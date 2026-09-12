%%% Open a fresh VM to inspect colour policy without changing the parent test
%%% VM's environment. Captured port data includes terminal escape bytes, which
%%% the Gleam assertions inspect directly.
-module(echo_test_ffi).
-export([coloured/1, detection/3]).
%% Run a fixed echo expression under controlled NO_COLOR and FORCE_COLOR
%% values. A fresh process keeps those overrides local to this check.
coloured(NoColour)->
    Paths=[filename:absname(P) || P<-code:get_path()],
    Eval="pooka_runtime_ffi:echo(42,<<\"src/main.pooka\">>,3),halt().",
    Port=open_port({spawn_executable,os:find_executable("erl")},[binary,exit_status,stderr_to_stdout,
        {env,[{"NO_COLOR",case NoColour of true->"1";false->false end},{"FORCE_COLOR","1"}]},
        {args,["+S","2:2","-noshell","-pa"]++Paths++["-eval",Eval]}]),
    collect(Port,[]).
%% Accumulate port chunks in arrival order. A nonzero child exit or a timeout
%% fails the fixture rather than returning a plausible but incomplete output.
collect(P,Acc)->receive
    {P,{data,B}}->collect(P,[B|Acc]);
    {P,{exit_status,0}}->iolist_to_binary(lists:reverse(Acc));
    {P,{exit_status,N}}->erlang:error({echo_child_failed,N})
after 10000->port_close(P),erlang:error(echo_child_timeout) end.



%% Query both stdout and stderr colour detection under explicit environment
%% settings. This exercises the runtime decision instead of calling only the
%% pure style helpers.
detection(NoColour,ForceColour,Term)->
    Paths=[filename:absname(P) || P<-code:get_path()],
    Eval="io:format(\"~p\",[{utilities@colour:detect(stdout),utilities@colour:detect(stderr)}]),halt().",
    Port=open_port({spawn_executable,os:find_executable("erl")},[binary,exit_status,stderr_to_stdout,
        {env,[{"NO_COLOR",binary_to_list(NoColour)},{"FORCE_COLOR",binary_to_list(ForceColour)},{"TERM",binary_to_list(Term)}]},
        {args,["+S","2:2","-noshell","-pa"]++Paths++["-eval",Eval]}]),
    collect(Port,[]).
