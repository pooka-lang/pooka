%% SPDX-License-Identifier: Apache-2.0

%%% Unpack and inspect the neighbours at the boundary.
%%%
%%% Provide package transport, archives and external-process operations that need
%%% Erlang facilities. Keep source selection and dependency solving in the Gleam
%%% project layer.
%%%
%%% ```text
%%% verified package archive -> source directory
%%% ```

-module(pooka_package_ffi).
-export([canonical/1, write_atomic/2, git_url/2, git_checkout/5, http_get/1, hex_unpack/3, hex_cached/2, native_build/6, stage_library/4, native_directory/1, using_directory/2, repository_identity/1]).
canonical(Path) ->
    try
        Absolute = filename:absname(unicode:characters_to_list(Path)),
        Resolved = resolve(filename:split(Absolute), "", 40),
        case filelib:is_dir(Resolved) of
            true -> {ok, unicode:characters_to_binary(Resolved)};
            false -> {error, unicode:characters_to_binary(["Dependency directory does not exist: ", Resolved])}
        end
    catch Class:Reason -> {error, unicode:characters_to_binary(io_lib:format("~tp:~tp",[Class,Reason]))} end.
resolve([], Path, _) -> Path;
resolve(["." | Rest], Path, Limit) -> resolve(Rest, Path, Limit);
resolve([".." | Rest], Path, Limit) -> resolve(Rest, filename:dirname(Path), Limit);
resolve([Part | Rest], Path, Limit) ->
    Next = case Path of "" -> Part; _ -> filename:join(Path,Part) end,
    case file:read_link(Next) of
        {ok, Link} when Limit > 0 ->
            Target = filename:absname(Link,filename:dirname(Next)),
            resolve(filename:split(Target) ++ Rest, "", Limit - 1);
        {ok, _} -> erlang:error(too_many_symbolic_links);
        _ -> resolve(Rest,Next,Limit)
    end.



%% Write a temporary file beside the destination and publish it through the module's
%% replacement path. Keep partial bytes out of the final file.
write_atomic(PathBinary, Text) ->
    Path = unicode:characters_to_list(PathBinary),
    case file:read_file(Path) of
        {ok, Text} -> {ok,nil};
        _ ->
            Stage = Path ++ ".tmp-" ++ os:getpid() ++ "-" ++ integer_to_list(erlang:unique_integer([positive])),
            case file:make_dir(Stage) of
                ok ->
                    Temporary = filename:join(Stage,"lock"),
                    try
                        ok = file:write_file(Temporary,Text),
                        ok = file:rename(Temporary,Path),
                        {ok,nil}
                    catch Class:Reason -> {error,unicode:characters_to_binary(io_lib:format("~tp:~tp",[Class,Reason]))}
                    after file:del_dir_r(Stage) end;
                {error,Reason} -> {error,unicode:characters_to_binary(file:format_error(Reason))}
            end
    end.



git_url(Owner, URL) ->
    Text = unicode:characters_to_list(URL),
    case string:find(Text,":") of
        nomatch -> unicode:characters_to_binary(lexical(filename:split(filename:absname(Text,unicode:characters_to_list(Owner))),""));
        _ -> URL
    end.
lexical([],Path) -> Path;
lexical(["."|Rest],Path) -> lexical(Rest,Path);
lexical([".."|Rest],Path) -> lexical(Rest,filename:dirname(Path));
lexical([Part|Rest],"") -> lexical(Rest,Part);
lexical([Part|Rest],Path) -> lexical(Rest,filename:join(Path,Part)).




%% Resolve and stage the selected Git source through the package cache boundary.
git_checkout(CacheBinary,NameBinary,URLBinary,RefBinary,Pin) ->
    try
        Cache = unicode:characters_to_list(CacheBinary),
        Name = unicode:characters_to_list(NameBinary),
        URL = unicode:characters_to_list(URLBinary),
        Reference = unicode:characters_to_list(RefBinary),
        Key = Name ++ "-" ++ lists:sublist(hex(crypto:hash(sha256,repository_identity(URLBinary))),16),
        ok = filelib:ensure_dir(filename:join(Cache,"placeholder")),
        case Pin of
            {some, RevisionBinary} ->
                Revision = unicode:characters_to_list(RevisionBinary),
                Destination = filename:join(Cache,Key ++ "-" ++ Revision),
                case filelib:is_dir(Destination) of
                    true -> verify_checkout(Destination,Revision), {ok,{unicode:characters_to_binary(Destination),RevisionBinary}};
                    false -> clone_checkout(Cache,Key,URL,Reference,Revision)
                end;
            none -> clone_checkout(Cache,Key,URL,Reference,none)
        end
    catch throw:{package_error,Reason} -> {error,binary:replace(Reason,URLBinary,repository_identity(URLBinary),[global])};
          Class:Reason -> {error,unicode:characters_to_binary(io_lib:format("Git dependency failed: ~tp:~tp",[Class,Reason]))} end.

clone_checkout(Cache,Key,URL,Reference,Pin) ->
    Name=lists:sublist(Key,length(Key)-17),
    pooka_progress_ffi:run(unicode:characters_to_binary(Name ++ " (git)"),fun() -> clone_checkout_inner(Cache,Key,URL,Reference,Pin) end).
clone_checkout_inner(Cache,Key,URL,Reference,Pin) ->
    Stage = fresh_directory(Cache,"git-stage"),
    Repo = filename:join(Stage,"repository"),
    try
        git(Cache,["clone","--no-checkout","--",URL,Repo]),
        Target = case Pin of
            none -> case Reference of
                "head" -> "HEAD";
                "branch:" ++ Branch -> "refs/remotes/origin/" ++ Branch;
                "tag:" ++ Tag -> "refs/tags/" ++ Tag;
                "rev:" ++ Rev ->
                    case valid_revision(Rev) of true -> Rev; false -> package_fail("Git rev must be a hexadecimal commit identifier") end
            end;
            Locked -> Locked
        end,
        RevisionOutput = try git(Repo,["rev-parse","--verify","--end-of-options",Target ++ "^{commit}"])
            catch throw:{package_error,_} when Pin =/= none ->
                git(Repo,["fetch","--no-tags","origin",Pin]),
                git(Repo,["rev-parse","--verify","--end-of-options",Pin ++ "^{commit}"])
            end,
        Revision = string:trim(unicode:characters_to_list(RevisionOutput)),
        true = valid_revision(Revision),
        git(Repo,["checkout","--detach",Revision,"--"]),
        git(Repo,["remote","set-url","origin",unicode:characters_to_list(repository_identity(unicode:characters_to_binary(URL)))]),
        Destination = filename:join(Cache,Key ++ "-" ++ Revision),
        case file:rename(Repo,Destination) of
            ok -> ok;
            {error,eexist} -> verify_checkout(Destination,Revision);
            {error,enotempty} -> verify_checkout(Destination,Revision);
            {error,Reason} -> package_fail(file:format_error(Reason))
        end,
        {ok,{unicode:characters_to_binary(Destination),unicode:characters_to_binary(Revision)}}
    after file:del_dir_r(Stage) end.

%% Check the materialized checkout against the expected repository/revision information.
verify_checkout(Directory,Revision) ->
    Actual = string:trim(unicode:characters_to_list(git(Directory,["rev-parse","HEAD"]))),
    case Actual =:= Revision andalso git(Directory,["status","--porcelain","--untracked-files=all","--ignored"]) =:= <<>> of
        true -> ok;
        false -> package_fail("Cached Git checkout was modified. Remove its build/packages directory before resolving again.")
    end.
valid_revision(Revision) ->
    (length(Revision) >= 7 andalso length(Revision) =< 64) andalso
        lists:all(fun(C) -> (C >= $0 andalso C =< $9) orelse (C >= $a andalso C =< $f) orelse (C >= $A andalso C =< $F) end,Revision).
hex(Binary) -> lists:flatten([io_lib:format("~2.16.0b",[Byte]) || <<Byte>> <= Binary]).
fresh_directory(Root,Prefix) ->
    Path = filename:join(Root,Prefix ++ "-" ++ os:getpid() ++ "-" ++ integer_to_list(erlang:unique_integer([positive]))),
    case file:make_dir(Path) of ok -> Path; {error,eexist} -> fresh_directory(Root,Prefix); {error,R} -> package_fail(file:format_error(R)) end.
package_fail(Reason) -> throw({package_error,unicode:characters_to_binary(Reason)}).
git(Directory,Arguments) -> run_tool("git",Directory,Arguments).
%% Run an external package tool with explicit arguments and recover its status/output for
%% project diagnostics.
run_tool(Program,Directory,Arguments) ->
    case os:find_executable(Program) of
        false -> package_fail(["Required dependency tool is missing: ",Program]);
        Executable ->
            Port = open_port({spawn_executable,Executable},[binary,exit_status,stderr_to_stdout,
                {cd,Directory},{env,[{"GIT_TERMINAL_PROMPT","0"}]},{args,Arguments}]),
            tool_output(Port,[],Program)
    end.
tool_output(Port,Parts,Program) ->
    receive
        {Port,{data,Data}} -> tool_output(Port,[Data|Parts],Program);
        {Port,{exit_status,0}} -> iolist_to_binary(lists:reverse(Parts));
        {Port,{exit_status,Status}} -> package_fail(io_lib:format("~ts failed (status ~p): ~ts",[Program,Status,iolist_to_binary(lists:reverse(Parts))]))
    after 60000 -> port_close(Port),package_fail([Program," timed out"]) end.

http_get(URLBinary) ->
    URL=unicode:characters_to_list(URLBinary),
    case lists:suffix(".tar",URL) of
        true -> pooka_progress_ffi:run(unicode:characters_to_binary(filename:basename(URL)),fun()->http_get_inner(URLBinary) end);
        false -> http_get_inner(URLBinary)
    end.
http_get_inner(URLBinary) ->
    try
        URL = unicode:characters_to_list(URLBinary),
        #{scheme := "https",host := Host} = uri_string:parse(URL),
        {ok,_} = application:ensure_all_started(inets),
        {ok,_} = application:ensure_all_started(ssl),
        SSL = [{verify,verify_peer},{cacerts,public_key:cacerts_get()},
               {server_name_indication,Host},
               {customize_hostname_check,[{match_fun,public_key:pkix_verify_hostname_match_fun(https)}]}],
        case httpc:request(get,{URL,[{"accept","application/json"},{"user-agent","pooka/0.1"}]},
                          [{timeout,30000},{connect_timeout,10000},{ssl,SSL},{autoredirect,false}], [{body_format,binary}]) of
            {ok,{{_,200,_},_,Body}} -> {ok,Body};
            {ok,{{_,Status,_},_,_}} -> package_fail(io_lib:format("Hex HTTP ~p for ~ts",[Status,URL]));
            {error,Reason} -> package_fail(io_lib:format("Hex request failed: ~tp",[Reason]))
        end
    catch throw:{package_error,Error} -> {error,Error};
          Class:Reason0 -> {error,unicode:characters_to_binary(io_lib:format("Hex request failed: ~tp:~tp",[Class,Reason0]))} end.



%% Validate and unpack a registry archive into a staged package directory.
hex_unpack(Bytes,Checksum,DestinationBinary) ->
    try
        Expected = string:lowercase(unicode:characters_to_list(Checksum)),
        case hex(crypto:hash(sha256,Bytes)) =:= Expected of
            true -> ok;
            false -> package_fail("Hex archive checksum mismatch")
        end,
        {ok,Outer} = erl_tar:extract({binary,Bytes},[memory]),
        {"VERSION",<<"3">>} = lists:keyfind("VERSION",1,Outer),
        {"metadata.config",Metadata} = lists:keyfind("metadata.config",1,Outer),
        {"contents.tar.gz",Contents} = lists:keyfind("contents.tar.gz",1,Outer),
        {"CHECKSUM",Inner} = lists:keyfind("CHECKSUM",1,Outer),
        InnerExpected = string:lowercase(string:trim(unicode:characters_to_list(Inner))),
        case hex(crypto:hash(sha256,[<<"3">>,Metadata,Contents])) =:= InnerExpected of
            true -> ok; false -> package_fail("Hex inner checksum mismatch")
        end,
        {ok,Table} = erl_tar:table({binary,Contents},[compressed,verbose]),
        lists:foreach(fun({Name,Type,_,_,_,_,_}) ->
            safe_archive_path(Name),
            case Type of regular -> ok; directory -> ok; _ -> package_fail("Hex archives containing links or special files are unsupported") end
        end,Table),
        {ok,Files} = erl_tar:extract({binary,Contents},[memory,compressed]),
        Normalized = [{safe_archive_path(Name),Data} || {Name,Data} <- Files],
        Names = [Name || {Name,_} <- Normalized],
        case length(Names) =:= length(lists:usort(Names)) andalso not lists:member(".pooka-hex",Names) andalso not lists:member(".pooka-hex.tar",Names) of
            true -> ok; false -> package_fail("Duplicate or reserved Hex archive path")
        end,
        Destination = unicode:characters_to_list(DestinationBinary),
        Cache = filename:dirname(Destination),
        ok = filelib:ensure_dir(filename:join(Cache,"placeholder")),
        Stage = fresh_directory(Cache,"hex-stage"),
        try
            lists:foreach(fun({Name,Data}) ->
                File = filename:join(Stage,Name),
                ok = filelib:ensure_dir(File), ok = file:write_file(File,Data)
            end,Normalized),
            Manifest = [{Name,crypto:hash(sha256,Data)} || {Name,Data} <- Normalized],
            ok = file:write_file(filename:join(Stage,".pooka-hex"),term_to_binary({Expected,Manifest})),
            ok = file:write_file(filename:join(Stage,".pooka-hex.tar"),Bytes),
            case file:rename(Stage,Destination) of
                ok -> ok;
                {error,eexist} -> {ok,true} = hex_cached(DestinationBinary,Checksum);
                {error,enotempty} -> {ok,true} = hex_cached(DestinationBinary,Checksum);
                {error,R} -> package_fail(file:format_error(R))
            end,
            {ok,nil}
        after file:del_dir_r(Stage) end
    catch throw:{package_error,Error} -> {error,Error};
          Class:Reason -> {error,unicode:characters_to_binary(io_lib:format("Invalid Hex archive: ~tp:~tp",[Class,Reason]))} end.

%% Reject archive paths that would escape the intended package root under this path-
%% validation policy.
safe_archive_path(Name) ->
    Parts = string:split(Name,"/",all),
    case filename:pathtype(Name) =:= relative andalso
         string:find(Name,"\\") =:= nomatch andalso string:find(Name,":") =:= nomatch andalso
         not lists:member(0,Name) andalso not lists:member("..",Parts) of
        true ->
            Clean = [Part || Part <- Parts, Part =/= "",Part =/= "."],
            case Clean of [] -> package_fail("Empty Hex archive path"); _ -> filename:join(Clean) end;
        false -> package_fail("Unsafe Hex archive path")
    end.


hex_cached(DestinationBinary,Checksum) ->
    Directory = unicode:characters_to_list(DestinationBinary),
    case file:read_file(filename:join(Directory,".pooka-hex.tar")) of
        {error,enoent} ->
            case filelib:is_dir(Directory) of true -> {error,<<"Unverified Hex cache directory; remove it before resolving">>}; false -> {ok,false} end;
        {error,R} -> {error,unicode:characters_to_binary(file:format_error(R))};
        {ok,Raw} ->
            try
                true = hex(crypto:hash(sha256,Raw)) =:= string:lowercase(unicode:characters_to_list(Checksum)),
                {ok,Outer} = erl_tar:extract({binary,Raw},[memory]),
                {"contents.tar.gz",Contents} = lists:keyfind("contents.tar.gz",1,Outer),
                {ok,Files} = erl_tar:extract({binary,Contents},[memory,compressed]),
                Names = lists:sort([safe_archive_path(Name) || {Name,_} <- Files]),
                true = lists:sort(cache_files(Directory,"")) =:= lists:sort([".pooka-hex",".pooka-hex.tar"|Names]),
                lists:foreach(fun({Name,Expected}) ->
                    {ok,Data} = file:read_file(filename:join(Directory,safe_archive_path(Name))),
                    true = crypto:hash(sha256,Data) =:= crypto:hash(sha256,Expected)
                end,Files),
                {ok,true}
            catch _:_ -> {error,<<"Hex cache checksum/source verification failed; remove the modified cache before resolving">>} end
    end.
cache_files(Root,Relative) ->
    Path = case Relative of "" -> Root; _ -> filename:join(Root,Relative) end,
    {ok,Info} = file:read_link_info(Path),
    case element(3,Info) of
        directory -> {ok,Names} = file:list_dir(Path),lists:append([cache_files(Root,case Relative of "" -> Name; _ -> filename:join(Relative,Name) end) || Name <- Names]);
        regular -> [Relative];
        _ -> erlang:error(unsafe_hex_cache_entry)
    end.

stage_library(LibraryBinary,NameBinary,Modules,Resource) ->
    try
        Ebin = filename:join([unicode:characters_to_list(LibraryBinary),unicode:characters_to_list(NameBinary),"ebin"]),
        ok = filelib:ensure_dir(filename:join(Ebin,"placeholder")),
        lists:foreach(fun({Name,Beam}) -> ok = file:write_file(filename:join(Ebin,unicode:characters_to_list(Name) ++ ".beam"),Beam) end,Modules),
        ok = file:write_file(filename:join(Ebin,unicode:characters_to_list(NameBinary) ++ ".app"),Resource),
        {ok,nil}
    catch Class:Reason -> {error,unicode:characters_to_binary(io_lib:format("Native library staging failed: ~tp:~tp",[Class,Reason]))} end.

native_build(RootBinary,LibraryBinary,NameBinary,AppBinary,VersionBinary,ToolBinaries) ->
    try
        Root = unicode:characters_to_list(RootBinary), Library = unicode:characters_to_list(LibraryBinary),
        _Name = unicode:characters_to_list(NameBinary), App = binary_to_atom(AppBinary,utf8),
        Output = filename:join(Library,atom_to_list(App)), Ebin = filename:join(Output,"ebin"),
        
        case file:read_link_info(Output) of {ok,_} -> ok = file:del_dir_r(Output); {error,enoent} -> ok end,
        ok = filelib:ensure_dir(filename:join(Ebin,"placeholder")),
        copy_native_headers(filename:join(Root,"include"),filename:join(Output,"include")),
        Tools = [unicode:characters_to_list(T) || T <- ToolBinaries],
        case lists:member("gleam",Tools) of
            true ->
                run_tool("gleam",Root,["compile-package","--target","erlang","--package",Root,"--out",Output,"--lib",Library]),
                remove_generated_erlang(Output);
            false ->
                case filelib:is_dir(filename:join(Root,"c_src")) orelse filelib:is_file(filename:join(Root,"rebar.config.script")) of
                    true -> package_fail("Native packages requiring NIF/build scripts are not supported yet");
                    false -> ok
                end,
                Files = lists:sort(filelib:fold_files(filename:join(Root,"src"),".*\\.erl$",true,fun(File,Acc) -> [File|Acc] end,[])),
                case Files of [] -> package_fail("Native package has no Erlang sources and is not a Gleam package"); _ -> ok end,
                Config = case file:consult(filename:join(Root,"rebar.config")) of {ok,C} -> C; {error,enoent} -> []; {error,R} -> package_fail(io_lib:format("Invalid rebar.config: ~tp",[R])) end,
                case lists:any(fun(Key) -> proplists:is_defined(Key,Config) end,[plugins,project_plugins,pre_hooks,post_hooks,provider_hooks,overrides]) of
                    true -> package_fail("Native package requires unsupported rebar hooks/plugins/overrides"); false -> ok
                end,
                Options = lists:append([erlc_option(Option,Root) || Option <- proplists:get_value(erl_opts,Config,[])]),
                Paths = filelib:wildcard(filename:join([Library,"*","ebin"])),
                CodeArgs = lists:append([["-pa",Path] || Path <- Paths]),
                First = [filename:join(Root,F) || F <- proplists:get_value(erl_first_files,Config,[])],
                Ordered = First ++ [F || F <- Files, not lists:member(F,First)],
                lists:foreach(fun(File) -> run_tool("erlc",Root,CodeArgs ++ ["-I",filename:join(Root,"include"),"-I",filename:join(Root,"src"),"-o",Ebin] ++ Options ++ [File]) end,Ordered)
        end,
        Beams = [{unicode:characters_to_binary(filename:basename(File,".beam")),read_required(File)} || File <- lists:sort(filelib:wildcard(filename:join(Ebin,"*.beam")))],
        case Beams of [] -> package_fail("Native package produced no BEAM modules"); _ -> ok end,
        AppSources = filelib:wildcard(filename:join(Root,"src/*.app.src")),
        Properties = case AppSources of
            [AppSource] -> case file:consult(AppSource) of {ok,[{application,App,Props}]} -> Props; Other -> package_fail(io_lib:format("Invalid application resource: ~tp",[Other])) end;
            [] -> case file:consult(filename:join(Ebin,atom_to_list(App) ++ ".app")) of {ok,[{application,App,Props}]} -> Props; _ -> package_fail("Native package application resource is missing") end;
            _ -> package_fail("Native package declares multiple OTP applications")
        end,
        Names = [binary_to_atom(Module,utf8) || {Module,_} <- Beams],
        Props1 = lists:keystore(modules,1,Properties,{modules,Names}),
        Props2 = lists:keystore(vsn,1,Props1,{vsn,unicode:characters_to_list(VersionBinary)}),
        Resource = unicode:characters_to_binary(io_lib:format("~tp.~n",[{application,App,Props2}])),
        ok = file:write_file(filename:join(Ebin,atom_to_list(App) ++ ".app"),Resource),
        {ok,{Beams,Resource}}
    catch throw:{package_error,Error} -> {error,Error};
          Class:Reason -> {error,unicode:characters_to_binary(io_lib:format("Native build failed: ~tp:~tp",[Class,Reason]))} end.
read_required(Path) -> {ok,Bytes} = file:read_file(Path),Bytes.
erlc_option({i,Path},Root) -> ["-I",filename:absname(Path,Root)];
erlc_option({d,Name},_) -> ["-D" ++ atom_to_list(Name)];
erlc_option({d,Name,Value},_) -> [lists:flatten(io_lib:format("-D~s=~tp",[Name,Value]))];
erlc_option(Option,_) -> [lists:flatten(io_lib:format("+~tp",[Option]))].
remove_generated_erlang(Directory) ->
    lists:foreach(fun(File) -> ok = file:delete(File) end,filelib:fold_files(Directory,".*\\.erl$",true,fun(F,A) -> [F|A] end,[])).

copy_native_headers(Source,Destination) ->
    case file:read_link_info(Source) of
        {error,enoent} -> ok;
        {ok,Info} when element(3,Info) =:= directory ->
            ok = filelib:ensure_dir(filename:join(Destination,"placeholder")),
            {ok,Names} = file:list_dir(Source),
            lists:foreach(fun(Name) -> copy_native_headers(filename:join(Source,Name),filename:join(Destination,Name)) end,Names);
        {ok,Info} when element(3,Info) =:= regular ->
            {ok,_} = file:copy(Source,Destination),ok;
        _ -> package_fail("Native include headers must be regular files or directories")
    end.

native_directory(TargetBinary) ->
    try
        Target = unicode:characters_to_list(TargetBinary),
        ok = filelib:ensure_dir(filename:join(Target,"placeholder")),
        {ok,unicode:characters_to_binary(fresh_directory(Target,".pooka-native"))}
    catch Class:Reason -> {error,unicode:characters_to_binary(io_lib:format("Native staging failed: ~tp:~tp",[Class,Reason]))} end.


using_directory(Directory,Run) ->
    try Run() after file:del_dir_r(unicode:characters_to_list(Directory)) end.

repository_identity(URLBinary) ->
    try uri_string:parse(string:trim(unicode:characters_to_list(URLBinary))) of
        URI when is_map(URI) -> unicode:characters_to_binary(uri_string:recompose(maps:remove(userinfo,URI)));
        _ -> URLBinary
    catch _:_ -> URLBinary end.
