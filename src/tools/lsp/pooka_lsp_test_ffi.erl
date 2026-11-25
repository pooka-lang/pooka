%% SPDX-License-Identifier: Apache-2.0

%% Run exactly the test selected by a code lens. Use the same compiler escript
%% as the server and pass arguments directly so names are never shell commands.
-module(pooka_lsp_test_ffi).
-export([run/2]).

run(Path,Name) ->
    case 'tools@lsp@analysis':workspace(Path) of
        {ok,Root} ->
            RootParts = filename:split(Root),
            Parts = filename:split(Path),
            case lists:prefix(RootParts,Parts) of
                true ->
                    Relative = iolist_to_binary(lists:join(<<"/">>,lists:nthtail(length(RootParts),Parts))),
                    run_escript(Root,Relative,Name);
                false -> {error,<<"The test file is outside its project">>}
            end;
        _ -> {error,<<"Could not locate the test project">>}
    end.

run_escript(Root,File,Name) ->
    case os:find_executable("escript") of
        false -> {error,<<"Could not find escript on PATH">>};
        Escript ->
            Script = filename:absname(escript:script_name()),
            Args = [Script,"test","--only",File,Name],
            Port = open_port({spawn_executable,Escript},[binary,exit_status,stderr_to_stdout,
                        {cd,Root},{args,Args},{env,[{"NO_COLOR","1"}]}]),
            Ref = erlang:start_timer(60000,self(),Port),
            try collect(Port,Ref,[],0)
            after erlang:cancel_timer(Ref) end
    end.

collect(Port,Ref,Chunks,Size) ->
    receive
        {Port,{data,Bytes}} ->
            Kept = min(byte_size(Bytes),65536-Size),
            Chunk = binary:part(Bytes,0,Kept),
            KeptChunks = case Kept of 0 -> Chunks; _ -> [Chunk|Chunks] end,
            collect(Port,Ref,KeptChunks,Size+Kept);
        {Port,{exit_status,Status}} ->
            Raw = iolist_to_binary(lists:reverse(Chunks)),
            Output = case unicode:characters_to_binary(Raw) of
                Text when is_binary(Text) -> Text;
                {_,Text,_} -> Text
            end,
            {ok,Status,Output};
        {timeout,Ref,Port} ->
            try port_close(Port) catch error:badarg -> ok end,
            {error,<<"The selected Pooka test exceeded its time limit">>}
    end.
