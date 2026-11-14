%% SPDX-License-Identifier: Apache-2.0

%%% Remember exactly which ingredients changed.
%%%
%%% Hash source trees and toolchain inputs for incremental builds. Manifest files
%%% such as pooka.toml belong to the key alongside the language sources.
%%%
%%% ```text
%%% changed pooka.toml -> invalidate affected build key
%%% ```

-module(pooka_incremental_ffi).
-export([snapshot/2, read_report/3, write_report/4, foreign/3, native/5, digest/1, enclosing_archive/1]).
-include_lib("kernel/include/file.hrl").

%% Hash the package inputs used to decide whether its prior build can be reused.
snapshot({graph,Root,Packages},Mode) ->
    try
        Projects = maps:from_list([{element(3,P),P} || P <- Packages]),
        Applications = maps:from_list([{application_name(P),chars(element(2,P))} || P <- Packages]),
        Toolchain = toolchain(),
        InputSets = maps:map(fun(_,P) ->
            IsRoot = element(3,P) =:= element(3,Root),
            Paths = inputs(P,IsRoot andalso Mode =:= <<"dev">>,Applications),
            Paths
        end,Projects),
        Own = maps:map(fun(Name,P) -> digest({P,Mode,Toolchain,maps:get(Name,InputSets)}) end,Projects),
        
        
        KeyMap = lists:foldl(fun(P,Acc) ->
            Name = element(3,P),
            Deps = element(5,P) ++ case P =:= Root andalso Mode =:= <<"dev">> of true -> element(6,P); false -> [] end,
            Children = lists:sort([{element(2,D),maps:get(element(2,D),Acc)} || D <- Deps,maps:is_key(element(2,D),Projects)]),
            maps:put(Name,digest({maps:get(Name,Own),Children}),Acc)
        end,#{},Packages),
        Keys = lists:sort(maps:to_list(KeyMap)),
        Foreign = [{Name,digest({P,Mode,Toolchain,
            [F || F={Path,_,_} <- maps:get(Name,InputSets), foreign_input(P,Path)],
            [{element(2,D),proplists:get_value(element(2,D),Keys)} || D <- element(5,P),maps:is_key(element(2,D),Projects)]})}
            || {Name,P} <- lists:sort(maps:to_list(Projects))],
        {ok,{snapshot,digest({incremental_v1,Root,Mode,Keys}),Keys,Foreign}}
    catch _:_ -> {error,nil} end.

foreign_input(P,Path) ->
    Root = chars(element(2,P)),
    File = chars(Path),
    filename:extension(File) =/= ".pooka" andalso
    not lists:prefix(filename:join(Root,"test") ++ "/",File) andalso
    not lists:prefix(filename:join(Root,"native") ++ "/",File).

%% Collect relevant package configuration and source inputs, including pooka.toml.
%% Generated output is not a source substitute.
inputs(P,Tests,Applications) ->
    Root = chars(element(2,P)),
    Directories = ["src","ffi","include","priv"] ++ case Tests of true -> ["test"]; false -> [] end,
    Config = ["pooka.toml","gleam.toml","rebar.config","rebar.config.script","mix.exs","manifest.toml"],
    Files = lists:append([tree(filename:join(Root,D)) || D <- Directories]) ++
            native_tree(filename:join(Root,"native")) ++
            lists:append([tree(filename:join(Root,C)) || C <- Config]),
    
    
    {ExtraDirs,Defines} = case element(8,P) of {beam,_,_} -> include_options(Root); pooka -> {[],[]} end,
    IncludeDirs = [filename:join(Root,"include"),filename:join(Root,"src")] ++ ExtraDirs,
    Includes = lists:append([erlang_includes(chars(Path),IncludeDirs,Defines,Applications) || {Path,_,_} <- Files,
                            filename:extension(chars(Path)) =:= ".erl"]),
    lists:usort(Files ++ Includes).

include_options(Root) ->
    case file:consult(filename:join(Root,"rebar.config")) of
        {ok,Config} ->
            Options = proplists:get_value(erl_opts,Config,[]),
            {[filename:absname(Path,Root) || {i,Path} <- Options],
             lists:append([case O of {d,N} -> [N]; {d,N,V} -> [{N,V}]; _ -> [] end || O <- Options])};
        {error,enoent} -> {[],[]};
        _ -> erlang:error(invalid_rebar_config)
    end.

%% A dependency header may not have a compiled application directory yet.
%% Resolve that case from the source graph instead of forgetting the snapshot.
%% Ordinary preprocessing remains authoritative when it can see every header.
%%
%% ```erlang
%% -include_lib("shared_headers/include/constants.hrl").
%% ```
erlang_includes(Path,Dirs,Defines,Applications) ->
    {ok,Forms} = epp:parse_file(Path,Dirs,Defines),
    Errors = [Reason || {error,Reason} <- Forms],
    case Errors of
        [] -> lists:append([tree(File) || {attribute,_,file,{File,_}} <- Forms]);
        _ ->
            Missing = [File || {_,epp,{include,lib,File}} <- Errors],
            true = Missing =/= [],
            true = lists:all(fun(File) -> tracked_library(File,Applications) end,Missing),
            true = lists:all(fun recoverable_include_error/1,Errors),
            %% Missing definitions can hide conditional includes from epp. Walk
            %% every literal include, including inactive branches, rather than
            %% trusting the partial file attributes. Dynamic include names stay
            %% uncacheable; compilation still decides whether the code is valid.
            Paths = literal_includes(Path,Dirs,Applications,sets:new()),
            lists:append([tree(File) || File <- sets:to_list(Paths)])
    end.

application_name(P) ->
    case element(8,P) of
        {beam,App,_} -> chars(App);
        pooka -> chars(element(3,P))
    end.

tracked_library(File,Applications) ->
    case filename:split(File) of
        [App|_] -> maps:is_key(App,Applications);
        _ -> false
    end.

recoverable_include_error({_,epp,{include,lib,_}}) -> true;
recoverable_include_error({_,epp,{undefined,_,_}}) -> true;
recoverable_include_error(_) -> false.

%% A complete lexical walk sees headers inside conditionals even when an
%% unavailable dependency macro prevents epp from entering that branch. Unknown
%% paths disable caching rather than making an incomplete promise.
%%
%% ```erlang
%% -ifdef(FROM_DEPENDENCY).
%% -include("../extra/local.hrl").
%% -endif.
%% ```
literal_includes(Path0,Dirs,Applications,Seen) ->
    Path = normalise(Path0),
    case sets:is_element(Path,Seen) of
        true -> Seen;
        false ->
            {ok,Bytes} = file:read_file(Path),
            {ok,Tokens,_} = erl_scan:string(unicode:characters_to_list(Bytes)),
            Includes = include_directives(Tokens),
            lists:foldl(fun({Kind,File},Acc) ->
                Header = include_path(Kind,File,Path,Dirs,Applications),
                literal_includes(Header,Dirs,Applications,Acc)
            end,sets:add_element(Path,Seen),Includes)
    end.

include_directives([{'-',_},{atom,_,Kind},{'(',_},{string,_,File},{')',_},{dot,_}|Rest])
  when Kind =:= include; Kind =:= include_lib ->
    [{Kind,File}|include_directives(Rest)];
include_directives([{'-',_},{atom,_,Kind}|_])
  when Kind =:= include; Kind =:= include_lib ->
    erlang:error(dynamic_include);
include_directives([_|Rest]) -> include_directives(Rest);
include_directives([]) -> [].

include_path(Kind,File,Source,Dirs,Applications) ->
    case Kind of
        include -> find_header(File,[filename:dirname(Source)|Dirs]);
        include_lib ->
            %% epp tries ordinary include directories before application lookup.
            %% Keep that order when a different dependency triggered recovery.
            case find_header_optional(File,[filename:dirname(Source)|Dirs]) of
                {ok,Path} -> Path;
                missing -> library_header(File,Applications)
            end
    end.

library_header(File,Applications) ->
    [App|Tail] = filename:split(File),
    case maps:find(App,Applications) of
        {ok,Root} -> find_header(filename:join(Tail),[Root]);
        error ->
            %% Runtime library headers are outside the graph, but their
            %% actual contents still become explicit snapshot inputs.
            case code:lib_dir(list_to_atom(App)) of
                {error,_} -> erlang:error(unknown_include_library);
                Root -> find_header(filename:join(Tail),[Root])
            end
    end.

find_header(File,Directories) ->
    case find_header_optional(File,Directories) of
        {ok,Path} -> Path;
        missing -> erlang:error(missing_include)
    end.

find_header_optional(File,[Directory|Rest]) ->
    Path = normalise(filename:absname(File,Directory)),
    case filelib:is_regular(Path) of
        true -> {ok,Path};
        false -> find_header_optional(File,Rest)
    end;
find_header_optional(_,[]) -> missing.



native_tree(Path) ->
    case file:read_link_info(Path) of
        {error,enoent} -> [];
        {ok,#file_info{type=directory}} ->
            {ok,Names} = file:list_dir(Path),
            [{unicode:characters_to_binary(Path),directory,<<>>} |
             lists:append([native_tree(filename:join(Path,N)) || N <- lists:sort(Names),
                           not native_output(N)])];
        {ok,#file_info{type=regular,mode=Mode}} ->
            {ok,Bytes} = file:read_file(Path),
            [{unicode:characters_to_binary(Path),Mode band 8#777,digest(Bytes)}];
        _ -> erlang:error(uncacheable_path)
    end.
native_output([$.|_]) -> true;
native_output(Name) -> lists:member(Name,["target","zig-out","build","_build"]).



tree(Path) ->
    case file:read_link_info(Path) of
        {error,enoent} -> [{unicode:characters_to_binary(Path),missing,<<>>}];
        {ok,#file_info{type=directory}} ->
            {ok,Names} = file:list_dir(Path),
            [{unicode:characters_to_binary(Path),directory,<<>>} |
             lists:append([tree(filename:join(Path,N)) || N <- lists:sort(Names)])];
        {ok,#file_info{type=regular,mode=Mode}} ->
            {ok,Bytes} = file:read_file(Path),
            [{unicode:characters_to_binary(Path),Mode band 8#777,digest(Bytes)}];
        _ -> erlang:error(uncacheable_path)
    end.

toolchain() ->
    
    
    
    Beams = compiler_beams(),
    
    
    Env = lists:sort([E || E <- os:getenv(),not volatile_environment(E)]),
    Tools = [{P,executable(P)} || P <- ["gleam","erlc","elixirc","lfec"]],
    digest({erlang:system_info(otp_release),erlang:system_info(version),
            compile:module_info(md5),Beams,Env,Tools}).

volatile_environment(E) ->
    lists:any(fun(Prefix) -> lists:prefix(Prefix,E) end,["_=","SHLVL=","PWD=","OLDPWD="]).

%% Identify the running compiler. A source build loads its modules from
%% build/<target>/erlang/*/ebin, so each BEAM file is hashed. An installed
%% compiler is one escript archive: code:which/1 then names a path inside the
%% archive, and the nearest ancestor that is a regular file is the escript
%% itself, which is hashed instead. Without this, a rebuilt compiler with an
%% unchanged version number would reuse stale package runtimes and generated
%% code.
compiler_beams() ->
    Directory = normalise(filename:dirname(code:which(?MODULE))),
    case enclosing_archive(Directory) of
        {ok,Archive} -> [{escript,unicode:characters_to_binary(Archive),digest(read_required(Archive))}];
        none ->
            Parent = filename:dirname(filename:dirname(Directory)),
            Files = lists:sort(filelib:wildcard(filename:join([Parent,"*","ebin","*.beam"]))),
            [{unicode:characters_to_binary(F),digest(read_required(F))} || F <- Files]
    end.

enclosing_archive(Path) when is_binary(Path) ->
    case enclosing_archive(chars(Path)) of
        {ok,Archive} -> {ok,unicode:characters_to_binary(Archive)};
        none -> {error,nil}
    end;
enclosing_archive(Path) ->
    case filelib:is_regular(Path) of
        true -> {ok,Path};
        false ->
            case filename:dirname(Path) of
                Path -> none;
                Parent -> enclosing_archive(Parent)
            end
    end.


normalise(Path) ->
    normalise_segments(filename:split(filename:absname(Path)), []).
normalise_segments([], Kept) -> filename:join(lists:reverse(Kept));
normalise_segments(["." | Rest], Kept) -> normalise_segments(Rest, Kept);
normalise_segments([".." | Rest], [Root]) -> normalise_segments(Rest, [Root]);
normalise_segments([".." | Rest], [_ | Kept]) -> normalise_segments(Rest, Kept);
normalise_segments([Segment | Rest], Kept) -> normalise_segments(Rest, [Segment | Kept]).

executable(Program) ->
    case os:find_executable(Program) of
        false -> missing;
        Path -> {Path,digest(read_required(Path))}
    end.

%% Read the previous reusable build report while checking its expected cache
%% representation.
read_report(Path,Key,Packages) ->
    try
        {ok,{StoredOutput,Report}} = read_cache(chars(Path),Key),
        true = StoredOutput =:= output(Packages),
        true = is_tuple(Report) andalso tuple_size(Report) =:= 12 andalso element(1,Report) =:= report,
        {ok,Report}
    catch _:_ -> {error,nil} end.

%% Persist the reusable report at the cache boundary after successful work.
write_report(Path,Key,Packages,Report) ->
    
    
    try write_cache(chars(Path),Key,{output(Packages),Report})
    catch _:_ -> {error,nil} end.

output(Packages) ->
    lists:append([lists:append([tree(filename:join(chars(P),D)) || D <- ["ebin","include","native"]]) ++
                  artifact_tree(filename:join(chars(P),"_pooka_artefacts")) || P <- Packages]) ++
    module_inputs(lists:append([[{<<>>,read_required(F)} || F <- filelib:wildcard(filename:join([chars(P),"ebin","*.beam"]))] || P <- Packages])) ++
    case Packages of
        [P|_] ->
            Target = filename:dirname(chars(P)),
            tree(filename:join(Target,"fingerprint")) ++
            tree(filename:join(filename:dirname(filename:dirname(Target)),"erlang"));
        [] -> []
    end.

%% Describe generated artifacts used by output validation without treating their timestamps
%% as source truth.
artifact_tree(Directory) ->
    case file:list_dir(Directory) of
        {ok,Names} -> lists:append([tree(filename:join(Directory,N)) || N <- lists:sort(Names),N =/= "build.cache"]);
        {error,enoent} -> tree(Directory);
        _ -> erlang:error(unreadable_artifacts)
    end.




foreign(Path,Key,Run) ->
    case load_package(Path,Key) of
        {ok,{Modules,Inputs}} ->
            case valid_modules(Modules) andalso Inputs =:= module_inputs(Modules) of
                true -> {ok,{Modules,false}};
                false -> build_foreign(Path,Key,Run)
            end;
        _ -> build_foreign(Path,Key,Run)
    end.
build_foreign(Path,Key,Run) ->
    case Run() of
        {ok,Modules} ->
            _ = save_package(Path,Key,{Modules,module_inputs(Modules)}),
            {ok,{Modules,true}};
        Error -> Error
    end.

native(Path,Key,Library,Application,Run) ->
    Destination = filename:join(chars(Library),chars(Application)),
    case load_package(Path,Key) of
        {ok,{Modules,Resource,Files,Inputs}} ->
            try
                true = valid_modules(Modules),true = is_binary(Resource),
                true = Inputs =:= module_inputs(Modules),
                restore(Destination,Files),
                {ok,{{Modules,Resource},false}}
            catch _:_ -> build_native(Path,Key,Destination,Run) end;
        _ -> build_native(Path,Key,Destination,Run)
    end.
build_native(Path,Key,Destination,Run) ->
    case Run() of
        {ok,{Modules,Resource}} ->
            _ = try save_package(Path,Key,{Modules,Resource,archive(Destination,""),module_inputs(Modules)}) catch _:_ -> {error,nil} end,
            {ok,{{Modules,Resource},true}};
        Error -> Error
    end.

%% Check cached module artifacts before accepting a package reuse decision.
valid_modules(Modules) when is_list(Modules) ->
    lists:all(fun({Name,Bytes}) when is_binary(Name),is_binary(Bytes) -> pooka_beam_ffi:valid_module(Bytes,Name); (_) -> false end,Modules);
valid_modules(_) -> false.




module_inputs(Modules) ->
    Paths = lists:usort(lists:append([beam_inputs(Bytes) || {_,Bytes} <- Modules])),
    lists:append([tree(Path) || Path <- Paths]).
beam_inputs(Bytes) ->
    Attributes = case beam_lib:chunks(Bytes,[attributes]) of
        {ok,{_,[{attributes,Attrs}]}} -> proplists:get_value(external_resource,Attrs,[]);
        _ -> []
    end,
    Includes = case beam_lib:chunks(Bytes,[abstract_code]) of
        {ok,{_,[{abstract_code,{raw_abstract_v1,Forms}}]}} ->
            [F || {attribute,_,file,{F,_}} <- Forms];
        _ -> []
    end,
    [case P of B when is_binary(B) -> chars(B); L -> L end || P <- Attributes ++ Includes].

archive(Root,Relative) ->
    Path = filename:join(Root,Relative),
    case file:read_link_info(Path) of
        {ok,#file_info{type=directory}} ->
            {ok,Names} = file:list_dir(Path),
            [{Relative,directory,<<>>} | lists:append([archive(Root,case Relative of "" -> N; _ -> filename:join(Relative,N) end) || N <- lists:sort(Names)])];
        {ok,#file_info{type=regular,mode=Mode}} -> [{Relative,Mode band 8#777,read_required(Path)}];
        _ -> erlang:error(unsafe_native_artifact)
    end.
restore(Root,Files) ->
    
    true = is_list(Files),
    true = lists:all(fun({Name,Mode,Bytes}) ->
        is_list(Name) andalso filename:pathtype(Name) =:= relative andalso
        not lists:member("..",filename:split(Name)) andalso
        (Mode =:= directory orelse is_integer(Mode)) andalso is_binary(Bytes)
    end,Files),
    case file:read_link_info(Root) of {ok,_} -> ok = file:del_dir_r(Root); {error,enoent} -> ok end,
    lists:foreach(fun({Name,directory,_}) -> ok = filelib:ensure_dir(filename:join([Root,Name,"placeholder"]));
                     ({Name,Mode,Bytes}) ->
                         Path = filename:join(Root,Name),ok = filelib:ensure_dir(Path),
                         ok = file:write_file(Path,Bytes),ok = file:change_mode(Path,Mode)
                  end,Files).

load_package(_,<<>>) -> {error,nil};
load_package(Path,Key) -> read_cache(chars(Path),Key).
save_package(_,<<>>,_) -> {error,nil};
save_package(Path,Key,Value) -> write_cache(chars(Path),Key,Value).





read_cache(Path,Key) ->
    try
        {ok,Bytes} = file:read_file(Path),
        {pooka_incremental_v2,Key,Hash,Atoms,Payload} = binary_to_term(Bytes,[safe]),
        true = digest({Atoms,Payload}) =:= Hash,
        _ = [binary_to_atom(Atom,utf8) || Atom <- Atoms],
        {ok,binary_to_term(Payload,[safe])}
    catch _:_ -> {error,nil} end.
write_cache(Path,Key,Value) ->
    try
        ok = filelib:ensure_dir(Path),
        Payload = term_to_binary(Value,[compressed]),
        Atoms = [atom_to_binary(Atom,utf8) || Atom <- sets:to_list(atoms(Value,sets:new([{version,2}])))],
        Bytes = term_to_binary({pooka_incremental_v2,Key,digest({Atoms,Payload}),Atoms,Payload}),
        pooka_package_ffi:write_atomic(unicode:characters_to_binary(Path),Bytes)
    catch _:_ -> {error,nil} end.
atoms(Value,Found) when is_atom(Value) -> sets:add_element(Value,Found);
atoms(Value,Found) when is_tuple(Value) -> atoms(tuple_to_list(Value),Found);
atoms([Head|Tail],Found) -> atoms(Tail,atoms(Head,Found));
atoms(Value,Found) when is_map(Value) -> atoms(maps:to_list(Value),Found);
atoms(_,Found) -> Found.

read_required(Path) -> {ok,Bytes} = file:read_file(Path),Bytes.
digest(Value) when is_binary(Value) -> crypto:hash(sha256,Value);
digest(Value) -> crypto:hash(sha256,term_to_binary(Value,[deterministic])).
chars(B) -> unicode:characters_to_list(B).
