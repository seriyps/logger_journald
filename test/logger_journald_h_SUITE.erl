-module(logger_journald_h_SUITE).

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    just_log_case/1,
    truncation_case/1
    %% ,
    %% overload_case/1
]).

-include_lib("stdlib/include/assert.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("kernel/include/logger.hrl").

all() ->
    %% All exported functions of arity 1 whose name ends with "_case"
    Exports = ?MODULE:module_info(exports),
    [
        F
        || {F, A} <- Exports,
           A == 1,
           case lists:reverse(atom_to_list(F)) of
               "esac_" ++ _ -> true;
               _ -> false
           end
    ].

init_per_suite(Cfg) ->
    {ok, _} = application:ensure_all_started(logger_journald),
    logger:set_primary_config(level, all),
    Cfg.

end_per_suite(Cfg) ->
    Cfg.

init_per_testcase(Name, Cfg) ->
    ?MODULE:Name({pre, Cfg}).

end_per_testcase(Name, Cfg) ->
    ?MODULE:Name({post, Cfg}).

just_log_case({pre, Cfg}) ->
    Srv = journald_server_mock:start(#{}),
    add_handler_for_srv(?FUNCTION_NAME, Srv),
    [{srv, Srv} | Cfg];
just_log_case({post, Cfg}) ->
    Srv = ?config(srv, Cfg),
    logger:remove_handler(?FUNCTION_NAME),
    journald_server_mock:stop(Srv),
    Cfg;
just_log_case(Cfg) when is_list(Cfg) ->
    Srv = ?config(srv, Cfg),
    SelfBin = list_to_binary(pid_to_list(self())),

    logger:log(info, "test"),
    ?assertMatch(
        #{
            <<"MESSAGE">> := <<"test">>,
            <<"ERL_GROUP_LEADER">> := <<"<", _/binary>>,
            <<"ERL_PID">> := SelfBin,
            <<"PRIORITY">> := <<"6">>,
            <<"SYSLOG_TIMESTAMP">> := _
        },
        p_recv(Srv)
    ),

    ?LOG_WARNING("test"),
    Func =
        <<?MODULE_STRING ":", (atom_to_binary(?FUNCTION_NAME, utf8))/binary, "/",
            (integer_to_binary(?FUNCTION_ARITY))/binary>>,
    ?assertMatch(
        #{
            <<"MESSAGE">> := <<"test">>,
            <<"CODE_FILE">> := <<_/binary>>,
            <<"CODE_FUNC">> := Func,
            <<"CODE_LINE">> := _,
            <<"ERL_GROUP_LEADER">> := <<"<", _/binary>>,
            <<"ERL_PID">> := SelfBin,
            <<"PRIORITY">> := <<"4">>,
            <<"SYSLOG_TIMESTAMP">> := _
        },
        p_recv(Srv),
        [{func, Func}, {pid, SelfBin}]
    ),

    logger:log(notice, "Hello ~s", ["world"]),
    ?assertMatch(#{<<"MESSAGE">> := <<"Hello world">>}, p_recv(Srv)),

    logger:log(debug, #{a => b, c => d}),
    #{<<"MESSAGE">> := Msg} = p_recv(Srv),
    %% <<"a: b, c: d">> or <<"c: d, a: b">>
    ?assertMatch([<<"a: b">>, <<"c: d">>], lists:sort(binary:split(Msg, <<", ">>))),

    logger:log(error, #{a => b}, #{report_cb => fun(Rep) -> {"~p", [Rep]} end}),
    ?assertMatch(#{<<"MESSAGE">> := <<"#{a => b}">>}, p_recv(Srv)),

    logger:log(
        emergency,
        #{c => d},
        #{report_cb => fun(Rep, Smth) -> io_lib:format("~p ~p", [Rep, Smth]) end}
    ),
    ?assertMatch(#{<<"MESSAGE">> := <<"#{c => d} #{", _/binary>>}, p_recv(Srv)),

    logger:critical(
        "Error: ~p",
        [smth_bad],
        #{domain => [logger_journald, ?MODULE, ?FUNCTION_NAME]}
    ),
    Domain =
        <<"logger_journald." ?MODULE_STRING ".", (atom_to_binary(?FUNCTION_NAME, utf8))/binary>>,
    ?assertMatch(
        #{
            <<"MESSAGE">> := <<"Error: smth_bad">>,
            <<"ERL_DOMAIN">> := Domain
        },
        p_recv(Srv),
        [{domain, Domain}]
    ),

    logger:alert("Wake up! ~p", [doom], #{
        my_key1 => my_value1,
        "my_key2" => "my_value2",
        <<"my_key3">> => <<"my_value3">>,
        <<"my_key4">> => {192, 168, 0, 1},
        ["my", $_, <<"key">>, ["5"]] => 42,
        <<"my_key6">> => [1087, 1088, 1080, 1074, 1077, 1090],
        <<"my_key7">> => [123456, 123456, 12345678901234567890],
        <<"my_key8">> => [ok]
    }),
    ?assertMatch(
        #{
            <<"MESSAGE">> := <<"Wake up! doom">>,
            <<"MY_KEY1">> := <<"my_value1">>,
            <<"MY_KEY2">> := <<"my_value2">>,
            <<"MY_KEY3">> := <<"my_value3">>,
            <<"MY_KEY4">> := <<"{192,168,0,1}">>,
            <<"MY_KEY5">> := <<"42">>,
            <<"MY_KEY6">> := <<208, 191, 209, 128, 208, 184, 208, 178, 208, 181, 209, 130>>,
            <<"MY_KEY7">> := <<"[123456,123456,12345678901234567890]">>,
            <<"MY_KEY8">> := <<"[ok]">>
        },
        p_recv(Srv)
    ),
    ok.

truncation_case({pre, Cfg}) ->
    Srv = journald_server_mock:start(#{socket_opts => [{recbuf, 2048}]}),
    add_handler_for_srv(?FUNCTION_NAME, Srv),
    [{srv, Srv} | Cfg];
truncation_case({post, Cfg}) ->
    Srv = ?config(srv, Cfg),
    logger:remove_handler(?FUNCTION_NAME),
    journald_server_mock:stop(Srv),
    Cfg;
truncation_case(Cfg) when is_list(Cfg) ->
    Srv = ?config(srv, Cfg),
    Bin10 = list_to_binary(lists:seq($0, $9)),
    <<MsgPart:1024/binary, _/binary>> = Msg = binary:copy(Bin10, 32 * 1024),
    logger:log(info, Msg),
    ShrunkMsg = <<MsgPart/binary, "…"/utf8>>,
    ?assertMatch(#{<<"MESSAGE">> := ShrunkMsg}, p_recv(Srv)).

%% @doc Test for overload protection
%% XXX: don't yet know how to validate it. Maybe use tracing? Or mock gen_udp?
%% overload_case({pre, Cfg}) ->
%%     Srv = journald_server_mock:start(#{}),
%%     add_handler_for_srv(?FUNCTION_NAME, Srv, #{
%%         sync_mode_qlen => 5,
%%         drop_mode_qlen => 10
%%     }),
%%     logger:set_module_level(logger_backend, debug),
%%     [{srv, Srv} | Cfg];
%% overload_case({post, Cfg}) ->
%%     Srv = ?config(srv, Cfg),
%%     logger:remove_handler(?FUNCTION_NAME),
%%     journald_server_mock:stop(Srv),
%%     Cfg;
%% overload_case(Cfg) when is_list(Cfg) ->
%%     Srv = ?config(srv, Cfg),
%%     io:format(user, "start ~n", []),
%%     Pids = [spawn_link(fun() -> log_loop(10) end) || _ <- lists:seq(1, 10)],
%%     [p_recv(Srv) || _ <- lists:seq(1, 5)],
%%     timer:sleep(3000),
%%     logger:notice("trigger check_overload"),
%%     [p_recv(Srv) || _ <- lists:seq(1, 30)],
%%     [exit(Pid, shutdown) || Pid <- Pids],
%%     ok.

%% log_loop(0) ->
%%     ok;
%% log_loop(N) ->
%%     logger:notice("loop ~w from ~p", [N, self()], #{domain => [test]}),
%%     log_loop(N - 1).

%% Internal

add_handler_for_srv(Id, Srv) ->
    add_handler_for_srv(Id, Srv, #{}).

add_handler_for_srv(Id, Srv, Conf) ->
    Path = journald_server_mock:get_path(Srv),
    ok = logger:add_handler(Id, logger_journald_h, #{config => Conf#{socket_path => Path}}).

p_recv(Srv) ->
    journald_server_mock:recv_parse(Srv).
