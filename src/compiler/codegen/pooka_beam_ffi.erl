%% SPDX-License-Identifier: Apache-2.0

%%% The final workshop speaks Erlang.
%%%
%%% Decode portable form terms, invoke compile:forms and launch isolated
%%% program/test VMs. Production execution inherits descriptors so prompts, stdin
%%% and stderr keep their normal behavior.
%%%
%%% ```erlang
%%% compile:forms(Forms, [binary, return_errors, return_warnings]).
%%% ```

-module(pooka_beam_ffi).
-export([compile/1, pretty/1, runtime_binary/0, runtime_binary_for/1, execute/4, execute_inherited/4, start_test_vm/1, stop_test_vm/1, execute_tests/3, abstract_forms/1, build_fingerprint/0, resource/1, valid_module/2,
         compile_foreign_erlang/1, run_foreign_compiler/3, discover_elixir_code_paths/0]).
%% Translate the small Gleam forms.Term algebra into ordinary Erlang atoms, numbers, tuples
%% and lists before compilation.
%%
%% ```erlang
%% decode({tuple,[{atom,<<"integer">>},{integer,1},{integer,42}]}).
%% % {integer,1,42}
%% ```
%%
%% Abstract format: https://www.erlang.org/doc/apps/erts/absform.html#module-declarations-and-forms
decode({atom, Name}) -> binary_to_atom(Name, utf8);
decode({integer, N}) -> N;
decode({floating, F}) -> F;
decode({characters, Text}) -> unicode:characters_to_list(Text);
decode({tuple, Elements}) -> list_to_tuple([decode(E) || E <- Elements]);
decode({sequence, Elements}) -> [decode(E) || E <- Elements].
%% Compile complete abstract forms with binary/error reporting options, returning BEAM
%% bytes without an intermediate Erlang source file.
%%
%% Abstract format: https://www.erlang.org/doc/apps/erts/absform.html#module-declarations-and-forms
compile(Forms) ->
    case compile:forms([decode(F) || F <- Forms],
                       [binary, return_errors, return_warnings, debug_info, no_auto_import]) of
        {ok, _, Beam} -> {ok, Beam};
        {ok, _, Beam, _Warnings} -> {ok, Beam};
        {error, Errors, Warnings} -> {error, format({Errors, Warnings})}
    end.
pretty(Forms) -> unicode:characters_to_binary([erl_pp:form(decode(F)) || F <- Forms]).
runtime_binary() ->
    case code:get_object_code(pooka_runtime_ffi) of
        {pooka_runtime_ffi, Beam, _} -> {ok, Beam};
        error -> {error, <<"Pooka runtime BEAM is unavailable">>}
    end.



%% Recompile the embedded template under a collision-free package module name.
%% Cache by template checksum and package inside this compiler VM, so staging and
%% final emission do not compile the same helper twice.
%% https://www.erlang.org/doc/apps/erts/absform.html#module-declarations-and-forms
runtime_binary_for(Package) ->
    case runtime_binary() of
        {ok, Template} ->
            Name = runtime_name(Package),
            Key = {?MODULE, runtime, Name, erlang:md5(Template)},
            case persistent_term:get(Key, undefined) of
                undefined ->
                    {ok, {_, [{abstract_code, {raw_abstract_v1, Forms}}]}} = beam_lib:chunks(Template, [abstract_code]),
                    Scoped = [rename_runtime(F, Name) || F <- Forms],
                    case compile:forms(Scoped, [binary, return_errors, return_warnings, debug_info]) of
                        {ok, Name, Beam} -> persistent_term:put(Key, Beam), {ok, Beam};
                        {ok, Name, Beam, _} -> persistent_term:put(Key, Beam), {ok, Beam};
                        Error -> {error, format(Error)}
                    end;
                Beam -> {ok, Beam}
            end;
        Error -> Error
    end.

runtime_name(Package) when is_binary(Package) ->
    binary_to_atom(<<"pooka@", Package/binary, "@@runtime">>, utf8);
runtime_name(Package) when is_atom(Package) -> runtime_name(atom_to_binary(Package, utf8)).

rename_runtime(pooka_runtime_ffi, Name) -> Name;
rename_runtime(Tuple, Name) when is_tuple(Tuple) -> list_to_tuple([rename_runtime(V, Name) || V <- tuple_to_list(Tuple)]);
rename_runtime(List, Name) when is_list(List) -> [rename_runtime(V, Name) || V <- List];
rename_runtime(Value, _) -> Value.

%% Build the child VM's application-start/main invocation and its failure boundary using
%% formatted Erlang terms.
execution_eval(Directory, Module) ->
    io_lib:format(
        "try true = code:add_patha(~tp), {ok, _} = application:ensure_all_started(~p), _ = ~p:main(), halt(0) "
        "catch C:R:S -> io:format(standard_error, \"~~ts~~nstacktrace: ~~tp~~n\", [~p:describe_failure(C,R),S]), halt(1) end.",
        [unicode:characters_to_list(Directory), application(Directory), binary_to_atom(Module, utf8), runtime_name(application(Directory))]).

execute(Directory, Module, Arguments, Colour) ->
    launch(Directory, execution_eval(Directory, Module), Arguments, Colour).

%% Start a fresh VM with inherited standard descriptors. nouse_stdio keeps the port from
%% capturing or merging the child's terminal streams; the result is its exact exit status.
execute_inherited(Directory, Module, Arguments, Colour) ->
    case erl_command() of
        error -> {error, <<"Cannot find erl on PATH">>};
        {ok, Erl, Environment} ->
            {RootEbin, Others} = code_paths(Directory),
            Port = open_port({spawn_executable, Erl}, [exit_status, nouse_stdio,
                {env, Environment ++ colour_environment(Colour)},
                {args, ["+S", "2:2", "-noshell", "-pa", RootEbin | Others] ++
                    ["-eval", lists:flatten(execution_eval(Directory, Module)),
                     "-extra" | [unicode:characters_to_list(A) || A <- Arguments]]}]),
            receive {Port, {exit_status, Status}} -> {ok, Status} end
    end.








%% Start the isolated VM that receives a framed batch of test requests.
start_test_vm(Colour) ->
    case erl_command() of
        error -> {test_vm, unavailable};
        {ok, Erl, Environment} ->
            Port = open_port({spawn_executable, Erl}, [binary, exit_status, stderr_to_stdout,
                    {env, Environment ++ colour_environment(Colour)},
                    {args, ["+S", "2:2", "-noshell", "-eval", test_vm_eval()]}]),
            {test_vm, Port}
    end.

test_vm_eval() ->
    "try case io:read('') of "
    "{ok, {pooka_tests, Paths, Root, App, Input, Output}} -> "
    "ok = code:add_pathsa(Paths), true = code:add_patha(Root), "
    "{ok, _} = application:ensure_all_started(App), "
    "Runtime = list_to_atom(\"pooka@\" ++ atom_to_list(App) ++ \"@@runtime\"), "
    "Runtime:run_tests(Input, Output), halt(0); "
    "_ -> halt(0) end "
    "catch C:R:S -> catch io:format(standard_error, \"~ts~nstacktrace: ~tp~n\", "
    "[io_lib:format(\"~tp: ~tp\", [C,R]),S]), halt(1) end.".

stop_test_vm({test_vm, unavailable}) -> nil;
stop_test_vm({test_vm, Port}) ->
    try port_close(Port) catch error:badarg -> true end,
    nil.

%% Send selected tests to the VM and recover individual framed results. Missing frames
%% become stopped-test failures rather than lost results.
execute_tests(Vm, _Directory, []) -> stop_test_vm(Vm), [];
execute_tests({test_vm, unavailable}, _Directory, Tests) ->
    [{test_run, {error, {test_failure, <<>>, <<"Cannot find erl on PATH">>, [], <<>>}}, 0} || _ <- Tests];
execute_tests({test_vm, Port}, Directory, Tests) ->
    Package = filename:dirname(unicode:characters_to_list(Directory)),
    Input = filename:join(Package, "pooka_tests.input"),
    Output = filename:join(Package, "pooka_tests.output"),
    Atoms = [{binary_to_atom(M, utf8), binary_to_atom(F, utf8)} || {M, F} <- Tests],
    ok = file:write_file(Input, term_to_binary(Atoms)),
    _ = file:delete(Output),
    {RootEbin, Others} = code_paths(Directory),
    Request = {pooka_tests, lists:reverse(Others), RootEbin, application(Directory), Input, Output},
    true = port_command(Port, io_lib:format("~tp.~n", [Request])),
    Printed = case collect(Port, []) of {ok, P} -> P; {error, P} -> P end,
    Finished = case file:read_file(Output) of
        {ok, Frames} -> frames(Frames, #{});
        {error, _} -> #{}
    end,
    _ = file:delete(Input),
    _ = file:delete(Output),
    [case maps:find(Index, Finished) of
         {ok, {Outcome, Duration}} -> {test_run, Outcome, Duration};
         
         error -> {test_run, {error, {test_failure, <<>>, stopped(Printed), [], <<>>}}, 0}
     end || Index <- lists:seq(1, length(Tests))].

%% Decode length-prefixed result frames by test index. Keep complete frames even if the VM
%% stops before all requests finish.
frames(<<Size:32, Frame:Size/binary, Rest/binary>>, Finished) ->
    {Index, Outcome, Duration} = binary_to_term(Frame, [safe]),
    frames(Rest, Finished#{Index => {Outcome, Duration}});
frames(_, Finished) -> Finished.

stopped(<<>>) -> <<"the test VM stopped before the test finished">>;
stopped(Printed) ->
    iolist_to_binary(["the test VM stopped before the test finished:\n", string:trim(Printed)]).

application(Directory) ->
    list_to_atom(filename:basename(filename:dirname(unicode:characters_to_list(Directory)))).




%% Use the deterministic capture launch path for test-facing execution helpers. This path
%% intentionally differs from interactive descriptor inheritance.
launch(Directory, Eval, Arguments, Colour) ->
    case erl_command() of
        error -> {error, <<"Cannot find erl on PATH">>};
        {ok, Erl, Environment} ->
            
            
            {RootEbin, Others} = code_paths(Directory),
            Port = open_port({spawn_executable, Erl}, [binary, exit_status, stderr_to_stdout,
                    {env, Environment ++ colour_environment(Colour)},
                    {args, ["+S", "2:2", "-noshell", "-pa", RootEbin | Others] ++ ["-eval", lists:flatten(Eval),
                            "-extra" | [unicode:characters_to_list(A) || A <- Arguments]]}]),
            collect(Port, [])
    end.






%% Locate the runtime executable and supply its required boot environment without assuming
%% a development-shell erl wrapper.
erl_command() ->
    Root = code:root_dir(),
    Bin = filename:join([Root, "erts-" ++ erlang:system_info(version), "bin"]),
    Erlexec = filename:join(Bin, "erlexec"),
    case filelib:is_regular(Erlexec) of
        true ->
            {ok, Erlexec, [{"ROOTDIR", Root}, {"BINDIR", Bin}, {"EMU", "beam"}, {"PROGNAME", "erl"}]};
        false ->
            case os:find_executable("erl") of
                false -> error;
                Erl -> {ok, Erl, []}
            end
    end.




%% Collect the built application's sibling dependency ebin directories for the child VM.
code_paths(Directory) ->
    Target = filename:dirname(filename:dirname(unicode:characters_to_list(Directory))),
    RootEbin = unicode:characters_to_list(Directory),
    Others = lists:delete(RootEbin, lists:usort(
        filelib:wildcard(filename:join([Target, "*", "ebin"]))))
        ++ elixir_code_paths(RootEbin),
    {RootEbin, Others}.




colour_environment(true) -> [{"FORCE_COLOR", "1"}, {"NO_COLOR", false}];
colour_environment(false) -> [{"NO_COLOR", "1"}, {"FORCE_COLOR", false}].

collect(Port, Parts) ->
    receive
        {Port, {data, Data}} -> collect(Port, [Data | Parts]);
        {Port, {exit_status, 0}} -> {ok, iolist_to_binary(lists:reverse(Parts))};
        {Port, {exit_status, _}} -> {error, iolist_to_binary(lists:reverse(Parts))}
    end.
format(Value) -> unicode:characters_to_binary(io_lib:format("~tp", [Value])).



abstract_forms(Forms) -> term_to_binary([decode(F) || F <- Forms]).
%% Fingerprint the compiler, runtime and relevant Erlang options so stale generated
%% artifacts cannot survive a meaningful compiler change.
build_fingerprint() ->
    
    
    
    term_to_binary({pooka_build_v2, erlang:system_info(otp_release),
                   erlang:system_info(version), compile:module_info(md5),
                   ?MODULE:module_info(md5),compiler_hashes(),os:getenv("ERL_COMPILER_OPTIONS")}).




compiler_hashes() ->
    case persistent_term:get({?MODULE, compiler_hashes}, undefined) of
        undefined ->
            _ = application:load(pooka),
            Modules = case application:get_key(pooka,modules) of {ok,Ms} -> lists:sort(Ms); _ -> [?MODULE] end,
            Hashes = [{M,case code:get_object_code(M) of {M,B,_} -> crypto:hash(sha256,B); error -> missing end} || M <- Modules],
            persistent_term:put({?MODULE, compiler_hashes}, Hashes),
            Hashes;
        Hashes -> Hashes
    end.
resource(Term) -> unicode:characters_to_binary(io_lib:format("~tp.~n", [decode(Term)])).

valid_module(Binary, Name) ->
    try beam_lib:chunks(Binary, [exports]) of
        {ok, {Module, _}} -> atom_to_binary(Module, utf8) =:= Name;
        _ -> false
    catch _:_ -> false end.





compile_foreign_erlang(Path) ->
    File = unicode:characters_to_list(Path),
    case compile:file(File, [binary, return_errors, return_warnings, debug_info]) of
        {ok, Module, Beam} -> {ok, {atom_to_binary(Module, utf8), Beam}};
        {ok, Module, Beam, _Warnings} -> {ok, {atom_to_binary(Module, utf8), Beam}};
        {error, Errors, _Warnings} -> {error, foreign_errors(Errors)}
    end.

foreign_errors(Errors) ->
    Lines = [io_lib:format("~ts:~ts: ~ts", [File, foreign_line(Location), Module:format_error(Description)])
             || {File, Problems} <- Errors, {Location, Module, Description} <- Problems],
    unicode:characters_to_binary(lists:join("\n", Lines)).

foreign_line({Line, Column}) -> io_lib:format("~p:~p", [Line, Column]);
foreign_line(Line) when is_integer(Line) -> integer_to_list(Line);
foreign_line(_) -> "?".





run_foreign_compiler(Program, Arguments, BeamDir) ->
    case os:find_executable(unicode:characters_to_list(Program)) of
        false -> {error, missing_compiler};
        Executable ->
            Port = open_port({spawn_executable, Executable},
                             [binary, exit_status, stderr_to_stdout,
                              {args, [unicode:characters_to_list(A) || A <- Arguments]}]),
            case collect(Port, []) of
                {ok, _} ->
                    Dir = unicode:characters_to_list(BeamDir),
                    {ok, [{unicode:characters_to_binary(filename:basename(Beam, ".beam")),
                           element(2, file:read_file(Beam))}
                          || Beam <- lists:sort(filelib:wildcard(filename:join(Dir, "*.beam")))]};
                {error, Output} -> {error, {compiler_failed, Output}}
            end
    end.




elixir_code_paths(Ebin) ->
    case filelib:wildcard(filename:join(Ebin, "Elixir.*.beam")) of
        [] -> [];
        _ -> discover_elixir_code_paths()
    end.



discover_elixir_code_paths() ->
    case os:find_executable("elixir") of
        false -> [];
        Executable ->
            Root = filename:dirname(filename:dirname(resolve_link(Executable, 10))),
            filelib:wildcard(filename:join([Root, "lib", "*", "ebin"]))
    end.

resolve_link(Path, 0) -> Path;
resolve_link(Path, Remaining) ->
    case file:read_link(Path) of
        {ok, Target} -> resolve_link(filename:absname(Target, filename:dirname(Path)), Remaining - 1);
        {error, _} -> Path
    end.


