%% SPDX-License-Identifier: Apache-2.0
%%% Read a dependency's configuration in its own room.
%%%
%%% Rebar scripts can change directories, application state or the environment.
%%% Evaluate them in a short-lived VM whose working directory is the package,
%%% then return only the resulting configuration to the compiler.
-module(pooka_rebar_config_ffi).
-export([main/0]).

main() ->
    [Output] = init:get_plain_arguments(),
    Result = try
        {ok, Root} = file:get_cwd(),
        Config = case file:consult(filename:join(Root, "rebar.config")) of
            {ok, Terms} -> Terms;
            {error, enoent} -> [];
            {error, Reason} -> error({invalid_rebar_config, Reason})
        end,
        Script = filename:join(Root, "rebar.config.script"),
        case file:script(Script, [{'CONFIG', Config}, {'SCRIPT', Script}]) of
            {ok, Value} when is_list(Value) -> {ok, Value};
            {ok, _} -> {error, <<"rebar.config.script must return a configuration list">>};
            {error, Error} -> {error, unicode:characters_to_binary(io_lib:format("Invalid rebar.config.script: ~tp", [Error]))}
        end
    catch Class:Failure ->
        {error, unicode:characters_to_binary(io_lib:format("rebar.config.script failed: ~tp:~tp", [Class, Failure]))}
    end,
    ok = file:write_file(Output, term_to_binary(Result)),
    halt(0).
