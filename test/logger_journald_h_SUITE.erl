-module(logger_journald_h_SUITE).

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([just_log_case/1]).

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
    ?assertMatch(#{<<"MESSAGE">> := <<"    a: b\n    c: d">>}, p_recv(Srv)),

    logger:log(error, #{a => b}, #{report_cb => fun(Rep) -> io_lib:format("~p", [Rep]) end}),
    ?assertMatch(#{<<"MESSAGE">> := <<"#{a => b}">>}, p_recv(Srv)),

    logger:log(
        emergency,
        #{c => d},
        #{report_cb => fun(Rep, Smth) -> io_lib:format("~p ~p", [Rep, Smth]) end}
    ),
    ?assertMatch(#{<<"MESSAGE">> := <<"#{c => d} []">>}, p_recv(Srv)),

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
        ["my", $_, <<"key">>, ["5"]] => 42
    }),
    ?assertMatch(
        #{
            <<"MESSAGE">> := <<"Wake up! doom">>,
            <<"MY_KEY1">> := <<"my_value1">>,
            <<"MY_KEY2">> := <<"my_value2">>,
            <<"MY_KEY3">> := <<"my_value3">>,
            <<"MY_KEY4">> := <<"{192,168,0,1}">>,
            <<"MY_KEY5">> := <<"42">>
        },
        p_recv(Srv)
    ),
    ok.

add_handler_for_srv(Id, Srv) ->
    Path = journald_server_mock:get_path(Srv),
    ok = logger:add_handler(Id, logger_journald_h, #{config => #{socket_path => Path}}).

p_recv(Srv) ->
    journald_server_mock:recv_parse(Srv).
