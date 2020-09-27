%% @doc Tiny interface to Journald socket
%%
%% See `man sd_journal_send', `man systemd.journal-fields'
%%
%% See [https://github.com/systemd/systemd/blob/v246/src/journal/journal-send.c#L206-L337
%%      sd_journal_sendv]
-module(journald_log).

-export([open/1, log/2, format/1]).

-export_type([handle/0, log_msg/0]).

-include_lib("kernel/include/file.hrl").

-record(state, {
    fd :: gen_udp:socket(),
    % see inet:local_address()
    path :: file:filename_all()
}).

-type key() :: iodata().
-type value() :: iodata() | integer() | atom().

-type log_msg() ::
    #{key() => value()} |
    [{key(), value()}].

-opaque handle() :: #state{}.

-define(DEFAULT_SOCKET_PATH, "/run/systemd/journal/socket").

%% @doc Opens journald log socket
-spec open(#{socket_path => file:filename_all()}) -> handle().
open(Opts) ->
    Path = maps:get(socket_path, Opts, ?DEFAULT_SOCKET_PATH),
    % any better way to check UNIX socket?
    {ok, #file_info{type = other}} = file:read_file_info(Path),
    {ok, S} = gen_udp:open(0, [
        local,
        {mode, binary}
    ]),
    #state{
        fd = S,
        path = Path
    }.

%% @doc Logs a Key - Value message to journald socket
%%
%% Keys have to be `iodata()' and should not contain newlines or `=' signs
%% Values can be `iodata()', `atom()' or `integer()' and may contain any binaries. utf8 is
%% preferrable
-spec log(log_msg(), handle()) -> ok | {error, inet:posix()}.
log(KV, #state{fd = Fd, path = Path}) ->
    Packet = format(KV),
    gen_udp_send(Fd, {local, Path}, Packet).

%% @doc Formats a flat Key-Value message to a (non-documented) format acceptable by journald socket
-spec format(log_msg()) -> iodata().
format(Map) when is_map(Map) ->
    format(maps:to_list(Map));
format([_ | _] = KV) when is_list(KV) ->
    [format_pair(K, V) || {K, V} <- KV].

%% =====================
%% Internal

-if(?OTP_RELEASE >= 22).
gen_udp_send(Fd, Dest, Packet) ->
    gen_udp:send(Fd, Dest, Packet).
-else.
gen_udp_send(Fd, Dest, Packet) ->
    gen_udp:send(Fd, Dest, 0, Packet).
-endif.

%% Keys supposed to be uppercase, but we are not enforcing that
format_pair(K, V) when is_integer(V) ->
    format_pair(K, integer_to_binary(V));
format_pair(K, V) when is_atom(V) ->
    format_pair(K, atom_to_binary(V, utf8));
format_pair(K, V) when is_binary(K) orelse is_list(K), is_binary(V) orelse is_list(V) ->
    (iolist_size(K) > 0) orelse error(empty_key),
    (not has_nl_or_eq(K)) orelse error({newline_or_eq_in_key, K}),
    case has_nl(V) of
        false ->
            [K, "=", V, $\n];
        true ->
            [K, <<"\n", (iolist_size(V)):64/unsigned-little>>, V, $\n]
    end.

has_nl(Subj) ->
    has(Subj, <<"\n">>).

has_nl_or_eq(Subj) ->
    has(Subj, [<<"\n">>, <<"=">>]).

has(Bin, What) when is_binary(Bin) ->
    binary:match(Bin, What) =/= nomatch;
has(IoList, What) ->
    re:run(IoList, [$[, What, $]], [{capture, none}]) =/= nomatch.

-ifdef(EUNIT).

-include_lib("eunit/include/eunit.hrl").

format_test() ->
    Samples = [
        {<<"A=B\n">>, [{"A", "B"}]},
        {<<"A=B\n">>, #{"A" => "B"}},
        {<<"A=B\n">>, #{<<"A">> => <<"B">>}},
        {<<"A=B\n">>, #{<<"A">> => 'B'}},
        {<<"A=10\n">>, #{<<"A">> => 10}},
        {<<"A=B\nC=D\nE=F\nG=123\n">>, [
            {<<"A">>, <<"B">>},
            {"C", "D"},
            {"E", 'F'},
            {"G", 123}
        ]},
        {<<"A\n", 3:64/unsigned-little, "B\nC\n">>, #{<<"A">> => <<"B\nC">>}},
        {<<"A\n", 3:64/unsigned-little, "B\nC\n">>, #{<<"A">> => ["B", $\n, <<"C">>]}}
    ],
    [?assertEqual(Expect, iolist_to_binary(format(KV)), KV) || {Expect, KV} <- Samples],

    ?assertError(function_clause, format(#{})),
    ?assertError(function_clause, format([])),
    ?assertError(function_clause, format(#{a => b})),
    ?assertError(function_clause, format(#{"A" => #{}})),
    ?assertError({newline_or_eq_in_key, "A\nB"}, format(#{"A\nB" => "C"})),
    ?assertError({newline_or_eq_in_key, "A=B"}, format(#{"A=B" => "C"})),
    ?assertError({newline_or_eq_in_key, <<"A=B">>}, format(#{<<"A=B">> => "C"})),
    ?assertError(empty_key, format(#{<<>> => "A"})),
    ?assertError(empty_key, format(#{[] => "A"})).

-endif.
