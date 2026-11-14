%% SPDX-License-Identifier: Apache-2.0

%%% Compile one native package away from the compiler's own code server.
%%% First files may provide parse transforms; they must finish before the
%%% remaining independent sources enter the bounded compilation queue.
-module(pooka_native_compile_ffi).
-export([main/0]).

main() ->
    [PlanPath] = init:get_plain_arguments(),
    {ok,Bytes} = file:read_file(PlanPath),
    %% This plan was just written by the parent compiler, not read from a
    %% package archive. It may contain package-specific macro-name atoms.
    {native_compile_v1,First,Remaining,Options} = binary_to_term(Bytes),
    case compile_first(First,Options) of
        {ok,_} -> finish(pooka_beam_ffi:compile_jobs([
            fun() -> compile_one(File,Options) end || File <- Remaining]));
        {error,_}=Error -> finish(Error)
    end.

compile_first([],_) -> {ok,[]};
compile_first([File|Rest],Options) ->
    case compile_one(File,Options) of
        {ok,_} -> compile_first(Rest,Options);
        {error,_}=Error -> Error
    end.

%% Collect compiler diagnostics as data so parallel workers cannot interleave
%% messages. The queue selects the first failing source in input order.
compile_one(File,Options) ->
    case compile:file(File,[return_errors,return_warnings|Options]) of
        {ok,_} -> {ok,nil};
        {ok,_,_Warnings} -> {ok,nil};
        {error,Errors,Warnings} -> {error,{Errors,Warnings}}
    end.

finish({ok,_}) -> halt(0);
finish({error,{Errors,Warnings}}) ->
    print_problems(Warnings),print_problems(Errors),halt(1).

print_problems(Problems) ->
    lists:foreach(fun({File,Entries}) ->
        lists:foreach(fun({Location,Module,Description}) ->
            io:format(standard_error,"~ts:~ts: ~ts~n",
                [File,location(Location),Module:format_error(Description)])
        end,Entries)
    end,Problems).

location({Line,Column}) -> io_lib:format("~p:~p",[Line,Column]);
location(Line) -> io_lib:format("~p",[Line]).
