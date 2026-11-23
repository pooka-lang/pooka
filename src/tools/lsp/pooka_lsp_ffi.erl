%% SPDX-License-Identifier: Apache-2.0

%% LSP's lengths count bytes, even when a JSON string contains Unicode.
%% https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/
-module(pooka_lsp_ffi).
-export([serve/0]).

serve() ->
    ok = io:setopts(standard_io,[binary,{encoding,latin1}]),
    Server = self(),
    Reader = spawn_link(fun() -> read_messages(Server) end),
    Analyzer = spawn(fun() -> analyze_queue(Server) end),
    try loop(starting,#{},0,undefined,Analyzer)
    after
        unlink(Reader),
        exit(Reader,kill),
        exit(Analyzer,kill)
    end.

read_messages(Server) ->
    case headers(undefined) of
        {ok,Length} ->
            case bytes(Length,[]) of
                {ok,Body} ->
                    Message = try json:decode(Body) catch error:_ -> invalid_json end,
                    Server ! {message,Message},
                    read_messages(Server);
                error -> Server ! disconnected
            end;
        error -> Server ! disconnected
    end.

bytes(0,Parts) -> {ok,iolist_to_binary(lists:reverse(Parts))};
bytes(Length,Parts) ->
    case file:read(standard_io,Length) of
        {ok,Chunk} when byte_size(Chunk) > 0 ->
            bytes(Length-byte_size(Chunk),[Chunk|Parts]);
        _ -> error
    end.

loop(Stage,Docs,Revision,Timer,Analyzer) ->
    receive
        {message,invalid_json} ->
            error_response(null,-32700,<<"Parse error">>),
            loop(Stage,Docs,Revision,Timer,Analyzer);
        {message,Message} when is_map(Message) -> dispatch(Message,Stage,Docs,Revision,Timer,Analyzer);
        {message,_} ->
            error_response(null,-32600,<<"Invalid request">>),
            loop(Stage,Docs,Revision,Timer,Analyzer);
        {analyze,Revision} when Stage =:= running ->
            Analyzer ! {analyze,Revision,Docs},
            loop(Stage,Docs,Revision,undefined,Analyzer);
        {checked,Revision,Results} when Stage =:= running ->
            lists:foreach(fun({Uri,Version,Diagnostics}) -> publish(Uri,Version,Diagnostics) end,Results),
            loop(Stage,Docs,Revision,Timer,Analyzer);
        disconnected -> disconnected();
        _ -> loop(Stage,Docs,Revision,Timer,Analyzer)
    end.

%% At most one check runs at a time. If edits arrive while it is busy,
%% analyze only the newest queued snapshot when it becomes available.
analyze_queue(Server) ->
    receive
        {analyze,_,_} = Work ->
            {analyze,Revision,Docs} = newest_analysis(Work),
            try Server ! {checked,Revision,analyze(Docs)}
            catch Class:Reason ->
                io:format(standard_error,"Pooka LSP analysis failed: ~p:~p~n",[Class,Reason])
            end,
            analyze_queue(Server)
    end.

newest_analysis(Work) ->
    receive
        {analyze,_,_} = Newer -> newest_analysis(Newer)
    after 0 -> Work end.

headers(Length) ->
    case io:get_line(standard_io, "") of
        <<"\n">> when is_integer(Length) -> {ok,Length};
        <<"\n">> -> error;
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

dispatch(#{<<"method">> := <<"initialize">>, <<"id">> := Id}, starting, Docs, R, T, Analyzer) ->
    reply(Id,#{capabilities => #{positionEncoding => <<"utf-16">>,
        documentFormattingProvider => true, documentSymbolProvider => true,
        textDocumentSync => #{openClose => true,change => 1,save => true}},
        serverInfo => #{name => <<"Pooka">>}}),
    loop(running,Docs,R,T,Analyzer);
dispatch(#{<<"method">> := <<"shutdown">>, <<"id">> := Id}, running, Docs, R, T, Analyzer) ->
    reply(Id,null), loop(stopping,Docs,R,T,Analyzer);
dispatch(#{<<"method">> := <<"exit">>}, stopping, _, _, _, _) -> 0;
dispatch(#{<<"method">> := <<"exit">>}, _, _, _, _, _) -> 1;
dispatch(#{<<"method">> := <<"textDocument/didOpen">>,
           <<"params">> := #{<<"textDocument">> :=
               #{<<"uri">> := Uri,<<"text">> := Text,<<"version">> := Version}}}, running, Docs, R, T, Analyzer) ->
    case file_path(Uri) of
        {ok,Path} -> changed(maps:put(Uri,{Path,Version,Text},Docs),R,T,Analyzer);
        error -> loop(running,Docs,R,T,Analyzer)
    end;
dispatch(#{<<"method">> := <<"textDocument/didChange">>,
           <<"params">> := #{<<"textDocument">> := #{<<"uri">> := Uri,<<"version">> := Version},
                             <<"contentChanges">> := Changes}}, running, Docs, R, T, Analyzer) ->
    case {maps:find(Uri,Docs),is_list(Changes)} of
        {{ok,{Path,Old,_}},true} when Version > Old, Changes =/= [] ->
            case lists:last(Changes) of
                #{<<"text">> := Text} when is_binary(Text) ->
                    changed(maps:put(Uri,{Path,Version,Text},Docs),R,T,Analyzer);
                _ -> loop(running,Docs,R,T,Analyzer)
            end;
        _ -> loop(running,Docs,R,T,Analyzer)
    end;
dispatch(#{<<"method">> := <<"textDocument/didSave">>}, running, Docs, R, T, Analyzer) ->
    changed(Docs,R,T,Analyzer);
dispatch(#{<<"method">> := <<"textDocument/didClose">>,
           <<"params">> := #{<<"textDocument">> := #{<<"uri">> := Uri}}}, running, Docs, R, T, Analyzer) ->
    publish(Uri,null,[]), changed(maps:remove(Uri,Docs),R,T,Analyzer);
dispatch(#{<<"method">> := <<"textDocument/documentSymbol">>, <<"id">> := Id,
           <<"params">> := #{<<"textDocument">> := #{<<"uri">> := Uri}}}, running, Docs, R, T, Analyzer) ->
    Symbols = case maps:find(Uri,Docs) of
        {ok,{Path,_,Source}} ->
            Raw = json:decode('tools@lsp@symbols':outline(Path,Source)),
            [symbol_ranges(Symbol,Source) || Symbol <- Raw];
        error -> []
    end,
    reply(Id,Symbols), loop(running,Docs,R,T,Analyzer);
dispatch(#{<<"method">> := <<"textDocument/formatting">>, <<"id">> := Id,
           <<"params">> := #{<<"textDocument">> := #{<<"uri">> := Uri}}}, running, Docs, R, T, Analyzer) ->
    Edits = case maps:find(Uri,Docs) of
        {ok,{_,_,Source}} ->
            case 'tools@formatter':format(Source) of
                {ok,Formatted} when Formatted =/= Source ->
                    [#{range => #{start => position(#{},Source),
                                   'end' => position(#{<<"byte_offset">> => byte_size(Source)},Source)},
                       newText => Formatted}];
                _ -> []
            end;
        error -> []
    end,
    reply(Id,Edits), loop(running,Docs,R,T,Analyzer);
dispatch(#{<<"id">> := Id}, starting, Docs, R, T, Analyzer) ->
    error_response(Id,-32002,<<"Server not initialized">>), loop(starting,Docs,R,T,Analyzer);
dispatch(#{<<"id">> := Id}, Stage, Docs, R, T, Analyzer) ->
    error_response(Id,-32601,<<"Method not found">>), loop(Stage,Docs,R,T,Analyzer);
dispatch(_,Stage,Docs,R,T,Analyzer) -> loop(Stage,Docs,R,T,Analyzer).

changed(Docs,R,Timer,Analyzer) ->
    case Timer of undefined -> ok; _ -> erlang:cancel_timer(Timer) end,
    Next = erlang:send_after(180,self(),{analyze,R+1}),
    loop(running,Docs,R+1,Next,Analyzer).

publish(Uri,Version,Diagnostics) ->
    Params = #{uri => Uri,diagnostics => Diagnostics},
    send(#{method => <<"textDocument/publishDiagnostics">>,
           params => case Version of null -> Params; _ -> Params#{version => Version} end}).

file_path(Uri) ->
    try uri_string:parse(Uri) of
        #{scheme := <<"file">>,path := Raw} ->
            Path = uri_string:percent_decode(Raw),
            case {os:type(),Path} of
                {{win32,_},<<$/,Drive,$:,Rest/binary>>} -> canonical_path(<<Drive,$:,Rest/binary>>);
                _ -> canonical_path(Path)
            end;
        _ -> error
    catch _:_ -> error end.

canonical_path(Path) ->
    case pooka_package_ffi:canonical(filename:dirname(Path)) of
        {ok,Canonical} -> {ok,filename:join(Canonical,filename:basename(Path))};
        _ -> {ok,Path}
    end.

analyze(Docs) ->
    Groups = maps:fold(fun(Uri,{Path,Version,Source},Acc) ->
        Workspace = 'tools@lsp@analysis':workspace(Path),
        maps:update_with(Workspace,fun(L) -> [{Uri,Path,Version,Source}|L] end,
                         [{Uri,Path,Version,Source}],Acc)
    end,#{},Docs),
    lists:append([analyze_group(Workspace,Files) || {Workspace,Files} <- maps:to_list(Groups)]).

analyze_group({ok,Root},Files) ->
    Sources = [{Path,Source} || {_,Path,_,Source} <- Files],
    Diagnostics = try
        #{<<"diagnostics">> := Values} =
            json:decode('tools@lsp@analysis':diagnostics(Root,Sources)),
        Values
    catch Class:Reason ->
        io:format(standard_error,"Pooka LSP analysis failed: ~p:~p~n",[Class,Reason]),
        []
    end,
    Open = maps:from_list([{Path,{Uri,Source}} || {Uri,Path,_,Source} <- Files]),
    [{Uri,Version,for_document(Path,Root,Source,Open,Diagnostics)}
     || {Uri,Path,Version,Source} <- Files];
analyze_group(_,Files) -> [{Uri,Version,[]} || {Uri,_,Version,_} <- Files].

for_document(Path,Root,Source,Open,Diagnostics) ->
    lists:filtermap(fun(Diagnostic) ->
        Labels = maps:get(<<"labels">>,Diagnostic,[]),
        case [Location || #{<<"importance">> := <<"primary">>,
                            <<"location">> := #{<<"path">> := File}=Location} <- Labels,
                          filename:absname(File,Root) =:= Path] of
            [Location|_] ->
                Others = [Label || #{<<"location">> := At} = Label <- Labels, At =/= Location],
                Related = lists:filtermap(fun(Label) -> related(Label,Root,Open) end,Others),
                {true,diagnostic(Diagnostic,Location,Source,Related)};
            [] when Labels =:= [] -> {true,diagnostic(Diagnostic,#{},Source,[])};
            [] -> false
        end
    end,Diagnostics).

diagnostic(Value,Location,Source,Related) ->
    Start = position(maps:get(<<"start">>,Location,#{}),Source),
    End = position(maps:get(<<"end">>,Location,#{}),Source),
    Severity = case maps:get(<<"severity">>,Value) of
        <<"error">> -> 1; <<"warning">> -> 2; _ -> 3
    end,
    Message = lists:join(<<"\n">>,[Text || Key <- [<<"title">>,<<"conclusion">>],
                              Text <- [maps:get(Key,Value,<<>>)], Text =/= <<>>]),
    Diagnostic = #{range => #{start => Start,'end' => End},severity => Severity,
                   data => #{code => maps:get(<<"id">>,Value)},
                   message => iolist_to_binary(Message)},
    case Related of [] -> Diagnostic; _ -> Diagnostic#{relatedInformation => Related} end.

%% Byte offsets refer to the checked source. Prefer an unsaved buffer and
%% only use the disk version for a file the editor has not opened.
related(#{<<"location">> := #{<<"path">> := File}=Location,
          <<"message">> := Message},Root,Open) ->
    Path = filename:absname(File,Root),
    case related_source(Path,Open) of
        {ok,Uri,Source} ->
            {true,#{location => #{uri => Uri,range => lsp_range(Location,Source)},
                    message => Message}};
        error -> false
    end.

related_source(Path,Open) ->
    case maps:find(Path,Open) of
        {ok,{Uri,Source}} -> {ok,Uri,Source};
        error ->
            case file:read_file(Path) of
                {ok,Source} -> {ok,file_uri(Path),Source};
                _ -> error
            end
    end.

file_uri(Path) ->
    Normal = binary:replace(Path,<<"\\">>,<<"/">>,[global]),
    case Normal of
        <<"//",Rest/binary>> -> <<"file://",(uri_string:quote(Rest, "/:"))/binary>>;
        <<"/",_/binary>> -> <<"file://",(uri_string:quote(Normal, "/:"))/binary>>;
        _ -> <<"file:///",(uri_string:quote(Normal, "/:"))/binary>>
    end.

symbol_ranges(Symbol,Source) ->
    Range = maps:get(<<"range">>,Symbol),
    Selection = maps:get(<<"selectionRange">>,Symbol),
    Children = maps:get(<<"children">>,Symbol),
    Symbol#{<<"range">> => lsp_range(Range,Source),
            <<"selectionRange">> => lsp_range(Selection,Source),
            <<"children">> => [symbol_ranges(Child,Source) || Child <- Children]}.

lsp_range(#{<<"start">> := Start,<<"end">> := End},Source) ->
    #{start => position(Start,Source),'end' => position(End,Source)}.

position(Location,Source) ->
    Offset = min(byte_size(Source),max(0,maps:get(<<"byte_offset">>,Location,0))),
    Prefix = binary:part(Source,0,Offset),
    Lines = binary:split(Prefix,<<"\n">>,[global]),
    Line = lists:last(Lines),
    Utf16 = unicode:characters_to_binary(Line,utf8,{utf16,little}),
    Units = case Utf16 of
        Binary when is_binary(Binary) -> byte_size(Binary) div 2;
        {_,Binary,_} -> byte_size(Binary) div 2
    end,
    #{line => length(Lines)-1,character => Units}.

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
