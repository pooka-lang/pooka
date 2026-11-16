%% SPDX-License-Identifier: Apache-2.0

%%% Fixtures for the VM's real logger and supervisor, not a replacement logger.
%%% A temporary handler copies reports to the observing process; the normal
%%% handlers keep running, so the captured program output is checked too.
-module(runtime_crash_test_ffi).
-export([current/0]).
-behaviour(supervisor).
-export([source/0, runtime_details/1, preserves_foreign_frames/0,
         observe/2, supervised/2, initial/1, fail/0, adopt/1, init/1,
         adding_handler/1, removing_handler/1, log/2]).

source() ->
    {ok,Text} = file:read_file(?FILE),
    Text.

runtime_details(Beam) ->
    {ok,{_,Chunks}} = beam_lib:chunks(Beam,[abstract_code,compile_info]),
    {raw_abstract_v1,Forms} = proplists:get_value(abstract_code,Chunks),
    Files = lists:usort([unicode:characters_to_binary(Path) ||
        {attribute,_,file,{Path,_}} <- Forms]),
    Keys = lists:sort([atom_to_binary(Key,utf8) ||
        {Key,_} <- proplists:get_value(compile_info,Chunks)]),
    {Files,Keys}.

preserves_foreign_frames() ->
    Function = fun() -> ok end,
    Foreign = [{foreign_crash,work,0},
               {foreign_crash,work,0,[{file,"ffi/user.erl"},{line,7}]},
               {Function,[],[]}],
    Private = [{pooka_runtime_ffi,panic,3,[]},
               {'pooka@library@@runtime',actor_loop,2},
               {fun pooka_runtime_ffi:echo/1,[42],[]}],
    pooka_runtime_ffi:user_stack(Private ++ Foreign) =:= Foreign.

observe(Pid,Crash) ->
    with_reports(fun() -> result(wait_down(Pid,Crash),1) end).

supervised(Pid,Crash) ->
    with_reports(fun() ->
        {ok,Supervisor} = supervisor:start_link(?MODULE,Pid),
        unlink(Supervisor),
        try result(wait_down(Pid,Crash),2)
        after gen_server:stop(Supervisor)
        end
    end).

initial(Start) ->
    with_reports(fun() ->
        Reason = try Start(), unexpectedly_started
                 catch Class:Failure -> {Class,Failure}
                 end,
        result(Reason,1)
    end).

fail() -> erlang:error(foreign_failure).

%% Adopt the fresh actor for this test. Linking from the supervisor makes its
%% ordinary child-terminated report observe exactly the same exit reason.
adopt(Pid) -> link(Pid), {ok,Pid}.
init(Pid) ->
    {ok,{#{strategy => one_for_one,intensity => 1,period => 5},
         [#{id => kettle,start => {?MODULE,adopt,[Pid]},restart => temporary,
            shutdown => 1000,type => worker}]}}.

wait_down(Pid,Crash) ->
    Reference = monitor(process,Pid),
    try
        Crash(),
        receive {'DOWN',Reference,process,Pid,Reason} -> Reason
        after 5000 -> erlang:error(actor_did_not_crash)
        end
    after demonitor(Reference,[flush])
    end.

with_reports(Work) ->
    ok = logger:add_handler(pooka_crash_probe,?MODULE,
        #{level => error,config => #{owner => self()}}),
    try Work()
    after logger:remove_handler(pooka_crash_probe)
    end.

adding_handler(Config) -> {ok,Config}.
removing_handler(_) -> ok.
log(Event,#{config := #{owner := Owner}}) ->
    Owner ! {pooka_crash_report,maps:get(msg,Event)},
    ok.

result(Reason,Count) ->
    Messages = reports(Count,erlang:monotonic_time(millisecond)+5000,[]),
    unicode:characters_to_binary(io_lib:format("exit: ~tp~nreports: ~tp~n",[Reason,Messages])).

reports(0,_,Found) -> lists:reverse(Found);
reports(Count,Deadline,Found) ->
    receive {pooka_crash_report,Message} -> reports(Count-1,Deadline,[Message|Found])
    after max(0,Deadline-erlang:monotonic_time(millisecond)) ->
        erlang:error({missing_crash_reports,Count,Found})
    end.

current() -> self().
