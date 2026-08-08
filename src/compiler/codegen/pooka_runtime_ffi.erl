%% SPDX-License-Identifier: Apache-2.0

%%% Keep the few runtime chores beside the generated program.
%%%
%%% Implement tagged control transfers, assertions, inspection, class dispatch and
%%% actor services needed by lowered forms. Private throw tags delimit Pooka
%%% control flow; they are not a general error transport.
%%%
%%% ```erlang
%%% propagate({ok, Value}) -> Value; propagate({error, _} = E) -> throw({pooka_return, E}).
%%% ```

-module(pooka_runtime_ffi).
-export([remainder/2, propagate/1, panic/1, assert/2, break/1, continue/0, echo/1, echo/3, inspect/1, encode/3, run_entry/2, escript_entry/3, interface_call/4, actor_start/4, actor_self/0, actor_owner/1, actor_initialize/1, actor_read/2, actor_write/3, actor_call/4, iteration_next/3, iteration_exhausted/0, describe_failure/2, assert_equal/3, assert_equal/5, run_tests/2]).
remainder(A, B) when is_integer(A), is_integer(B) -> A rem B;
remainder(A, B) when is_float(A), is_float(B) -> math:fmod(A, B).
%% Unwrap success or throw the private return tag consumed by this callable's generated
%% boundary. Ordinary exceptions are not converted into Result.
%%
%% ```erlang
%% propagate({ok, 42}). % 42
%% % propagate({error, E}) throws {pooka_return,{error,E}}
%% ```
propagate({ok, Value}) -> Value;
propagate({error, _} = Error) -> throw({pooka_return, Error}).
panic(Message) -> erlang:error({pooka_panic, Message}).
assert(true, _) -> nil;
assert(false, Message) -> erlang:error({pooka_assert, Message}).
%% Raise a structured assertion failure using operands already evaluated by generated code.
%% This helper reports a failed comparison; it is not the comparison operation itself.
assert_equal(Expected, Found, Message) -> erlang:error({pooka_assert_values, Message, Expected, Found}).
assert_equal(Expected, Found, Message, Path, Line) -> erlang:error({pooka_assert_values, Message, Expected, Found, Path, Line}).
%% Throw the private break payload caught by the nearest generated loop boundary.
%%
%% ```erlang
%% break(42). % throws {pooka_break,42}
%% ```
break(Value) -> throw({pooka_break, Value}).
%% Transfer to the nearest generated loop continuation without inventing a result value.
continue() -> throw(pooka_continue).




%% Write a source-labelled inspection and return the original value. Test capture chooses
%% its own device; ordinary execution uses standard_error.
%%
%% ```erlang
%% echo(42, <<"src/main.pooka">>, 3). % prints location/value, returns 42
%% ```
echo(Value) -> echo(Value,<<"<runtime>">>,0).
echo(Value,Path,Line) ->
    Location = [Path,":",integer_to_binary(Line)],
    
    Header = case debug_colour() of true -> ["\e[38;2;139;148;168m",Location,"\e[0m"]; false -> Location end,
    io:put_chars(echo_device(),[Header,"\n",inspect(Value),"\n"]),Value.

echo_device() ->
    case persistent_term:get(pooka_test_capture, false) of
        true -> group_leader();
        false -> standard_error
    end.
debug_colour() ->
    case os:getenv("NO_COLOR") of
        false -> os:getenv("FORCE_COLOR") =:= "1" orelse element(1,io:columns(standard_error)) =:= ok;
        _ -> false
    end.





%% Render BEAM representations with Pooka-facing names and bounded recursive inspection.
%% Keep runtime identity for functions and actors rather than exposing an accidental tuple
%% layout.
inspect(Value) -> unicode:characters_to_binary(inspect_value(Value,0)).
inspect_value(_,Depth) when Depth > 40 -> "...";
inspect_value(true,_) -> "True";
inspect_value(false,_) -> "False";
inspect_value(nil,_) -> "Nil";
inspect_value(none,_) -> "None";
inspect_value({ok,V},D) -> ["Ok(",inspect_value(V,D+1),")"];
inspect_value({error,V},D) -> ["Error(",inspect_value(V,D+1),")"];
inspect_value({some,V},D) -> ["Some(",inspect_value(V,D+1),")"];
inspect_value(V,_) when is_binary(V) ->
    case unicode:characters_to_list(V) of
        Text when is_list(Text) -> case lists:all(fun(C) -> C >= 32 orelse lists:member(C,[9,10,13]) end,Text) of
            true -> [$",[escape(C) || C <- Text],$"];
            false -> bit_array_text(V)
        end;
        _ -> bit_array_text(V)
    end;
inspect_value(V,_) when is_bitstring(V) -> io_lib:format("~tp",[V]);
inspect_value(V,D) when is_list(V) -> ["[",inspect_list(V,D+1),"]"];
inspect_value({'$pooka_actor',_,Name,Pid},_) -> [atom_to_list(Name),"(",io_lib:format("~p",[Pid]),")"];
inspect_value(V,D) when is_tuple(V) ->
    case tuple_to_list(V) of
        [Tag|Fields] when is_atom(Tag) ->
            case string:prefix(atom_to_list(Tag),"pooka@class@") of
                nomatch -> ["#(",join_values(tuple_to_list(V),D+1),")"];
                _ -> [lists:last(string:split(atom_to_list(Tag),"@",all)),"(",join_values(Fields,D+1),")"]
            end;
        Fields -> ["#(",join_values(Fields,D+1),")"]
    end;
inspect_value(V,D) when is_map(V) ->
    ["#{",lists:join(", ",[[inspect_value(K,D+1),": ",inspect_value(Value,D+1)] || {K,Value} <- lists:sort(maps:to_list(V))]),"}"];
inspect_value(V,_) when is_function(V) -> {arity,N}=erlang:fun_info(V,arity),["fn(",lists:join(", ",lists:duplicate(N,"_")),") { ... }"];
inspect_value(V,_) when is_atom(V) -> atom_to_list(V);
inspect_value(V,_) -> io_lib:format("~tp",[V]).
inspect_list([],_) -> [];
inspect_list([V],D) -> inspect_value(V,D);
inspect_list([V|Rest],D) when is_list(Rest) -> [inspect_value(V,D),", ",inspect_list(Rest,D)];
inspect_list([V|Rest],D) -> [inspect_value(V,D),", ..",inspect_value(Rest,D)].
join_values(Values,D) -> lists:join(", ",[inspect_value(V,D) || V <- Values]).
bit_array_text(V) -> ["<<",lists:join(", ",[integer_to_list(B) || B <- binary_to_list(V)]),">>"].
escape($") -> "\\\"";
escape($\\) -> "\\\\";
escape(10) -> "\\n";
escape(13) -> "\\r";
escape(9) -> "\\t";
escape(C) when C < 32; C =:= 127 -> io_lib:format("\\u{~.16b}",[C]);
escape(C) -> [C].

encode(Text, utf8, _) -> Text;
encode(Text, Encoding, native) ->
    encode(Text, Encoding, erlang:system_info(endian));
encode(Text, Encoding, Endian) ->
    case unicode:characters_to_binary(Text, utf8, {Encoding, Endian}) of
        Binary when is_binary(Binary) -> Binary;
        _ -> erlang:error({pooka_invalid_unicode, Text})
    end.



%% Start the requested OTP application and invoke its main module at the executable
%% boundary. Convert failures into the executable's exit behavior.
run_entry(Application, Module) ->
    erlang:halt(entry_status(Application, Module)).

entry_status(Application, Module) ->
    try
        {ok, _} = application:ensure_all_started(Application),
        _ = Module:main(),
        0
    catch Class:Reason:Stack ->
        io:format(standard_error, "~ts~nstacktrace: ~tp~n", [describe_failure(Class, Reason), Stack]),
        1
    end.




describe_failure(error, {pooka_panic, Message}) -> ["panic: ", Message];
describe_failure(error, {pooka_assert_values, Message, _, _, _, _}) -> ["assertion failed: ", Message];
describe_failure(error, {pooka_assert_values, Message, _, _}) -> ["assertion failed: ", Message];
describe_failure(error, {pooka_assert, Message}) -> ["assertion failed: ", Message];
describe_failure(error, pooka_match_failure) -> "no match branch accepted the value";
describe_failure(error, pooka_iteration_exhausted) ->
    "the loop ended without breaking with a value";
describe_failure(error, {pooka_invalid_unicode, _}) -> "the text cannot be encoded";
describe_failure(error, pooka_actor_state_isolated) ->
    "actor state was accessed outside its actor";
describe_failure(exit, {pooka_actor_call_failed, Reason}) ->
    ["the actor stopped before replying: ", describe_exit(Reason)];
describe_failure(exit, {pooka_actor_initialization_failed, Reason}) ->
    ["the actor failed to start: ", describe_exit(Reason)];

describe_failure(error, {pooka_native_unavailable, Component, Function, Arity, loaded}) ->
    ["native component `", Component, "` does not implement `", Function, "/",
     integer_to_binary(Arity), "`"];
describe_failure(error, {pooka_native_unavailable, Component, _, _, {_, Text}}) when is_list(Text) ->
    ["native component `", Component, "` could not be loaded: ", unicode:characters_to_binary(Text)];
describe_failure(error, {pooka_native_unavailable, Component, _, _, Reason}) ->
    io_lib:format("native component `~ts` could not be loaded: ~tp", [Component, Reason]);
describe_failure(Class, Reason) -> io_lib:format("~tp: ~tp", [Class, Reason]).



describe_exit({Reason, Stack}) when is_list(Stack) -> describe_failure(error, Reason);
describe_exit(Reason) -> describe_failure(exit, Reason).






%% Dispatch a declared interface method through the receiver's concrete class or actor
%% identity. Existing atoms identify generated entrypoints.
interface_call(_Namespace, {'$pooka_actor', Module, Class, _Pid} = Receiver, Method, Arguments) ->
    Function = list_to_existing_atom("$class@" ++ atom_to_list(Class) ++ "@" ++ atom_to_list(Method)),
    erlang:apply(Module, Function, [Receiver | Arguments]);
interface_call(Namespace, Receiver, Method, Arguments) ->
    "pooka@class@" ++ Identity = atom_to_list(element(1, Receiver)),
    [SourceModule, _RootClass] = string:split(Identity, "@", trailing),
    {Owner, Path} = case string:split(SourceModule,"/",all) of
        ["$package", Package | Rest] -> {Package,string:join(Rest,"/")};
        _ -> {atom_to_list(Namespace),SourceModule}
    end,
    ModulePath = lists:flatten(string:replace(Path, "/", "@", all)),
    Module = list_to_existing_atom("pooka@" ++ Owner ++ "@" ++ ModulePath),
    erlang:apply(Module, '$interface@call', [Receiver, Method, Arguments]).





%% Start and monitor the actor while its initializer runs. Return the actor handle only
%% after initialization has acknowledged readiness.
actor_start(Module, Class, Initializer, Arguments) ->
    Caller = self(),
    Ready = make_ref(),
    {Pid, Monitor} = spawn_monitor(fun() ->
        Reference = {'$pooka_actor', Module, Class, self()},
        put('$pooka_actor_reference', Reference),
        erlang:apply(Module, Initializer, Arguments),
        Caller ! {Ready, ready},
        actor_loop(Module, Reference)
    end),
    receive
        {Ready, ready} ->
            demonitor(Monitor, [flush]),
            {'$pooka_actor', Module, Class, Pid};
        {'DOWN', Monitor, process, Pid, Reason} ->
            exit({pooka_actor_initialization_failed, Reason})
    end.

actor_self() -> get('$pooka_actor_reference').
%% Check that mutable actor state is accessed by its owning actor process and matching
%% runtime reference.
actor_owner({'$pooka_actor', _, _, Pid} = Reference) when Pid =:= self() ->
    case actor_self() =:= Reference of
        true -> nil;
        false -> erlang:error(pooka_actor_state_isolated)
    end;
actor_owner(_) -> erlang:error(pooka_actor_state_isolated).

actor_initialize(State) -> put('$pooka_actor_state', State), nil.
%% Read one state tuple field only after the actor-owner check succeeds.
actor_read(Reference, Index) ->
    actor_owner(Reference),
    element(Index, get('$pooka_actor_state')).
%% Replace one state tuple field in the owner process dictionary. Caller-visible actor
%% handles keep their identity.
actor_write(Reference, Index, Value) ->
    actor_owner(Reference),
    State = get('$pooka_actor_state'),
    put('$pooka_actor_state', setelement(Index, State, Value)),
    nil.




%% Queue behavior calls asynchronously, dispatch self-calls directly when permitted, and
%% correlate synchronous replies for external callers.
actor_call({'$pooka_actor', _, _, Pid}, Method, Arguments, true) ->
    Pid ! {'$pooka_actor_async', Method, Arguments},
    nil;
actor_call({'$pooka_actor', Module, _, Pid} = Reference, Method, Arguments, false)
  when Pid =:= self() ->
    actor_owner(Reference),
    erlang:apply(Module, Method, [Reference | Arguments]);
actor_call({'$pooka_actor', _, _, Pid}, Method, Arguments, false) ->
    Monitor = monitor(process, Pid),
    Pid ! {'$pooka_actor_call', self(), Monitor, Method, Arguments},
    receive
        {Monitor, Reply} -> demonitor(Monitor, [flush]), Reply;
        {'DOWN', Monitor, process, Pid, Reason} -> exit({pooka_actor_call_failed, Reason})
    end.



%% Receive queued actor requests and dispatch their generated method bodies while retaining
%% actor-owned state.
actor_loop(Module, Reference) ->
    receive
        
        
        
        {'$pooka_actor_stop', _Caller, _Token} ->
            ok;
        {'$pooka_actor_call', Caller, Token, Method, Arguments} ->
            Reply = erlang:apply(Module, Method, [Reference | Arguments]),
            Caller ! {Token, Reply},
            actor_loop(Module, Reference);
        {'$pooka_actor_async', Method, Arguments} ->
            erlang:apply(Module, Method, [Reference | Arguments]),
            actor_loop(Module, Reference)
    end.





%% Normalize list and explicit iterator-protocol steps to none or {some,Value,Rest}. A
%% protocol object advances itself; its next result is not a public state-pair tuple.
%%
%% ```erlang
%% iteration_next(app, [1,2], list). % {some,1,[2]}
%% ```
iteration_next(_, [], list) -> none;
iteration_next(_, [Head | Tail], list) -> {some, Head, Tail};
iteration_next(Namespace, Iterator, protocol) ->
    case interface_call(Namespace, Iterator, next, []) of
        none -> none;
        {some, Value} -> {some, Value, Iterator}
    end.



%% Reject exhaustion of an iteration that promised a value through an explicit break.
%% Effect-only iteration has a Nil completion path instead.
iteration_exhausted() -> erlang:error(pooka_iteration_exhausted).



%% Extract and start an exported escript application, keeping its temporary runtime files
%% within the executable lifecycle.
escript_entry(Application, Module, _Arguments) ->
    Root = case os:getenv("TMPDIR") of
        false -> case os:getenv("TEMP") of false -> "/tmp"; T -> T end;
        T -> T
    end,
    Directory = escript_temporary(Root),
    Status = try
        {ok, Sections} = escript:extract(escript:script_name(), []),
        {archive, Archive} = lists:keyfind(archive, 1, Sections),
        {ok, _} = zip:extract(Archive, [{cwd, Directory}]),
        {ok, Packages} = file:list_dir(Directory),
        Paths = [filename:join([Directory, Package, "ebin"]) || Package <- Packages,
            filelib:is_dir(filename:join([Directory, Package, "ebin"]))],
        ok = code:add_pathsa(Paths),
        entry_status(Application, Module)
    catch Class:Reason:Stack ->
        io:format(standard_error, "~ts~nstacktrace: ~tp~n", [describe_failure(Class, Reason), Stack]),
        1
    after file:del_dir_r(Directory) end,
    erlang:halt(Status).

escript_temporary(Root) ->
    Name = "pooka-escript-" ++ os:getpid() ++ "-" ++ integer_to_list(erlang:unique_integer([positive])),
    Directory = filename:join(Root, Name),
    case file:make_dir(Directory) of
        ok -> ok = file:change_mode(Directory, 8#700), Directory;
        {error, eexist} -> escript_temporary(Root);
        {error, Reason} -> erlang:error({pooka_escript_temporary, Reason})
    end.













%% Read the requested test entries and write framed outcomes for the parent compiler to
%% recover independently.
run_tests(Input, Output) ->
    {ok, Encoded} = file:read_file(Input),
    Tests = binary_to_term(Encoded),
    persistent_term:put(pooka_test_capture, true),
    
    
    _ = logger:remove_handler(default),
    {ok, Device} = file:open(Output, [write, raw, binary]),
    Indexed = lists:zip(lists:seq(1, length(Tests)), Tests),
    test_pool(Indexed, erlang:system_info(schedulers_online), #{}, Device),
    ok = file:close(Device).

%% Limit concurrent test workers, record finished outcomes and account for workers that
%% exit before reporting normally.
test_pool([], _, Running, _) when map_size(Running) =:= 0 -> ok;
test_pool([Next | Rest], Limit, Running, Device) when map_size(Running) < Limit ->
    {Monitor, Test} = start_test(Next),
    test_pool(Rest, Limit, Running#{Monitor => Test}, Device);
test_pool(Pending, Limit, Running, Device) ->
    receive
        {'DOWN', Monitor, process, _, Exit} when is_map_key(Monitor, Running) ->
            {Index, Capture, Started} = maps:get(Monitor, Running),
            Duration = erlang:monotonic_time(microsecond) - Started,
            Printed = captured(Capture),
            Outcome = case Exit of
                {pooka_test, passed} -> {ok, Printed};
                {pooka_test, {failed, {Reason, Details, Stack}}} ->
                    {error, {test_failure, Printed, Reason, Details, Stack}};
                
                Other ->
                    {Reason, Details, Stack} = failure_term(exit, Other, []),
                    {error, {test_failure, Printed, Reason, Details, Stack}}
            end,
            Frame = term_to_binary({Index, Outcome, Duration}),
            ok = file:write(Device, [<<(byte_size(Frame)):32>>, Frame]),
            test_pool(Pending, Limit, maps:remove(Monitor, Running), Device)
    end.

%% Give each test an isolated worker and capture device so one test's output cannot become
%% another test's assertion report.
start_test({Index, {Module, Function}}) ->
    Capture = spawn(fun() -> capture([]) end),
    Started = erlang:monotonic_time(microsecond),
    {_, Monitor} = spawn_monitor(fun() ->
        group_leader(Capture, self()),
        Result = try Module:Function() of
            _ -> passed
        catch Class:Reason:Stack -> {failed, failure_term(Class, Reason, Stack)}
        end,
        exit({pooka_test, Result})
    end),
    {Monitor, {Index, Capture, Started}}.

captured(Capture) ->
    Capture ! {pooka_captured, self()},
    receive {pooka_captured, Capture, Printed} -> Printed end.




%% Implement the group-leader capture loop used by tests. Reply to supported IO requests
%% while retaining their output in order.
capture(Parts) ->
    receive
        {io_request, From, ReplyAs, Request} ->
            {Reply, Kept} = capture_request(Request, Parts),
            From ! {io_reply, ReplyAs, Reply},
            capture(Kept);
        {pooka_captured, From} ->
            From ! {pooka_captured, self(), iolist_to_binary(lists:reverse(Parts))},
            capture(Parts)
    end.

%% Normalize supported Erlang IO protocol requests. Unsupported requests receive an
%% explicit protocol error rather than hanging a reader.
capture_request({put_chars, Encoding, Characters}, Parts) ->
    {ok, [capture_text(Characters, Encoding) | Parts]};
capture_request({put_chars, Encoding, Module, Function, Arguments}, Parts) ->
    capture_request({put_chars, Encoding, apply(Module, Function, Arguments)}, Parts);
capture_request({put_chars, Characters}, Parts) ->
    capture_request({put_chars, latin1, Characters}, Parts);
capture_request({put_chars, Module, Function, Arguments}, Parts) ->
    capture_request({put_chars, latin1, Module, Function, Arguments}, Parts);
capture_request({requests, Requests}, Parts) ->
    lists:foldl(fun(Request, {_, Kept}) -> capture_request(Request, Kept) end,
                {ok, Parts}, Requests);
capture_request(getopts, Parts) -> {[{binary, false}, {encoding, unicode}], Parts};
capture_request({setopts, _}, Parts) -> {ok, Parts};
capture_request({get_geometry, _}, Parts) -> {{error, enotsup}, Parts};
capture_request(_, Parts) -> {{error, request}, Parts}.

capture_text(Characters, Encoding) ->
    case unicode:characters_to_binary(Characters, Encoding) of
        Text when is_binary(Text) -> Text;
        _ -> iolist_to_binary(io_lib:format("~tp", [Characters]))
    end.



%% Preserve assertion details and stack information in the per-test failure representation.
failure_term(Class, Reason, Stack) ->
    Details = case Reason of
        {pooka_assert_values, _, Expected, Found, Path, Line} ->
            [{<<"expected">>, inspect(Expected)}, {<<"found">>, inspect(Found)},
             {<<"location">>,iolist_to_binary([Path,":",integer_to_binary(Line)])}];
        {pooka_assert_values, _, Expected, Found} ->
            [{<<"expected">>, inspect(Expected)}, {<<"found">>, inspect(Found)}]
                ++ spec_location(Stack);
        _ -> spec_location(Stack)
    end,
    {unicode:characters_to_binary(describe_failure(Class,Reason)), Details, test_format(Stack)}.




spec_location(Stack) ->
    Lines = [{File, Line} || {_, _, _, Info} <- Stack,
                             {file, File} <- [lists:keyfind(file, 1, Info)],
                             {line, Line} <- [lists:keyfind(line, 1, Info)],
                             lists:suffix(".spec.pooka", File)],
    case Lines of
        [{File, Line} | _] ->
            [{<<"location">>, iolist_to_binary([File, ":", integer_to_binary(Line)])}];
        [] -> []
    end.
test_format([]) -> <<>>;
test_format(Value) -> unicode:characters_to_binary(io_lib:format("~tp",[Value])).
