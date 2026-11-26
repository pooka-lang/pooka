%% SPDX-License-Identifier: Apache-2.0

%% LSP's lengths count bytes, even when a JSON string contains Unicode.
%% https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/
-module(pooka_lsp_ffi).
-export([serve/0,navigation_cache/2]).

serve() ->
    ok = io:setopts(standard_io,[binary,{encoding,latin1}]),
    Server = self(),
    put(lsp_pending_navigation,#{}),
    Reader = spawn_link(fun() -> read_messages(Server) end),
    Analyzer = spawn(fun() -> analyze_queue(Server) end),
    Navigator = spawn(fun() -> definition_queue(Server,undefined) end),
    try loop(starting,#{},0,undefined,{Analyzer,Navigator,false})
    after
        unlink(Reader),
        exit(Reader,kill),
        exit(Analyzer,kill),
        exit(Navigator,kill),
        case erase(lsp_test_worker) of Pid when is_pid(Pid) -> exit(Pid,kill); _ -> ok end
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
            {Worker,_,_} = Analyzer,
            Worker ! {analyze,Revision,Docs},
            loop(Stage,Docs,Revision,undefined,Analyzer);
        {checked,Revision,Results} when Stage =:= running ->
            put(lsp_quick_fixes,{Revision,maps:from_list([
                {Uri,Fixes} || {Uri,_,_,Fixes} <- Results, Fixes =/= []
            ])}),
            lists:foreach(fun({Uri,Version,Diagnostics,_}) ->
                publish(Uri,Version,Diagnostics)
            end,Results),
            loop(Stage,Docs,Revision,Timer,Analyzer);
        {navigation_start,Worker,Id,Ref} when Stage =:= running ->
            Worker ! {navigation_permission,Ref,pending_navigation(Id,Ref)},
            loop(Stage,Docs,Revision,Timer,Analyzer);
        {navigation_result,RequestRevision,Id,Ref,Result} when Stage =:= running ->
            case pending_navigation(Id,Ref) of
                true ->
                    remove_navigation(Id),
                    case {RequestRevision =:= Revision,Result} of
                        {false,_} -> error_response(Id,-32801,<<"Document changed during the request">>);
                        {true,{request_error,Message}} -> error_response(Id,-32602,Message);
                        {true,_} -> reply(Id,Result)
                    end;
                false -> ok
            end,
            loop(Stage,Docs,Revision,Timer,Analyzer);
        {test_result,Worker,Id,Result} when Stage =:= running ->
            case erase(lsp_test_worker) of
                Worker -> finish_test(Id,Result);
                _ -> ok
            end,
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

%% Typed navigation can run inference for the whole project. Keep one worker
%% separate from diagnostics so neither can block the protocol message loop.
definition_queue(Server,PreviousRevision) ->
    receive
        {navigation,Revision,Id,Ref,Work} ->
            Server ! {navigation_start,self(),Id,Ref},
            receive
                {navigation_permission,Ref,true} ->
                    refresh_navigation_cache(Revision,PreviousRevision),
                    Result = try navigation_work(Work)
                             catch Class:Reason ->
                                 io:format(standard_error,"Pooka navigation failed: ~p:~p~n",[Class,Reason]),
                                 null
                             end,
                    Server ! {navigation_result,Revision,Id,Ref,Result},
                    definition_queue(Server,Revision);
                {navigation_permission,Ref,false} ->
                    definition_queue(Server,PreviousRevision)
            end
    end.

navigation_work({workspace_symbols,Query,Roots,Docs}) ->
    workspace_symbols(Query,Roots,Docs);
navigation_work({document,Query,Uri,Position,Docs}) ->
    navigation(Query,Uri,Position,Docs).

enqueue_navigation(Worker,Revision,Id,Work) ->
    Ref = make_ref(),
    Pending = get(lsp_pending_navigation),
    put(lsp_pending_navigation,Pending#{Id => Ref}),
    Worker ! {navigation,Revision,Id,Ref,Work}.

pending_navigation(Id,Ref) -> maps:find(Id,get(lsp_pending_navigation)) =:= {ok,Ref}.

remove_navigation(Id) ->
    Pending = get(lsp_pending_navigation),
    put(lsp_pending_navigation,maps:remove(Id,Pending)),
    maps:is_key(Id,Pending).

refresh_navigation_cache(Revision,Revision) -> ok;
refresh_navigation_cache(_,_) -> erase(lsp_navigation_cache).

%% One workspace per worker snapshot bounds retained reports even when
%% several projects are open. The checked and inferred phases share that slot.
navigation_cache({Phase,Root},Compute) ->
    Cache = case get(lsp_navigation_cache) of
        {Root,Entries} -> Entries;
        _ -> #{}
    end,
    case maps:find(Phase,Cache) of
        {ok,Result} -> Result;
        error ->
            case Compute() of
                {ok,_} = Result ->
                    put(lsp_navigation_cache,{Root,maps:put(Phase,Result,Cache)}),
                    Result;
                Error -> Error
            end
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

dispatch(#{<<"method">> := <<"initialize">>, <<"id">> := Id}=Request, starting, Docs, R, T, {Worker,Navigator,_}) ->
    put(lsp_versioned_edits,supports_versioned_edits(Request)),
    put(lsp_workspace_roots,workspace_roots(Request)),
    reply(Id,#{capabilities => #{positionEncoding => <<"utf-16">>,
        documentFormattingProvider => true, documentSymbolProvider => true, definitionProvider => true, typeDefinitionProvider => true, hoverProvider => true, completionProvider => #{triggerCharacters => [<<".">>]},
        signatureHelpProvider => #{triggerCharacters => [<<"(">>,<<",">>]},
        codeActionProvider => #{codeActionKinds => [<<"quickfix">>]},
        semanticTokensProvider => #{full => true,
            legend => #{tokenTypes => 'tools@lsp@semantic':legend(),
                        tokenModifiers => [<<"declaration">>,<<"readonly">>]}},
        codeLensProvider => #{resolveProvider => false},
        executeCommandProvider => #{commands => [<<"pooka.runTest">>]},
        workspace => #{workspaceFolders => #{supported => true,changeNotifications => true}},
        workspaceSymbolProvider => true, referencesProvider => true, documentHighlightProvider => true,
        renameProvider => case get(lsp_versioned_edits) of
            true -> #{prepareProvider => true};
            false -> false
        end,
        textDocumentSync => #{openClose => true,change => 1,save => true}},
        serverInfo => #{name => <<"Pooka">>}}),
    loop(running,Docs,R,T,{Worker,Navigator,supports_file_watch(Request)});
dispatch(#{<<"method">> := <<"initialized">>}, running, Docs, R, T, {Worker,Navigator,true}) ->
    register_file_watch(),
    loop(running,Docs,R,T,{Worker,Navigator,false});
dispatch(#{<<"method">> := <<"$/cancelRequest">>, <<"params">> := #{<<"id">> := Id}},
         running, Docs, R, T, Analyzer) ->
    case remove_navigation(Id) of
        true -> error_response(Id,-32800,<<"Request cancelled">>);
        false -> ok
    end,
    loop(running,Docs,R,T,Analyzer);
dispatch(#{<<"method">> := <<"workspace/didChangeWorkspaceFolders">>,
           <<"params">> := #{<<"event">> := #{<<"added">> := Added,<<"removed">> := Removed}}},
         running, Docs, R, T, Analyzer) when is_list(Added), is_list(Removed) ->
    {_,Roots} = get(lsp_workspace_roots),
    Next = lists:usort(folder_paths(Added) ++ (Roots -- folder_paths(Removed))),
    put(lsp_workspace_roots,{explicit,Next}),
    changed(Docs,R,T,Analyzer);
dispatch(#{<<"method">> := <<"workspace/didChangeWatchedFiles">>,
           <<"params">> := #{<<"changes">> := Changes}}, running, Docs, R, T, Analyzer)
  when is_list(Changes), Changes =/= [] ->
    changed(Docs,R,T,Analyzer);
dispatch(#{<<"id">> := <<"pooka-watch-files">>}=Response, running, Docs, R, T, Analyzer)
  when not is_map_key(<<"method">>,Response) ->
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
dispatch(#{<<"method">> := <<"workspace/symbol">>, <<"id">> := Id,
           <<"params">> := #{<<"query">> := Query}}, running, Docs, R, T, Analyzer)
  when is_binary(Query) ->
    {_,Navigator,_} = Analyzer,
    enqueue_navigation(Navigator,R,Id,{workspace_symbols,Query,get(lsp_workspace_roots),Docs}),
    loop(running,Docs,R,T,Analyzer);
dispatch(#{<<"method">> := <<"textDocument/semanticTokens/full">>, <<"id">> := Id,
           <<"params">> := #{<<"textDocument">> := #{<<"uri">> := Uri}}}, running, Docs, R, T, Analyzer) ->
    Data = case maps:find(Uri,Docs) of
        {ok,{Path,_,Source}} -> semantic_data('tools@lsp@semantic':tokens(Path,Source),Source);
        error -> []
    end,
    reply(Id,#{data => Data}),
    loop(running,Docs,R,T,Analyzer);
dispatch(#{<<"method">> := <<"textDocument/codeLens">>, <<"id">> := Id,
           <<"params">> := #{<<"textDocument">> := #{<<"uri">> := Uri}}}, running, Docs, R, T, Analyzer) ->
    Lenses = case maps:find(Uri,Docs) of
        {ok,{Path,_,Source}} -> test_lenses(Uri,Path,Source);
        error -> []
    end,
    reply(Id,Lenses),
    loop(running,Docs,R,T,Analyzer);
dispatch(#{<<"method">> := <<"workspace/executeCommand">>, <<"id">> := Id,
           <<"params">> := #{<<"command">> := <<"pooka.runTest">>,
                            <<"arguments">> := [Uri,Name]}}, running, Docs, R, T, Analyzer)
  when is_binary(Uri), is_binary(Name) ->
    start_test(Id,Uri,Name,Docs),
    loop(running,Docs,R,T,Analyzer);
dispatch(#{<<"method">> := <<"textDocument/documentSymbol">>, <<"id">> := Id,
           <<"params">> := #{<<"textDocument">> := #{<<"uri">> := Uri}}}, running, Docs, R, T, Analyzer) ->
    Symbols = case maps:find(Uri,Docs) of
        {ok,{Path,_,Source}} ->
            Raw = json:decode('tools@lsp@symbols':outline(Path,Source)),
            [symbol_ranges(Symbol,Source) || Symbol <- Raw];
        error -> []
    end,
    reply(Id,Symbols), loop(running,Docs,R,T,Analyzer);
dispatch(#{<<"method">> := <<"textDocument/rename">>, <<"id">> := Id,
           <<"params">> := #{<<"textDocument">> := #{<<"uri">> := Uri},
                            <<"position">> := Position,<<"newName">> := Name}},
         running, Docs, R, T, Analyzer) when is_binary(Name) ->
    case get(lsp_versioned_edits) of
        true ->
            {_,Navigator,_} = Analyzer,
            enqueue_navigation(Navigator,R,Id,{document,{rename,Name,Docs},Uri,Position,Docs});
        _ -> error_response(Id,-32602,<<"Rename requires versioned workspace edits">>)
    end,
    loop(running,Docs,R,T,Analyzer);
dispatch(#{<<"method">> := <<"textDocument/references">>, <<"id">> := Id,
           <<"params">> := #{<<"textDocument">> := #{<<"uri">> := Uri},
                            <<"position">> := Position,<<"context">> := Context}},
         running, Docs, R, T, Analyzer) ->
    {_,Navigator,_} = Analyzer,
    Include = maps:get(<<"includeDeclaration">>,Context,false),
    enqueue_navigation(Navigator,R,Id,{document,{references,Include},Uri,Position,Docs}),
    loop(running,Docs,R,T,Analyzer);
dispatch(#{<<"method">> := Method, <<"id">> := Id,
           <<"params">> := #{<<"textDocument">> := #{<<"uri">> := Uri},
                            <<"position">> := Position}}, running, Docs, R, T, Analyzer)
  when Method =:= <<"textDocument/typeDefinition">>; Method =:= <<"textDocument/documentHighlight">>;
       Method =:= <<"textDocument/definition">>; Method =:= <<"textDocument/hover">>;
       Method =:= <<"textDocument/completion">>;
       Method =:= <<"textDocument/signatureHelp">>;
       Method =:= <<"textDocument/prepareRename">> ->
    {_,Navigator,_} = Analyzer,
    enqueue_navigation(Navigator,R,Id,{document,Method,Uri,Position,Docs}),
    loop(running,Docs,R,T,Analyzer);
dispatch(#{<<"method">> := <<"textDocument/codeAction">>, <<"id">> := Id,
           <<"params">> := #{<<"textDocument">> := #{<<"uri">> := Uri},
                            <<"range">> := Range, <<"context">> := Context}},
         running, Docs, R, T, Analyzer) ->
    reply(Id,quick_fixes(Uri,Range,Context,R)),
    loop(running,Docs,R,T,Analyzer);
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

test_lenses(Uri,Path,Source) ->
    case filename:extension(Path) =:= <<".pooka">> andalso
         filename:extension(filename:rootname(Path)) =:= <<".spec">> of
        false -> [];
        true ->
            [#{range => offset_range(Start,End,Source),
               command => #{title => <<"Run test">>,command => <<"pooka.runTest">>,
                            arguments => [Uri,Name]}}
             || {Name,Start,End} <- 'tools@lsp@symbols':test_lenses(Path,Source)]
    end.

start_test(Id,Uri,Name,Docs) ->
    case {get(lsp_test_worker),maps:find(Uri,Docs)} of
        {undefined,{ok,{Path,_,Source}}} ->
            Allowed = [Test || #{command := #{arguments := [_,Test]}} <- test_lenses(Uri,Path,Source)],
            case {lists:member(Name,Allowed),file:read_file(Path)} of
                {true,{ok,Source}} ->
                    Server = self(),
                    Pid = spawn(fun() ->
                        Result = try pooka_lsp_test_ffi:run(Path,Name)
                                 catch _:_ -> {error,<<"Could not start Pooka tests">>} end,
                        Server ! {test_result,self(),Id,Result}
                    end),
                    put(lsp_test_worker,Pid);
                {true,_} -> error_response(Id,-32602,<<"Save the test file before running it">>);
                _ -> error_response(Id,-32602,<<"No runnable test with that name in this document">>)
            end;
        {undefined,_} -> error_response(Id,-32602,<<"Open the test document first">>);
        _ -> error_response(Id,-32602,<<"A Pooka test is already running">>)
    end.

finish_test(Id,{ok,Status,Output}) ->
    Type = case Status of 0 -> 3; _ -> 1 end,
    send(#{method => <<"window/logMessage">>,params => #{type => Type,message => Output}}),
    reply(Id,#{exitCode => Status,output => Output});
finish_test(Id,{error,Message}) ->
    error_response(Id,-32603,Message).

semantic_data(Tokens,Source) ->
    {Parts,_} = lists:mapfoldl(fun({Start,End,Kind,Modifiers},Previous) ->
        Gap = binary:part(Source,Previous,Start-Previous),
        #{line := DeltaLine,character := DeltaColumn} =
            position(#{<<"byte_offset">> => byte_size(Gap)},Gap),
        Name = binary:part(Source,Start,End-Start),
        #{character := Length} = position(#{<<"byte_offset">> => byte_size(Name)},Name),
        {[DeltaLine,DeltaColumn,Length,Kind,Modifiers],Start}
    end,0,Tokens),
    lists:append(Parts).

workspace_roots(Request) ->
    Params = maps:get(<<"params">>,Request,#{}),
    case maps:get(<<"workspaceFolders">>,Params,null) of
        Entries when is_list(Entries) -> {explicit,folder_paths(Entries)};
        _ -> {fallback,folder_paths([#{<<"uri">> => maps:get(<<"rootUri">>,Params,null)}])}
    end.

folder_paths(Entries) ->
    lists:usort([Path || #{<<"uri">> := Uri} <- Entries, is_binary(Uri),
                        {ok,Path} <- [file_path(Uri)]]).

workspace_symbols(Query,{Mode,Roots},Docs) ->
    Open = [{Uri,Path,Source} || {Uri,{Path,_,Source}} <- maps:to_list(Docs)],
    Overlays = [{Path,Source} || {_,Path,Source} <- Open],
    Uris = maps:from_list([{Path,Uri} || {Uri,Path,_} <- Open]),
    FolderProbes = [filename:join(Root,<<"workspace.pooka">>) || Root <- Roots],
    Probes = case Mode of
        explicit -> FolderProbes;
        fallback -> FolderProbes ++ [Path || {_,Path,_} <- Open]
    end,
    Files = 'tools@lsp@symbols':workspace(Probes,Overlays),
    Folded = string:casefold(Query),
    lists:sublist(lists:append([
        collect_symbols(json:decode(Outline),Namespace,maps:get(Path,Uris,file_uri(Path)),Text,Folded)
        || {Path,Namespace,Text,Outline} <- Files
    ]),250).

collect_symbols(Symbols,Namespace,Uri,Source,Query) ->
    lists:flatmap(fun(#{<<"name">> := Name,<<"kind">> := Kind,
                        <<"selectionRange">> := Selection,<<"children">> := Children}) ->
        Qualified = <<Namespace/binary,".",Name/binary>>,
        Match = case Query =:= <<>> orelse string:find(string:casefold(Qualified),Query) =/= nomatch of
            true -> [#{name => Name,kind => Kind,containerName => Namespace,
                       location => #{uri => Uri,range => lsp_range(Selection,Source)}}];
            false -> []
        end,
        Match ++ collect_symbols(Children,Qualified,Uri,Source,Query)
    end,Symbols).

supports_versioned_edits(#{<<"params">> := #{<<"capabilities">> :=
                         #{<<"workspace">> := #{<<"workspaceEdit">> :=
                         #{<<"documentChanges">> := true}}}}}) -> true;
supports_versioned_edits(_) -> false.

quick_fixes(Uri,Range,Context,Revision) ->
    Only = maps:get(<<"only">>,Context,[<<"quickfix">>]),
    case {get(lsp_versioned_edits),get(lsp_quick_fixes),lists:member(<<"quickfix">>,Only)} of
        {true,{Revision,ByUri},true} ->
            [Action || {DiagnosticRange,Action} <- maps:get(Uri,ByUri,[]),
                       intersects(Range,DiagnosticRange)];
        _ -> []
    end.

intersects(#{<<"start">> := Start,<<"end">> := End},#{start := From,'end' := To}) ->
    point(Start) =< point(To) andalso point(End) >= point(From);
intersects(_,_) -> false.

point(#{<<"line">> := Line,<<"character">> := Column}) -> {Line,Column};
point(#{line := Line,character := Column}) -> {Line,Column};
point(_) -> {-1,-1}.

supports_file_watch(Request) ->
    case Request of
        #{<<"params">> := #{<<"capabilities">> := #{<<"workspace">> :=
            #{<<"didChangeWatchedFiles">> := #{<<"dynamicRegistration">> := true}}}}} -> true;
        _ -> false
    end.

%% Register only after the client has finished initialization. Editors that
%% cannot register file watchers still refresh on ordinary document events.
register_file_watch() ->
    Watchers = [#{globPattern => Glob} ||
                Glob <- [<<"**/pooka.toml">>, <<"**/pooka.lock">>, <<"**/*.pooka">>]],
    send(#{id => <<"pooka-watch-files">>,method => <<"client/registerCapability">>,
           params => #{registrations => [#{id => <<"pooka-watch-files">>,
               method => <<"workspace/didChangeWatchedFiles">>,
               registerOptions => #{watchers => Watchers}}]}}).

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
    [begin
        Items = for_document(Path,Root,Source,Open,Diagnostics),
        Actions = lists:append([quick_fix_edits(Value,Item,Path,Root,Uri,Version,Source)
                                || {Value,Item} <- Items]),
        {Uri,Version,[Item || {_,Item} <- Items],Actions}
     end || {Uri,Path,Version,Source} <- Files];
analyze_group(_,Files) -> [{Uri,Version,[],[]} || {Uri,_,Version,_} <- Files].

for_document(Path,Root,Source,Open,Diagnostics) ->
    lists:filtermap(fun(Diagnostic) ->
        Labels = maps:get(<<"labels">>,Diagnostic,[]),
        case [Location || #{<<"importance">> := <<"primary">>,
                            <<"location">> := #{<<"path">> := File}=Location} <- Labels,
                          filename:absname(File,Root) =:= Path] of
            [Location|_] ->
                Others = [Label || #{<<"location">> := At} = Label <- Labels, At =/= Location],
                Related = lists:filtermap(fun(Label) -> related(Label,Root,Open) end,Others),
                {true,{Diagnostic,diagnostic(Diagnostic,Location,Source,Related)}};
            [] when Labels =:= [] -> {true,{Diagnostic,diagnostic(Diagnostic,#{},Source,[])}};
            [] -> false
        end
    end,Diagnostics).

quick_fix_edits(Value,Item,Path,Root,Uri,Version,Source) ->
    [{maps:get(range,Item),
      #{title => Title,kind => <<"quickfix">>,diagnostics => [Item],
        edit => #{documentChanges => [
            #{textDocument => #{uri => Uri,version => Version},
              edits => [#{range => lsp_range(Location,Source),newText => Replacement}]}
        ]}}}
     || #{<<"location">> := #{<<"path">> := File}=Location,
          <<"description">> := Title,<<"replacement">> := Replacement,
          <<"applicability">> := Applicability} <- maps:get(<<"fixes">>,Value,[]),
        Applicability =:= <<"automatic">> orelse Applicability =:= <<"suggested">>,
        filename:absname(File,Root) =:= Path].

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

navigation(Query,Uri,Position,Docs) ->
    Open = maps:from_list([{Path,{DocUri,Source}} ||
                           {DocUri,{Path,_,Source}} <- maps:to_list(Docs)]),
    case maps:find(Uri,Docs) of
        {ok,{Path,_,Source}} ->
            case byte_offset(Position,Source) of
                {ok,Offset} ->
                    Overlays = [{P,S} || {P,{_,S}} <- maps:to_list(Open)],
                    execute_navigation(Query,Path,Source,Offset,Overlays,Open);
                error -> null
            end;
        error -> null
    end.

execute_navigation(<<"textDocument/prepareRename">>,Path,Source,Offset,Overlays,_) ->
    case 'tools@lsp@rename':prepare(Path,Offset,Overlays) of
        {ok,{Start,End,Name}} -> #{range => offset_range(Start,End,Source),placeholder => Name};
        {error,_} -> null
    end;
execute_navigation({rename,Name,Docs},Path,_,Offset,Overlays,Open) ->
    case 'tools@lsp@rename':edits(Path,Offset,Name,Overlays) of
        {error,Message} -> {request_error,Message};
        {ok,Edits} ->
            case rename_changes(Edits,Name,Docs,Open) of
                {ok,Changes} -> #{documentChanges => Changes};
                error -> {request_error,<<"A source file changed before rename completed">>}
            end
    end;
execute_navigation(<<"textDocument/documentHighlight">>,Path,Source,Offset,Overlays,_) ->
    [#{range => offset_range(Start,End,Source),kind => 1}
     || {Target,Start,End} <- 'tools@lsp@references':locations(Path,Offset,Overlays,true),
        Target =:= Path];
execute_navigation({references,Include},Path,_,Offset,Overlays,Open) ->
    Locations = 'tools@lsp@references':locations(Path,Offset,Overlays,Include =:= true),
    lists:filtermap(fun({Target,Start,End}) -> navigation_location(Target,Start,End,Open) end,Locations);
execute_navigation(<<"textDocument/signatureHelp">>,Path,Source,Offset,Overlays,_) ->
    case 'tools@lsp@signature':help(Path,Source,Offset,Overlays) of
        {ok,{Label,Labels,Active}} ->
            #{signatures => [#{label => Label,parameters => [#{label => Parameter} || Parameter <- Labels]}],
              activeSignature => 0,activeParameter => Active};
        {error,_} -> null
    end;
execute_navigation(<<"textDocument/completion">>,Path,Source,Offset,Overlays,_) ->
    case 'tools@lsp@completion':complete(Path,Source,Offset,Overlays) of
        {ok,{Start,End,Names}} ->
            Range = #{start => position(#{<<"byte_offset">> => Start},Source),
                      'end' => position(#{<<"byte_offset">> => End},Source)},
            [#{label => Name,textEdit => #{range => Range,newText => Name}} || Name <- Names];
        {error,_} -> []
    end;
execute_navigation(<<"textDocument/hover">>,Path,Source,Offset,Overlays,_) ->
    case 'tools@lsp@definition':hover(Path,Source,Offset,Overlays) of
        {ok,Markdown} -> #{contents => #{kind => <<"markdown">>,value => Markdown}};
        {error,_} -> null
    end;
execute_navigation(<<"textDocument/typeDefinition">>,Path,Source,Offset,Overlays,Open) ->
    navigation_target('tools@lsp@definition':type_target(Path,Source,Offset,Overlays),Open);
execute_navigation(<<"textDocument/definition">>,Path,Source,Offset,Overlays,Open) ->
    navigation_target('tools@lsp@definition':target(Path,Source,Offset,Overlays),Open).

navigation_target(Result,Open) ->
    case Result of
        {ok,{Target,Start,End}} ->
            case navigation_location(Target,Start,End,Open) of
                {true,Location} -> Location;
                false -> null
            end;
        {error,_} -> null
    end.

rename_changes(Edits,Name,Docs,Open) ->
    try
        ByUri = lists:foldl(fun({Path,Start,End,Text},Acc) ->
            Uri = case related_source(Path,Open) of
                {ok,FileUri,Text} -> FileUri;
                _ -> throw(stale_rename_source)
            end,
            Edit = #{range => offset_range(Start,End,Text),newText => Name},
            maps:update_with(Uri,fun(Items) -> [Edit|Items] end,[Edit],Acc)
        end,#{},Edits),
        {ok,[#{textDocument => #{uri => Uri,version => case maps:find(Uri,Docs) of
                                    {ok,{_,Version,_}} -> Version;
                                    error -> null
                                end},edits => Items}
             || {Uri,Items} <- maps:to_list(ByUri)]}
    catch throw:stale_rename_source -> error end.

offset_range(Start,End,Source) ->
    #{start => position(#{<<"byte_offset">> => Start},Source),
      'end' => position(#{<<"byte_offset">> => End},Source)}.

navigation_location(Target,Start,End,Open) ->
    case related_source(Target,Open) of
        {ok,TargetUri,Text} ->
            {true,#{uri => TargetUri,range => lsp_range(
                #{<<"start">> => #{<<"byte_offset">> => Start},
                  <<"end">> => #{<<"byte_offset">> => End}},Text)}};
        error -> false
    end.

byte_offset(#{<<"line">> := Line,<<"character">> := Character},Source)
  when is_integer(Line), Line >= 0, is_integer(Character), Character >= 0 ->
    Lines = binary:split(Source,<<"\n">>,[global]),
    case length(Lines) > Line of
        false -> error;
        true ->
            {Before,[Text|_]} = lists:split(Line,Lines),
            Utf16 = unicode:characters_to_binary(Text,utf8,{utf16,little}),
            Bytes = Character * 2,
            case is_binary(Utf16) andalso byte_size(Utf16) >= Bytes of
                false -> error;
                true ->
                    case unicode:characters_to_binary(binary:part(Utf16,0,Bytes),{utf16,little},utf8) of
                        Prefix when is_binary(Prefix) -> {ok,iolist_size(Before) + Line + byte_size(Prefix)};
                        _ -> error
                    end
            end
    end;
byte_offset(_,_) -> error.

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
