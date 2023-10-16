%%%-------------------------------------------------------------------
%%% @doc
%%% OTP `logger' handler that sends logs to journald
%%%
%%% It has a limited support for logger formatter: you can only use `logger_formatter' module and
%%% `template' option will be ignored.
%%%
%%% It has some basic overload protection, see `sync_mode_qlen' and `drop_mode_qlen' options.
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
    defaults => #{journald_sock:key() => journald_sock:value()},
    sync_mode_qlen => pos_integer(),
    drop_mode_qlen => pos_integer()
}.

%% Handler's specific options
%% <ul>
%%   <li>`socket_path' - path to journald control socket</li>
%%   <li>`defaults' - flat key-value pairs which will be mixed-in to every log message (unless
%%   overwritten by message's own fields)</li>
%%   <li>`sync_mode_qlen' - same as for `logger_std_h': when handler's msg queue reaches this
%%   many messages, switch from `gen_server:cast' to `gen_server:call' (with default timeout)</li>
%%   <li>`drop_mode_qlen' - same as for `logger_std_h': when handler's msg queue reaches this
%%   many messages, just ignore log message. `warning' message will be periodically sent to the log
%%   saying how many messages were dropped (if any)</li>
%% </ul>

-record(state, {
    handle :: journald_sock:handle(),
    defaults :: #{binary() => iodata()},
    olp_last_check :: integer(),
    olp_counter :: counters:counters_ref()
    %% ,
    %% olp_opts :: map()
}).

-define(OPT_KEYS, [socket_path, defaults]).
-define(SIZE_SHRINK_TO_BYTES, 1024).
-define(EAGAIN_RETRY_TIMES, 5).
-define(EAGAIN_RETRY_SLEEP_MS, 50).
-define(OLP_CHECK_INTERVAL_MS, 2500).
-define(OLP_MSQ_IDX, 1).
-define(OLP_DROP_IDX, 2).
-define(PT_KEY(Name), {?MODULE, Name, counter}).

%%%===================================================================
%%% API

start_link(Id, Opts) ->
    gen_server:start_link({local, id_to_reg(Id)}, ?MODULE, [Id, Opts], []).

%%%===================================================================
%%% logger callbacks

adding_handler(#{id := Name, module := ?MODULE} = Config) ->
    ensure_app(),
    Opts0 = maps:get(config, Config, #{}),
    DefaultOpts = #{
        sync_mode_qlen => 10,
        drop_mode_qlen => 1000
    },
    Opts = maps:merge(DefaultOpts, Opts0),
    HandlerOpts = maps:with(?OPT_KEYS, Opts0),
    overload_init(Config#{config => Opts}),
    case logger_journald_sup:start_handler(Name, HandlerOpts) of
        {ok, NewPid} ->
            NewPid;
        {error, {already_started, OldPid}} ->
            %% maybe handler failed and have been restarted by supervisor
            OldPid
    end,
    {ok, Config#{config => Opts#{handler_reg => id_to_reg(Name)}}}.

changing_config(_SetOrUpdate, _OldConfig, NewConfig) ->
    %% TODO
    {ok, NewConfig}.

removing_handler(#{config := #{handler_reg := RegName}} = Config) ->
    logger_journald_sup:stop_handler(RegName),
    overload_stop(Config).

log(LogEvent, #{config := #{handler_reg := RegName}} = Conf) ->
    NormalEvent = normalize_event(LogEvent, Conf),
    case overload_on_log(Conf) of
        cast ->
            gen_server:cast(RegName, {log, NormalEvent});
        call ->
            try
                gen_server:call(RegName, {log, NormalEvent})
            catch
                exit:{timeout, _} ->
                    timeout
            end;
        drop ->
            dropped
    end.

filter_config(#{config := Opts} = Config) ->
    Config#{config := maps:without([handler_reg], Opts)}.

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================
%% @private
init([Id, Opts]) ->
    % borrowed from logger_olp
    process_flag(message_queue_data, off_heap),
    Handle = journald_sock:open(Opts),
    Defaults = normalize_flat(maps:get(defaults, Opts, #{})),
    OlpCounter = persistent_term:get(?PT_KEY(Id)),
    {_, QLen} = erlang:process_info(self(), message_queue_len),
    ok = counters:put(OlpCounter, ?OLP_MSQ_IDX, QLen),
    {ok, #state{
        handle = Handle,
        defaults = Defaults,
        olp_counter = OlpCounter,
        olp_last_check = erlang:monotonic_time(millisecond)
    }}.

%% @private
handle_call({log, NormalizedEvent}, _From, #state{defaults = Defaults, handle = Handle} = State0) ->
    do_log(NormalizedEvent, Defaults, Handle),
    State = check_overload(State0),
    {reply, ok, State}.

%% @private
handle_cast({log, NormalizedEvent}, #state{defaults = Defaults, handle = Handle} = State0) ->
    do_log(NormalizedEvent, Defaults, Handle),
    State = check_overload(State0),
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

do_log(NormalizedEvent, Defaults, Handle) ->
    %XXX: maybe do merge in log/2, before sending?
    Event = maps:merge(Defaults, NormalizedEvent),
    case try_send(Event, Handle, ?EAGAIN_RETRY_TIMES) of
        ok ->
            ok;
        {error, Posix} ->
            MaybePid = maps:get(<<"ERL_PID">>, NormalizedEvent, <<"unknown">>),
            internal_msg(
                error,
                "log emission for pid: ~p failed: ~p",
                [MaybePid, Posix],
                Defaults,
                Handle
            )
    end.

try_send(_Event, _Handle, 0) ->
    {error, no_retries};
try_send(Event, Handle, Retry) ->
    case journald_sock:log(Event, Handle) of
        ok ->
            ok;
        {error, TooBig} when TooBig == emsgsize; TooBig == enobufs ->
            ShrinkLimit = ?SIZE_SHRINK_TO_BYTES,
            ShrunkMap = shrink(Event, ShrinkLimit),
            journald_sock:log(ShrunkMap, Handle);
        {error, eagain} ->
            timer:sleep(?EAGAIN_RETRY_SLEEP_MS),
            try_send(Event, Handle, Retry - 1);
        {error, _Other} = Err ->
            Err
    end.

shrink(Event, ShrinkLimit) ->
    maps:map(
        fun(_K, V) ->
            shrink_value(V, ShrinkLimit)
        end,
        Event
    ).

shrink_value(V, ShrinkLimit) ->
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
    end.

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
    Msg = ensure_bytes(logger_formatter:format(Event, FormatterConf#{template => [msg]})),
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
    normalize_kv(Key, io_lib:format("~0tp", [Value])).

normalize_flat(Map) ->
    maps:from_list([normalize_kv(K, V) || {K, V} <- maps:to_list(Map)]).

normalize_kv(K, V) ->
    {string:uppercase(K), ensure_bytes(V)}.

ensure_bytes(V) when is_binary(V) ->
    V;
ensure_bytes(V) when is_list(V) ->
    %% cheapest way to check if `V0' is indeed iolist (eg, has no ints over 255)
    try iolist_size(V) of
        _ -> V
    catch
        error:badarg ->
            try unicode:characters_to_binary(V)
	    catch error:badarg ->
	        io_lib:format("~w", [V])
	    end
    end;
ensure_bytes(V) when is_integer(V) ->
    integer_to_binary(V);
ensure_bytes(V) when is_atom(V) ->
    atom_to_binary(V, utf8).

%% Overlaod protection

overload_init(#{id := Name} = _Conf) ->
    Counter = counters:new(2, []),
    persistent_term:put(?PT_KEY(Name), Counter).

overload_stop(#{id := Name}) ->
    persistent_term:erase(?PT_KEY(Name)).

overload_on_log(#{
    id := Name,
    module := ?MODULE,
    config := #{
        drop_mode_qlen := DropModeLen,
        sync_mode_qlen := SyncModeLen
    }
}) ->
    Counter = persistent_term:get(?PT_KEY(Name)),
    case counters:get(Counter, ?OLP_MSQ_IDX) of
        Len when Len < SyncModeLen ->
            counters:add(Counter, ?OLP_MSQ_IDX, 1),
            cast;
        Len when Len < DropModeLen ->
            counters:add(Counter, ?OLP_MSQ_IDX, 1),
            call;
        _Len ->
            counters:add(Counter, ?OLP_DROP_IDX, 1),
            drop
    end.

check_overload(
    #state{
        olp_last_check = LastCheck,
        olp_counter = Counter,
        handle = Handle,
        defaults = Defaults
    } = St
) ->
    Now = erlang:monotonic_time(millisecond),
    case (LastCheck + ?OLP_CHECK_INTERVAL_MS) < Now of
        true ->
            %% XXX: there is a slight shance of real message queue length and counter to become out
            %% of sync in such a way that counter makes all callers into "drop" mode while
            %% real message queue is empty (how??). Then `check_overload' won't be called and will
            %% stuck in this state forever (since `check_overload' is triggered by log messages)
            {_, QLen} = erlang:process_info(self(), message_queue_len),
            ok = counters:put(Counter, ?OLP_MSQ_IDX, QLen),
            case counters:get(Counter, ?OLP_DROP_IDX) of
                0 ->
                    ok;
                NDropped ->
                    LastCheckSys = erlang:time_offset(millisecond) + LastCheck,
                    internal_msg(
                        warning,
                        ?MODULE_STRING ++ " dropped ~w messages since ~s",
                        [
                            NDropped,
                            calendar:system_time_to_rfc3339(
                                LastCheckSys,
                                [{unit, millisecond}]
                            )
                        ],
                        Defaults,
                        Handle
                    ),
                    %% using `sub' because there might be more accumulated while we were sending
                    %% internal_msg.
                    %% In theory should check for int64 overflow, but unlikely in practice.
                    counters:sub(Counter, ?OLP_DROP_IDX, NDropped)
            end,
            %% TODO: implement "flush" mode here
            St#state{olp_last_check = Now};
        false ->
            counters:sub(Counter, ?OLP_MSQ_IDX, 1),
            St
    end.

internal_msg(Level, Fmt, Params, Defaults, Handle) ->
    Msg = io_lib:format("[logger] " ++ Fmt, Params),
    FilteredDefaults = maps:filter(
        fun
            (<<"SYSLOG_IDENTIFIER">>, _) -> true;
            ("SYSLOG_IDENTIFIER", _) -> true;
            (K, _) -> unicode:characters_to_binary(K) == <<"SYSLOG_IDENTIFIER">>
        end,
        Defaults
    ),
    Event = FilteredDefaults#{
        <<"MESSAGE">> => Msg,
        <<"PRIORITY">> => convert_level(Level),
        <<"ERL_DOMAIN">> => <<?MODULE_STRING>>
    },
    case journald_sock:log(Event, Handle) of
        ok ->
            journal;
        {error, Err} ->
            io:format(
                standard_error,
                ?MODULE_STRING ":~w error '~0p' sending internal message ~0p",
                [?LINE, Err, Event]
            ),
            standard_error
    end.

-ifdef(EUNIT).

-include_lib("eunit/include/eunit.hrl").

format_test() ->
    Samples = [
        {#{<<"MESSAGE">> => <<"\"A\": B">>}, {report, #{"A" => "B"}}, #{}},
        {#{<<"MESSAGE">> => <<"\"A\": привет"/utf8>>}, {report, #{"A" => "привет"}}, #{}},
        {#{"A" => <<"привет"/utf8>>, <<"MESSAGE">> => <<"">>}, {string, ""}, #{"A" => "привет"}},
        {#{<<"A">> => <<"привет"/utf8>>, <<"MESSAGE">> => <<"">>}, {string, ""}, #{
            <<"A">> => <<"привет"/utf8>>
        }},
        {#{"A" => <<"привет"/utf8>>, <<"MESSAGE">> => <<"привет"/utf8>>}, {string, "привет"}, #{
            "A" => <<"привет"/utf8>>
        }},
        {#{"A" => <<"привет"/utf8>>, <<"MESSAGE">> => <<"привет"/utf8>>},
            {string, <<"привет"/utf8>>}, #{"A" => "привет"}}
    ],
    [
        begin
            Event = #{msg => Msg, level => info, meta => Meta},
            NormEvent0 = normalize_event(Event, #{}),
            NormMsg = maps:get(<<"MESSAGE">>, NormEvent0),
            NormEvent = NormEvent0#{<<"MESSAGE">> := iolist_to_binary(NormMsg)},
            ?assertEqual(
                Expect#{<<"PRIORITY">> => "6"},
                NormEvent,
                Event
            )
        end
        || {Expect, Msg, Meta} <- Samples
    ].

-endif.
