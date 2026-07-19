%% SPDX-License-Identifier: Apache-2.0

%%% Native work needs a careful doorkeeper.
%%%
%%% Run configured native builds and prepare loader artifacts through Erlang
%%% facilities. Preserve output and failure status so the CLI can explain a failed
%%% component.
%%%
%%% ```text
%%% native build command -> library path or error
%%% ```

-module(pooka_nif_ffi).
-export([run_build/3, erts_include/0, shared_library/1, component_key/4, loader/4]).

-include_lib("kernel/include/file.hrl").




%% Run the configured native component build and retain failure output for the diagnostic
%% boundary.
run_build(Command, Directory, Environment) ->
    {Shell, Arguments} = case os:type() of
        {win32, _} -> {os:find_executable("cmd"), ["/c", chars(Command)]};
        _ -> {"/bin/sh", ["-c", chars(Command)]}
    end,
    try
        Port = open_port({spawn_executable, Shell},
                         [binary, exit_status, stderr_to_stdout, hide,
                          {cd, chars(Directory)},
                          {env, [{chars(K), chars(V)} || {K, V} <- Environment]},
                          {args, Arguments}]),
        collect(Port, [])
    catch error:Reason ->
        {error, iolist_to_binary(io_lib:format("could not run the build command: ~tp", [Reason]))}
    end.

collect(Port, Parts) ->
    receive
        {Port, {data, Data}} -> collect(Port, [Data | Parts]);
        {Port, {exit_status, 0}} -> {ok, iolist_to_binary(lists:reverse(Parts))};
        {Port, {exit_status, Status}} ->
            {error, iolist_to_binary([lists:reverse(Parts),
                io_lib:format("~n(exit status ~p)", [Status])])}
    end.


erts_include() ->
    unicode:characters_to_binary(filename:join([code:root_dir(),
        "erts-" ++ erlang:system_info(version), "include"])).




shared_library(Path) ->
    case file:open(chars(Path), [read, binary, raw]) of
        {ok, File} ->
            Header = case file:read(File, 4) of {ok, Bytes} -> Bytes; _ -> <<>> end,
            ok = file:close(File),
            case Header of
                <<16#7f, "ELF">> -> true;
                <<16#cf, 16#fa, 16#ed, 16#fe>> -> true;
                <<16#ce, 16#fa, 16#ed, 16#fe>> -> true;
                <<16#fe, 16#ed, 16#fa, 16#cf>> -> true;
                <<16#fe, 16#ed, 16#fa, 16#ce>> -> true;
                <<16#ca, 16#fe, 16#ba, 16#be>> -> true;
                <<"MZ", _/binary>> -> true;
                _ -> false
            end;
        {error, _} -> false
    end.






%% Hash the component inputs used to decide whether the native build can be reused.
component_key(Directory, Command, Artifact, Mode) ->
    crypto:hash(sha256, term_to_binary({pooka_native_v1, Command, Artifact, Mode,
        erlang:system_info(otp_release), erlang:system_info(version),
        tree(chars(Directory))}, [deterministic])).

tree(Path) ->
    case file:read_link_info(Path) of
        {ok, #file_info{type = directory}} ->
            {ok, Names} = file:list_dir(Path),
            [{directory, Path} |
             lists:append([tree(filename:join(Path, Name)) || Name <- lists:sort(Names),
                           not ignored(Name)])];
        {ok, #file_info{type = regular, mode = Mode}} ->
            {ok, Bytes} = file:read_file(Path),
            [{file, Path, Mode band 8#777, crypto:hash(sha256, Bytes)}];
        {ok, #file_info{type = symlink}} ->
            [{link, Path, file:read_link(Path)}];
        _ -> []
    end.

ignored([$. | _]) -> true;
ignored(Name) -> lists:member(Name, ["target", "zig-out", "build", "_build"]).






%% Generate the Erlang NIF loader wrapper while preserving the component's declared module
%% identity.
loader(Module, Application, Component, Functions) ->
    M = binary_to_atom(Module, utf8),
    App = binary_to_atom(Application, utf8),
    L = 1,
    Key = {tuple, L, [{atom, L, pooka_native}, {atom, L, M}]},
    Init = {function, L, pooka_native_init, 0, [{clause, L, [], [],
        [{match, L, {var, L, 'Path'},
          call(filename, join, [cons_list([call(code, lib_dir, [{atom, L, App}]),
                                           string("native"),
                                           string(binary_to_list(Component))])])},
         {'case', L, call(erlang, load_nif, [{var, L, 'Path'}, {integer, L, 0}]),
          [{clause, L, [{atom, L, ok}], [],
            [call(persistent_term, put, [Key, {atom, L, loaded}])]},
           {clause, L, [{tuple, L, [{atom, L, error}, {var, L, 'Reason'}]}], [],
            [call(persistent_term, put, [Key, {var, L, 'Reason'}])]}]},
         {atom, L, ok}]}]},
    Stubs = [stub(Key, Component, Name, Arity) || {Name, Arity} <- Functions],
    Forms = [{attribute, L, module, M},
             {attribute, L, export, [{binary_to_atom(N, utf8), A} || {N, A} <- Functions]},
             {attribute, L, on_load, {pooka_native_init, 0}},
             Init | Stubs] ++ [{eof, L}],
    case compile:forms(Forms, [binary, return_errors, no_auto_import]) of
        {ok, _, Beam} -> {ok, Beam};
        {ok, _, Beam, _} -> {ok, Beam};
        {error, Errors, _} -> {error, iolist_to_binary(io_lib:format("~tp", [Errors]))}
    end.

stub(Key, Component, Name, Arity) ->
    L = 1,
    Arguments = [{var, L, '_'} || _ <- lists:seq(1, Arity)],
    Reason = {tuple, L, [{atom, L, pooka_native_unavailable}, binary(Component), binary(Name),
                         {integer, L, Arity},
                         call(persistent_term, get, [Key, {atom, L, not_loaded}])]},
    {function, L, binary_to_atom(Name, utf8), Arity,
     [{clause, L, Arguments, [], [call(erlang, nif_error, [Reason])]}]}.

call(Module, Function, Arguments) ->
    {call, 1, {remote, 1, {atom, 1, Module}, {atom, 1, Function}}, Arguments}.
cons_list([]) -> {nil, 1};
cons_list([Head | Tail]) -> {cons, 1, Head, cons_list(Tail)}.
string(Text) -> {string, 1, Text}.
binary(Text) -> {bin, 1, [{bin_element, 1, {string, 1, binary_to_list(Text)}, default, default}]}.

chars(Value) when is_binary(Value) -> unicode:characters_to_list(Value);
chars(Value) -> Value.
