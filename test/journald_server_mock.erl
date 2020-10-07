-module(journald_server_mock).

-export([
    start/1,
    stop/1,
    parse/1,
    get_path/1,
    recv_raw/1,
    recv_parse/1
]).

start(Opts) ->
    Default = #{
        socket_path => "/tmp/" ++ ?MODULE_STRING ++ ".sock",
        socket_opts => []
    },
    #{
        socket_path := Path,
        socket_opts := ExtraSockOpts
    } = maps:merge(Default, Opts),
    file:delete(Path),
    Addr = {local, Path},
    {ok, Sock} = gen_udp:open(0, [local, binary, {ifaddr, Addr}, {active, false} | ExtraSockOpts]),
    #{sock => Sock, path => Path}.

stop(#{sock := Sock, path := Path}) ->
    gen_udp:close(Sock),
    file:delete(Path).

recv_raw(#{sock := Sock}) ->
    {ok, {_Addr, _Port, Data}} = gen_udp:recv(Sock, 8192, 5000),
    Data.

recv_parse(St) ->
    parse(recv_raw(St)).

parse(Bin) ->
    maps:from_list(parse_to_list(Bin)).

get_path(#{path := Path}) ->
    Path.

parse_to_list(Bin) ->
    parse_pair(binary:split(Bin, <<"\n">>)).

parse_pair([Line, Tail]) ->
    case binary:split(Line, <<"=">>) of
        [Key, Value] ->
            %% Normal 'KEY=Value\n'
            [{Key, Value} | parse_to_list(Tail)];
        [Key] ->
            %% Probably binary field containing '=' in value
            %% 'Key \n Len:64/unsigned-little Value \n'
            <<Len:64/unsigned-little, Value:Len/binary, "\n", Rest/binary>> = Tail,
            [{Key, Value} | parse_to_list(Rest)]
    end;
parse_pair([<<>>]) ->
    [].
