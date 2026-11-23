%% SPDX-License-Identifier: Apache-2.0

%% LSP's lengths count bytes, even when a JSON string contains Unicode.
%% https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/
-module(pooka_lsp_ffi).
-export([serve/0]).

serve() ->
    ok = io:setopts(standard_io,[binary,{encoding,latin1}]),
    loop(starting,#{}).

loop(Stage, Documents) ->
    case headers(undefined) of
        {ok,Length} ->
            case file:read(standard_io,Length) of
                {ok,Body} when byte_size(Body) =:= Length ->
                    try json:decode(Body) of
                        Message when is_map(Message) -> dispatch(Message,Stage,Documents);
                        _ -> error_response(null,-32600,<<"Invalid request">>), loop(Stage,Documents)
                    catch error:_ -> error_response(null,-32700,<<"Parse error">>), loop(Stage,Documents) end;
                _ -> disconnected()
            end;
        _ -> disconnected()
    end.

headers(Length) ->
    case io:get_line(standard_io, "") of
        <<"\r\n">> when is_integer(Length) -> {ok,Length};
        <<"\r\n">> -> error;
        Line when is_binary(Line), byte_size(Line) =< 8192 ->
            case binary:split(string:trim(Line), <<":">>) of
                [Name, Value] ->
                    case string:lowercase(Name) of
                        <<"content-length">> when Length =:= undefined ->
                            try binary_to_integer(string:trim(Value)) of
                                N when N > 0, N =< 16777216 -> headers(N);
                                _ -> error
                            catch error:badarg -> error end;
                        <<"content-length">> -> error;
                        _ -> headers(Length)
                    end;
                _ -> error
            end;
        _ -> error
    end.

dispatch(#{<<"method">> := <<"initialize">>, <<"id">> := Id}, starting, Docs) ->
    reply(Id,#{capabilities => #{positionEncoding => <<"utf-16">>},
               serverInfo => #{name => <<"Pooka">>}}),
    loop(running,Docs);
dispatch(#{<<"method">> := <<"shutdown">>, <<"id">> := Id}, running, Docs) ->
    reply(Id,null), loop(stopping,Docs);
dispatch(#{<<"method">> := <<"exit">>}, stopping, _) -> 0;
dispatch(#{<<"method">> := <<"exit">>}, _, _) -> 1;
dispatch(#{<<"id">> := Id}, starting, Docs) ->
    error_response(Id,-32002,<<"Server not initialized">>), loop(starting,Docs);
dispatch(#{<<"id">> := Id}, Stage, Docs) ->
    error_response(Id,-32601,<<"Method not found">>), loop(Stage,Docs);
dispatch(_,Stage,Docs) -> loop(Stage,Docs).

reply(Id,Result) -> send(#{id => Id, result => Result}).
error_response(Id,Code,Message) ->
    send(#{id => Id, error => #{code => Code,message => Message}}).

send(Message) ->
    Body = iolist_to_binary(json:encode(Message#{jsonrpc => <<"2.0">>})),
    ok = file:write(standard_io,[<<"Content-Length: ">>,integer_to_binary(byte_size(Body)),
                                 <<"\r\n\r\n">>,Body]).

disconnected() ->
    io:put_chars(standard_error,"error: language server disconnected before shutdown\n"),
    1.
