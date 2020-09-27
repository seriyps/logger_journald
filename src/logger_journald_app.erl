%%%-------------------------------------------------------------------
%%% @author Sergey <me@seriyps.ru>
%%% @doc
%%% OTP logger handler that sends log messages to Linux journald
%%% @end
%%% Created : 26 Sep 2020 by Sergey Prokhorov <me@seriyps.ru>
%%%-------------------------------------------------------------------
-module(logger_journald_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    logger_journald_sup:start_link().

stop(_State) ->
    ok.
