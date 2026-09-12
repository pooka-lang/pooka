%%% Ask the host whether an optional language tool is available. These helpers
%%% support real boundary tests without treating every developer machine as the
%%% same installation.
-module(ffi_test_ffi).
-export([has_executable/1]).


%% Return whether the named executable can be found on PATH. The caller
%% decides which optional runtime case to exercise.
has_executable(Name) -> os:find_executable(binary_to_list(Name)) =/= false.
