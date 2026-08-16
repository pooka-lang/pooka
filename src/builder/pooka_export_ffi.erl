%% SPDX-License-Identifier: Apache-2.0

%%% Pack the BEAM files without opening their suitcases.
%%%
%%% Create executable archive payloads and export files at the Erlang boundary.
%%% Package assembly keeps the compiler independent of another BEAM language.
%%%
%%% ```text
%%% BEAM binaries + entry module -> executable archive
%%% ```

-module(pooka_export_ffi).
-include_lib("kernel/include/file.hrl").
-export([runtime_packages/3, temporary_directory/1, publish_directory/2, package_modules/2, create_escript/4]).




%% Assemble the application archive and bootstrap entrypoint into an executable escript.
create_escript(Shipment, Destination, Module, Bootstrap) ->
    case temporary_directory(Destination) of
        {error, _} = Error -> Error;
        {ok, Staging} ->
            Temporary = filename:join(unicode:characters_to_list(Staging), "executable"),
            try
                Root = unicode:characters_to_list(Shipment),
                {ok, Names} = file:list_dir(Root),
                Packages = [Name || Name <- lists:sort(Names), filelib:is_dir(filename:join(Root, Name))],
                Files = lists:append([archive_files(Root, Name) || Name <- Packages]),
                BootstrapName = unicode:characters_to_list(Module) ++ ".beam",
                case lists:any(fun({Name, _}) -> filename:basename(Name) =:= BootstrapName end, Files) of
                    true -> fail("Escript bootstrap conflicts with a packaged foreign module");
                    false -> ok
                end,
                ["pooka", Package | _] = string:split(unicode:characters_to_list(Module), "@", all),
                RuntimeName = "pooka@" ++ Package ++ "@@runtime.beam",
                [Runtime] = [Binary || {Name, Binary} <- Files,
                    lists:suffix("/ebin/" ++ RuntimeName, Name)],
                Archive = [{unicode:characters_to_list(Module) ++ ".beam", Bootstrap},
                           {RuntimeName, Runtime} | Files],
                ok = escript:create(Temporary, [shebang, {comment, "Pooka executable"},
                    {emu_args, "-escript main " ++ unicode:characters_to_list(Module)},
                    {archive, Archive, []}]),
                ok = file:change_mode(Temporary, 8#755),
                ok = file:rename(Temporary, unicode:characters_to_list(Destination)),
                {ok, nil}
            catch Class:Reason -> {error, format({Class, Reason})}
            after file:del_dir_r(unicode:characters_to_list(Staging)) end
    end.

archive_files(Root, Relative) ->
    Path = filename:join(Root, Relative),
    case file:read_link_info(Path) of
        {ok, #file_info{type = directory}} ->
            {ok, Names} = file:list_dir(Path),
            lists:append([archive_files(Root, filename:join(Relative, Name)) || Name <- lists:sort(Names)]);
        {ok, #file_info{type = regular}} ->
            {ok, Binary} = file:read_file(Path),
            [{Relative, Binary}];
        Other -> fail({unsupported_archive_entry, Relative, Other})
    end.



runtime_packages(EbinBinary, TargetBinaries, AppName) ->
    Ebin = unicode:characters_to_list(EbinBinary),
    Targets = [binary_to_atom(Target, utf8) || Target <- TargetBinaries],
    HasElixir = filelib:wildcard(filename:join(Ebin, "Elixir.*.beam")) =/= []
        orelse lists:any(fun(Target) -> lists:prefix("Elixir.", atom_to_list(Target)) end, Targets),
    case HasElixir of
        false -> {ok, []};
        true ->
            try
                Paths = pooka_beam_ffi:discover_elixir_code_paths(),
                case Paths of [] -> fail("Elixir runtime libraries were not found"); _ -> ok end,
                Candidates = maps:from_list([{list_to_atom(filename:basename(filename:dirname(Path))), Path}
                                             || Path <- Paths]),
                Imports = lists:flatmap(fun(File) ->
                    case beam_lib:chunks(File, [imports]) of
                        {ok, {_, [{imports, Entries}]}} -> [M || {M, _, _} <- Entries];
                        Error -> fail({invalid_project_beam, File, Error})
                    end
                end, [filename:join(Ebin, atom_to_list(Module) ++ ".beam")
                      || Module <- resource_modules(Ebin,unicode:characters_to_list(AppName))]),
                Referenced = Targets ++ Imports,
                Seeds = [elixir | [App || {App, Path} <- maps:to_list(Candidates),
                    lists:any(fun(Module) -> filelib:is_file(filename:join(Path, atom_to_list(Module) ++ ".beam")) end,
                              Referenced)]],
                Selected = runtime_closure(Seeds, Candidates, #{}),
                {ok, [{atom_to_binary(App, utf8), unicode:characters_to_binary(filename:dirname(maps:get(App, Candidates)))}
                      || App <- lists:sort(maps:keys(Selected))]}
            catch throw:{export_error, Reason} -> {error, format(Reason)};
                  Class:Reason -> {error, format({Class, Reason})}
            end
    end.

runtime_closure([], _Candidates, Selected) -> Selected;
runtime_closure([App | Rest], Candidates, Selected) ->
    case maps:is_key(App, Selected) of
        true -> runtime_closure(Rest, Candidates, Selected);
        false ->
            case maps:find(App, Candidates) of
                error ->
                    case code:lib_dir(App) of
                        {error, bad_name} -> fail({missing_runtime_application, App});
                        _ -> runtime_closure(Rest, Candidates, Selected)
                    end;
                {ok, Path} ->
                    File = filename:join(Path, atom_to_list(App) ++ ".app"),
                    case file:consult(File) of
                        {ok, [{application, App, Properties}]} ->
                            Dependencies = proplists:get_value(applications, Properties, []),
                            runtime_closure(Dependencies ++ Rest, Candidates, Selected#{App => true});
                        Error -> fail({invalid_runtime_resource, File, Error})
                    end
            end
    end.



temporary_directory(Destination) ->
    temporary_directory(unicode:characters_to_list(Destination), 100).
temporary_directory(_Destination, 0) -> {error, <<"Could not allocate export staging directory">>};
temporary_directory(Destination, Attempts) ->
    Suffix = os:getpid() ++ "-" ++ integer_to_list(erlang:unique_integer([positive, monotonic])),
    Path = Destination ++ ".tmp-" ++ Suffix,
    case file:make_dir(Path) of
        ok -> {ok, unicode:characters_to_binary(Path)};
        {error, eexist} -> temporary_directory(Destination, Attempts - 1);
        {error, Reason} -> {error, format({Path, Reason})}
    end.



%% Publish staged export output only after assembly has completed, keeping staging cleanup
%% separate from the final artifact.
publish_directory(StagingBinary, DestinationBinary) ->
    Staging = unicode:characters_to_list(StagingBinary),
    Destination = unicode:characters_to_list(DestinationBinary),
    Previous = Staging ++ ".previous",
    case file:read_link_info(Destination) of
        {error, enoent} -> file_result(file:rename(Staging, Destination));
        {ok, _} ->
            case file:rename(Destination, Previous) of
                ok -> case file:rename(Staging, Destination) of
                    ok -> file_result(remove_tree(Previous));
                    {error, Reason} ->
                        Restore = file:rename(Previous, Destination),
                        {error, format({publish_failed, Reason, restored_previous, Restore})}
                end;
                {error, Reason} -> {error, format({save_previous_failed, Reason})}
            end;
        {error, Reason} -> {error, format({Destination, Reason})}
    end.

remove_tree(Path) ->
    case file:read_link_info(Path) of
        {ok, #file_info{type = directory}} ->
            case file:list_dir(Path) of
                {ok, Entries} ->
                    case remove_children(Path, Entries) of
                        ok -> file:del_dir(Path);
                        Error -> Error
                    end;
                Error -> Error
            end;
        {ok, _} -> file:delete(Path);
        {error, enoent} -> ok;
        Error -> Error
    end.
remove_children(_Directory, []) -> ok;
remove_children(Directory, [Name | Rest]) ->
    case remove_tree(filename:join(Directory, Name)) of
        ok -> remove_children(Directory, Rest);
        Error -> Error
    end.

file_result(ok) -> {ok, nil};
file_result({error, Reason}) -> {error, format(Reason)}.
fail(Reason) -> throw({export_error, Reason}).
format(Value) -> unicode:characters_to_binary(io_lib:format("~tp", [Value])).



package_modules(EbinBinary, AppName) ->
    try {ok, [atom_to_binary(Module, utf8) || Module <- resource_modules(unicode:characters_to_list(EbinBinary),unicode:characters_to_list(AppName))]}
    catch throw:{export_error, Reason} -> {error, format(Reason)};
          Class:Reason -> {error, format({Class, Reason})}
    end.
resource_modules(Ebin, AppName) ->
    App = list_to_atom(AppName),
    File = filename:join(Ebin, AppName ++ ".app"),
    case file:consult(File) of
        {ok, [{application, App, Properties}]} ->
            Modules = proplists:get_value(modules, Properties, []),
            case is_list(Modules) andalso lists:all(fun is_atom/1, Modules) of
                true -> lists:usort(Modules);
                false -> fail({invalid_module_list, File})
            end;
        Error -> fail({invalid_application_resource, File, Error})
    end.
