%%%-------------------------------------------------------------------
%%% @doc
%%% OTP `logger' handler that sends logs to journald
%%%
%%% This handler does not provide any overload protection (yet). OTP's built-in `logger_olp' is not
%%% documented (and not really reusable), so we can't use it here.
%%%
%%% It has a limited support for logger formatter: you can only use `logger_formatter' module and
%%% `template' option will be ignored.
%%%
%%% Implementation of [http://erlang.org/doc/man/logger.html#handler_callback_functions
%%%   logger handler callbacks].
%%% See
%%% [http://erlang.org/doc/apps/kernel/logger_chapter.html#example--implement-a-handler examples].
%%% @end
%%% @author Sergey Prokhorov <me@seriyps.ru>
%%%-------------------------------------------------------------------
-module(logger_journald_h).

-behaviour(gen_server).

%% API
-export([start_link/2]).

%% logger callbacks
-export([
    log/2,
    adding_handler/1,
    removing_handler/1,
    changing_config/3,
    filter_config/1
]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-export_type([opts/0]).

-type opts() :: #{
    socket_path => file:filename_all(),
    defaults => #{journald_sock:key() => journald_sock:value()}
}.

%% Handler's specific options
%% <ul>
%%   <li>`socket_path' - path to journald control socket</li>
%%   <li>`defaults' - flat key-value pairs which will be mixed-in to every log message (unless
%%   overwritten by message's own fields)</li>
%% </ul>

-record(state, {
    handle :: journald_sock:handle(),
    defaults :: #{binary() => iodata()}
}).

-define(OPT_KEYS, [socket_path, defaults]).

%%%===================================================================
%%% API

start_link(Id, Opts) ->
    gen_server:start_link({local, id_to_reg(Id)}, ?MODULE, [Id, Opts], []).

%%%===================================================================
%%% logger callbacks

adding_handler(#{id := Name, module := ?MODULE} = Config) ->
    ensure_app(),
    Opts = maps:get(config, Config, #{}),
    MyOpts = maps:with(?OPT_KEYS, Opts),
    Pid =
        case logger_journald_sup:start_handler(Name, MyOpts) of
            {ok, NewPid} ->
                NewPid;
            {error, {already_started, OldPid}} ->
                %% maybe handler failed and have been restarted by supervisor
                OldPid
        end,
    {ok, Config#{config => Opts#{handler_pid => Pid}}}.

changing_config(_SetOrUpdate, _OldConfig, NewConfig) ->
    %% TODO
    {ok, NewConfig}.

removing_handler(#{config := #{handler_pid := Pid}}) ->
    logger_journald_sup:stop_handler(Pid).

log(LogEvent, #{config := #{handler_pid := Pid}} = Conf) ->
    NormalEvent = normalize_event(LogEvent, Conf),
    gen_server:call(Pid, {log, NormalEvent}).

filter_config(#{config := Opts} = Config) ->
    Config#{config := maps:without([handler_pid], Opts)}.

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================
%% @private
init([_Id, Opts]) ->
    % borrowed from logger_olp
    process_flag(message_queue_data, off_heap),
    Handle = journald_sock:open(Opts),
    Defaults = normalize_flat(maps:get(defaults, Opts, #{})),
    {ok, #state{handle = Handle, defaults = Defaults}}.

%% @private
handle_call({log, NormalizedEvent}, _From, #state{defaults = Defaults, handle = Handle} = State) ->
    %XXX: maybe do merge in log/2, before sending?
    Event = maps:merge(Defaults, NormalizedEvent),
    case try_send(Event, Handle) of
        ok ->
            ok;
        {error, Posix} ->
            %% just crash if this one also fails
            MaybePid = maps:get(<<"ERL_PID">>, NormalizedEvent, <<"unknown">>),
            Msg = io_lib:format("[logger] log emission for pid: ~p failed: ~p", [MaybePid, Posix]),
            ok = journald_sock:log(
                #{
                    <<"MESSAGE">> => Msg,
                    <<"PRIORITY">> => convert_level(error)
                },
                Handle
            )
    end,
    {reply, ok, State}.

try_send(Event, Handle) ->
    case journald_sock:log(Event, Handle) of
        ok ->
            ok;
        {error, TooBig} when TooBig == emsgsize; TooBig == enobufs ->
            ShrinkLimit = 1024,
            ShrunkMap = shrink(Event, ShrinkLimit),
            journald_sock:log(ShrunkMap, Handle)
    end.

shrink(Event, ShrinkLimit) ->
    maps:map(
        fun(_K, V) ->
            try string:slice(V, 0, ShrinkLimit) of
                ShrunkV ->
                    case iolist_size(ShrunkV) of
                        ShrinkLimit ->
                            %% Was probably shrunk
                            [ShrunkV, <<"…"/utf8>>];
                        _ ->
                            ShrunkV
                    end
            catch
                _:_ ->
                    <<"truncated">>
            end
        end,
        Event
    ).

%% @private
handle_cast(_Request, State) ->
    {noreply, State}.

%% @private
handle_info(_Info, State) ->
    {noreply, State}.

%% @private
terminate(_Reason, #state{handle = Handle}) ->
    case journald_sock:is_handle(Handle) of
        true ->
            journald_sock:close(Handle);
        false ->
            ok
    end.

%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions

id_to_reg(Name) ->
    list_to_atom(?MODULE_STRING ++ "_" ++ atom_to_list(Name)).

ensure_app() ->
    case whereis(logger_journald_sup) of
        undefined ->
            ok = application:start(logger_journald);
        _Pid ->
            ok
    end.

-spec normalize_event(logger:log_event(), logger:handler_config()) -> journald_sock:log_msg().
normalize_event(#{msg := _, level := Level, meta := Meta} = Event, Conf) ->
    {logger_formatter, FormatterConf0} = maps:get(formatter, Conf, {logger_formatter, #{}}),
    FormatterConf = maps:with(
        [chars_limit, depth, max_size, report_cb, single_line],
        FormatterConf0
    ),
    Msg = logger_formatter:format(Event, FormatterConf#{template => [msg]}),
    maps:from_list(
        [
            {<<"PRIORITY">>, convert_level(Level)},
            {<<"MESSAGE">>, Msg}
            | convert_meta(maps:to_list(Meta))
        ]
    ).

convert_level(Level) ->
    %% value between 0 ("emerg") and 7 ("debug") formatted as a decimal string
    case Level of
        emergency -> "0";
        alert -> "1";
        critical -> "2";
        error -> "3";
        warning -> "4";
        notice -> "5";
        info -> "6";
        debug -> "7"
    end.

convert_meta([{K, V} | Tail]) ->
    case convert_meta(K, V) of
        false -> convert_meta(Tail);
        {_, _} = Pair -> [Pair | convert_meta(Tail)]
    end;
convert_meta([]) ->
    [].

convert_meta(file, File) ->
    {<<"CODE_FILE">>, File};
convert_meta(line, Line) ->
    {<<"CODE_LINE">>, integer_to_binary(Line)};
convert_meta(mfa, {Module, Function, Arity}) ->
    MFA = io_lib:format("~s:~s/~w", [Module, Function, Arity]),
    {<<"CODE_FUNC">>, iolist_to_binary(MFA)};
convert_meta(time, TS) ->
    TimeStr = calendar:system_time_to_rfc3339(TS, [{unit, microsecond}]),
    {<<"SYSLOG_TIMESTAMP">>, TimeStr};
convert_meta(pid, Pid) ->
    {<<"ERL_PID">>, erlang:pid_to_list(Pid)};
convert_meta(gl, Pid) ->
    {<<"ERL_GROUP_LEADER">>, erlang:pid_to_list(Pid)};
convert_meta(domain, Domain) ->
    {<<"ERL_DOMAIN">>, lists:join($., lists:map(fun erlang:atom_to_list/1, Domain))};
convert_meta(report_cb, _Cb) ->
    false;
convert_meta(Key, Value) when
    is_list(Key) orelse is_binary(Key),
    is_list(Value) orelse
        is_binary(Value) orelse
        is_atom(Value) orelse
        is_integer(Value)
->
    normalize_kv(Key, Value);
convert_meta(Key, Value) when is_atom(Key) ->
    convert_meta(atom_to_binary(Key, utf8), Value);
convert_meta(Key, Value) ->
    normalize_kv(Key, io_lib:format("~0p", [Value])).

normalize_flat(Map) ->
    maps:from_list([normalize_kv(K, V) || {K, V} <- maps:to_list(Map)]).

normalize_kv(K, V) ->
    {string:uppercase(K), V}.
