%% SPDX-License-Identifier: Apache-2.0

%%% Carry a lamp while a dependency download is away.
%%%
%%% Own scoped terminal reporting, spinner processes and deterministic event
%%% recording. Restore the previous scope after success or failure so one download
%%% cannot capture the next command.
%%%
%%% ```text
%%% scope -> start spinner -> run operation -> stop spinner -> restore scope
%%% ```

-module(pooka_progress_ffi).
-export([with_reporting/2, record/1, run/2]).
with_reporting(Colour,Run) -> scoped({terminal,Colour},Run).
record(Run) ->
    Old = get(pooka_progress_events), put(pooka_progress_events,[]),
    try Value=scoped(record,Run),{Value,lists:reverse(get(pooka_progress_events))}
    after restore(pooka_progress_events,Old) end.
%% Install the progress mode for one operation and restore the old process-local mode in an
%% after clause.
scoped(Mode,Run) ->
    Old=get(pooka_progress),put(pooka_progress,Mode),
    try Run() after restore(pooka_progress,Old) end.
restore(Key,undefined) -> erase(Key);
restore(Key,Value) -> put(Key,Value).
run(Name,Run) ->
    case get(pooka_progress) of
        undefined -> Run();
        record ->
            event(<<"Downloading ",Name/binary>>),
            try Value=Run(),event(<<(status(Value))/binary," ",Name/binary>>),Value
            catch C:R:S -> event(<<"Failed ",Name/binary>>),erlang:raise(C,R,S) end;
        {terminal,Colour} ->
            Started=erlang:monotonic_time(microsecond),
            Tty=case io:columns(standard_error) of {ok,_} -> true; _ -> false end,
            Spinner=case Tty of
                true -> Parent=self(),spawn(fun()-> M=monitor(process,Parent),spin(Parent,M,Name,Colour,0) end);
                false -> line(<<"Downloading">>,Name,Colour),none
            end,
            try Value=Run(),stop(Spinner),finish(status(Value),Name,Colour,Started),Value
            catch C:R:S -> stop(Spinner),finish(<<"Failed">>,Name,Colour,Started),erlang:raise(C,R,S) end
    end.
event(E) -> put(pooka_progress_events,[E|get(pooka_progress_events)]).
status({error,_}) -> <<"Failed">>;
status(_) -> <<"Downloaded">>.
line(Label,Name,Colour) ->
    io:put_chars(standard_error,[style(Colour),io_lib:format("~10ts",[Label]),reset(Colour)," ",Name,"\n"]).
finish(Label,Name,Colour,Started) ->
    Ms=(erlang:monotonic_time(microsecond)-Started)/1000,
    line(Label,iolist_to_binary([Name,io_lib:format(" in ~.2fms",[Ms])]),Colour).
style(true) -> "\e[1;38;2;255;137;31m";
style(false) -> "".
reset(true) -> "\e[0m";
reset(false) -> "".
%% Animate only while its parent operation is alive. A monitor and explicit stop handshake
%% keep completed commands from leaving a spinner behind.
spin(Parent,Monitor,Name,Colour,I) ->
    Frames=["⠋","⠙","⠹","⠸","⠼","⠴","⠦","⠧","⠇","⠏"],
    io:put_chars(standard_error,["\r\e[2K",style(Colour),lists:nth(I rem 10+1,Frames)," Downloading",reset(Colour)," ",Name]),
    receive
        {stop,Parent,Ref} -> io:put_chars(standard_error,"\r\e[2K"),Parent!{stopped,Ref};
        {'DOWN',Monitor,process,Parent,_} -> io:put_chars(standard_error,"\r\e[2K")
    after 80 -> spin(Parent,Monitor,Name,Colour,I+1) end.
%% Stop the owned spinner and wait for its acknowledgement before printing the final
%% progress line.
stop(none) -> ok;
stop(Pid) ->
    Ref=make_ref(),Pid!{stop,self(),Ref},
    receive {stopped,Ref}->ok after 1000 -> exit(Pid,kill) end.
