%%% Borrow environment and permission settings for incremental-build fixtures.
%%% The environment wrapper restores its previous value even when the test body
%%% raises, so the next test does not inherit the borrowed setting.
-module(incremental_test_ffi).
-export([with_environment/3, executable/1]).
%% Save the host value, run the callback with the requested value, and restore
%% absence or the previous value in after. Cleanup runs on exceptional exits
%% too.
with_environment(NameBinary,ValueBinary,Run) ->
    Name = unicode:characters_to_list(NameBinary),
    Previous = os:getenv(Name),
    true = os:putenv(Name,unicode:characters_to_list(ValueBinary)),
    try Run()
    after case Previous of false -> os:unsetenv(Name); Value -> os:putenv(Name,Value) end end.
%% Mark a generated fixture script executable using the POSIX mode expected by
%% the subprocess tests. Return the Gleam Nil representation on success.
executable(Path) ->
    ok = file:change_mode(unicode:characters_to_list(Path),8#755),nil.
