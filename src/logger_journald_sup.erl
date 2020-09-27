%%%-------------------------------------------------------------------
%%% @doc
%%% Supervisor that holds journald handler process(es)
%%% @end
%%% @author Sergey Prokhorov <me@seriyps.ru>
%%%-------------------------------------------------------------------
-module(logger_journald_sup).

-behaviour(supervisor).

%% API
-export([start_link/0, start_handler/2, stop_handler/1]).

-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

start_handler(Name, Opts) ->
    supervisor:start_child(?MODULE, [Name, Opts]).

stop_handler(Pid) ->
    supervisor:terminate_child(?MODULE, Pid).

init([]) ->
    SupFlags = #{
        strategy => simple_one_for_one,
        intensity => 5,
        period => 5
    },

    AChild = #{
        id => logger_journald_h,
        start => {logger_journald_h, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [logger_journald_h]
    },

    {ok, {SupFlags, [AChild]}}.
