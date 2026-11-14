%%% Check worker lifecycle without borrowing the test runner's mailbox.
-module(parallel_compile_test_ffi).
-export([crash_preserves_mailbox/0, workers_are_bounded/0, native_transform_is_unloaded/0]).

crash_preserves_mailbox() ->
    {messages,Before} = process_info(self(),messages),
    Sentinel = {sentinel,make_ref()}, self() ! Sentinel,
    Raised = try pooka_beam_ffi:compile_jobs([
        fun() -> timer:sleep(10),{ok,one} end,
        fun() -> erlang:error(compiler_worker_crash) end
    ]) of _ -> false catch error:compiler_worker_crash -> true end,
    Preserved = receive Sentinel -> true after 0 -> false end,
    {messages,After} = process_info(self(),messages),
    Raised andalso Preserved andalso Before =:= After.

workers_are_bounded() ->
    Table = ets:new(compiler_worker_count,[public]),
    true = ets:insert(Table,{active,0}),
    try
        Jobs = [fun() ->
            Active = ets:update_counter(Table,active,1),
            timer:sleep(5),
            _ = ets:update_counter(Table,active,-1),
            {ok,Active}
        end || _ <- lists:seq(1,17)],
        {ok,Counts} = pooka_beam_ffi:compile_jobs(Jobs),
        Limit = max(1,min(4,erlang:system_info(schedulers_online))),
        lists:all(fun(N) -> N >= 1 andalso N =< Limit end,Counts)
            andalso ets:lookup(Table,active) =:= [{active,0}]
    after ets:delete(Table) end.

%% A transform used only by the child compiler must not be loaded here.
native_transform_is_unloaded() -> code:is_loaded(isolated_native_transform) =:= false.
