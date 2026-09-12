%%% Run exported programs in separate operating-system processes and inspect
%%% their archives. These fixtures deliberately leave the compiler VM:
%%% relocation, argument passing, stdin and exit status need a real process
%%% boundary.
-module(shipment_test_ffi).
-export([run_cli_prompt/2, run_cli_stdio/3, run/3, has_executable/1, run_cli/2, run_escript/3, escript_files/1, git/2, hex_archive/2]).
%% Launch the export with escript from the requested directory. Place
%% temporary runtime files in that fixture directory and keep child scheduler
%% use modest.
run_escript(Script, Arguments, Directory) ->
    Port = open_port({spawn_executable, os:find_executable("escript")}, [binary, exit_status, stderr_to_stdout,
        {cd, unicode:characters_to_list(Directory)},
        {env, [{"ERL_FLAGS", "+S 2:2"}, {"TMPDIR", unicode:characters_to_list(Directory)}]},
        {args, [unicode:characters_to_list(Script) | [unicode:characters_to_list(A) || A <- Arguments]]}]),
    collect(Port, []).

%% Open the embedded zip archive without executing it. Returning filenames
%% lets Gleam assertions check what the escript actually carries.
escript_files(Script) ->
    {ok, Sections} = escript:extract(unicode:characters_to_list(Script), []),
    {archive, Archive} = lists:keyfind(archive, 1, Sections),
    {ok, Files} = zip:extract(Archive, [memory]),
    [unicode:characters_to_binary(Name) || {Name, _} <- Files].


%% Start a fresh Erlang VM with absolute code paths and plain CLI output. This
%% catches behavior that an in-process CLI call could hide.
run_cli(Arguments, Directory) ->
    Erlang = os:find_executable("erl"),
    Paths = [filename:absname(Path) || Path <- code:get_path()],
    Port = open_port({spawn_executable, Erlang}, [binary, exit_status, stderr_to_stdout,
        {cd, unicode:characters_to_list(Directory)},
        {env, [{"ERL_FLAGS", "+S 2:2"}, {"NO_COLOR", "1"}]},
        {args, ["-noshell", "-pa"] ++ Paths ++
            ["-eval", "pooka:main(), halt().", "-extra"] ++
            [unicode:characters_to_list(A) || A <- Arguments]}]),
    collect(Port, []).
%% Launch a generated shell script with positional arguments. Values are
%% passed as process arguments rather than interpolated into shell command
%% text.
run(Script, Arguments, Directory) ->
    Shell = os:find_executable("sh"),
    Port = open_port({spawn_executable, Shell}, [binary, exit_status, stderr_to_stdout,
        {cd, unicode:characters_to_list(Directory)}, {env, [{"ERL_FLAGS", "+S 2:2"}]},
        {args, [unicode:characters_to_list(Script) | [unicode:characters_to_list(A) || A <- Arguments]]}]),
    collect(Port, []).
%% Drain data until the exit-status message arrives, then restore chunk order.
%% A thirty-second timeout closes the port and returns a failing fixture
%% status.
collect(Port, Parts) ->
    receive
        {Port, {data, Data}} -> collect(Port, [Data | Parts]);
        {Port, {exit_status, Status}} -> {Status, iolist_to_binary(lists:reverse(Parts))}
    after 30000 -> port_close(Port), {124, <<"Exported program timed out">>}
    end.
%% Check for an optional host tool before the caller attempts its integration
%% fixture.
has_executable(Name) -> os:find_executable(unicode:characters_to_list(Name)) =/= false.

%% Invoke Git with a literal argument list inside a temporary repository. This
%% provides actual revision behavior without contacting a remote repository.
git(Directory,Arguments) ->
    Port = open_port({spawn_executable,os:find_executable("git")},[binary,exit_status,stderr_to_stdout,
        {cd,unicode:characters_to_list(Directory)},
        {args,[unicode:characters_to_list(A) || A <- Arguments]}]),
    collect(Port,[]).

%% Build a small Hex v3 envelope around caller-provided files. Return the
%% outer bytes and their SHA-256 so resolver tests can inject a reproducible
%% download.
hex_archive(Directory,Files) ->
    Root = unicode:characters_to_list(Directory),
    InnerFile = filename:join(Root,"inner.tar.gz"),
    OuterFile = filename:join(Root,"outer.tar"),
    Payload = [{unicode:characters_to_list(Name),Data} || {Name,Data} <- Files],
    ok = erl_tar:create(InnerFile,Payload,[compressed]),
    {ok,Inner} = file:read_file(InnerFile),
    Metadata = <<"[].">>,
    Hash = hex_bytes(crypto:hash(sha256,[<<"3">>,Metadata,Inner])),
    ok = erl_tar:create(OuterFile,[{"VERSION",<<"3">>},{"metadata.config",Metadata},{"contents.tar.gz",Inner},{"CHECKSUM",Hash}],[]),
    {ok,Archive} = file:read_file(OuterFile),
    {Archive,hex_bytes(crypto:hash(sha256,Archive))}.
%% Render each digest byte as two lowercase hexadecimal digits, preserving
%% leading zeroes.
hex_bytes(Binary) -> iolist_to_binary([io_lib:format("~2.16.0b",[Byte]) || <<Byte>> <= Binary]).

%% Use separate fixture files for stdin, stdout and stderr. The shell receives
%% paths as positional arguments, so Unicode or spaces do not become shell
%% syntax.
run_cli_stdio(Arguments, Directory, Input) ->
    Root = unicode:characters_to_list(Directory),
    InputFile = filename:join(Root, "cli.stdin"),
    OutputFile = filename:join(Root, "cli.stdout"),
    ErrorFile = filename:join(Root, "cli.stderr"),
    ok = file:write_file(InputFile, Input),
    Paths = [filename:absname(Path) || Path <- code:get_path()],
    Command = "input=$1; output=$2; error=$3; shift 3; exec \"$@\" <\"$input\" >\"$output\" 2>\"$error\"",
    Port = open_port({spawn_executable, os:find_executable("sh")},
        [binary, exit_status, stderr_to_stdout, {cd, Root},
         {env, [{"ERL_FLAGS", "+S 2:2"}, {"NO_COLOR", "1"}]},
         {args, ["-c", Command, "pooka-cli-test", InputFile, OutputFile, ErrorFile,
                 os:find_executable("erl"), "-noshell", "-pa"] ++ Paths ++
                ["-eval", "pooka:main(), halt().", "-extra"] ++
                [unicode:characters_to_list(A) || A <- Arguments]}]),
    {Status, _} = collect(Port, []),
    {ok, Output} = file:read_file(OutputFile),
    {ok, Error} = file:read_file(ErrorFile),
    {Status, Output, Error}.

%% Start the CLI without supplying input immediately. The fixture waits for a
%% visible prompt before allowing the child to receive its reply.
run_cli_prompt(Directory, Input) ->
    Paths = [filename:absname(Path) || Path <- code:get_path()],
    Port = open_port({spawn_executable, os:find_executable("erl")},
        [binary, exit_status, stderr_to_stdout,
         {cd, unicode:characters_to_list(Directory)},
         {env, [{"ERL_FLAGS", "+S 2:2"}, {"NO_COLOR", "1"}]},
         {args, ["-noshell", "-pa"] ++ Paths ++
                ["-eval", "pooka:main(), halt().", "-extra", "run"]}]),
    await_prompt(Port, Input, <<>>).

%% Accumulate output until the prompt arrives, then send input exactly once.
%% Timing out here exposes a runner that buffers the prompt while waiting for
%% that input.
await_prompt(Port, Input, Output) ->
    receive
        {Port, {data, Data}} ->
            Combined = <<Output/binary, Data/binary>>,
            case binary:match(Combined, <<"Prompt: ">>) of
                nomatch -> await_prompt(Port, Input, Combined);
                _ ->
                    true = port_command(Port, Input),
                    {Status, Rest} = collect(Port, []),
                    {Status, <<Combined/binary, Rest/binary>>}
            end;
        {Port, {exit_status, Status}} -> {Status, Output}
    after 5000 ->
        port_close(Port),
        {124, <<Output/binary, "timed out waiting for prompt">>}
    end.
