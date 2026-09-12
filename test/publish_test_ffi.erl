%%% Read publication archives using Erlang's tar and term readers. Assertions
%%% here inspect the actual archive envelope and checksum rather than trusting
%%% the compiler's own reported file list.
-module(publish_test_ffi).
-export([inspect_archive/2, package_metadata/1, package_requirements/1, archive_text/2, compiles_generated_sources/1]).
%% Check the Hex v3 envelope, inner source files and documentation archive.
%% Recompute the checksum from version, metadata and compressed contents
%% before accepting the parcel.
inspect_archive(P,D)->
    {ok,Outer}=erl_tar:extract(binary_to_list(P),[memory]),
    {"VERSION",<<"3">>}=lists:keyfind("VERSION",1,Outer),
    {"metadata.config",M}=lists:keyfind("metadata.config",1,Outer),
    {ok,Tokens,_}=erl_scan:string(binary_to_list(M)),
    Terms=terms(Tokens,[],[]),
    <<"app">>=proplists:get_value(<<"app">>,Terms),
    [<<"pooka">>,<<"rebar3">>]=proplists:get_value(<<"build_tools">>,Terms),
    {"contents.tar.gz",C}=lists:keyfind("contents.tar.gz",1,Outer),
    {"CHECKSUM",Check}=lists:keyfind("CHECKSUM",1,Outer),
    Check=binary:encode_hex(crypto:hash(sha256,[<<"3">>,M,C])),
    {ok,Fs}=erl_tar:extract({binary,C},[memory,compressed]),
    Ns=[N || {N,_}<-Fs],
    true=lists:member("src/main.pooka",Ns),
    true=lists:member("src/pooka@app@main.erl",Ns),
    true=lists:member("src/app.app.src",Ns),
    true=lists:member("rebar.config",Ns),
    false=lists:any(fun(N)->lists:suffix(".beam",N) orelse lists:suffix(".abstr",N) end,Ns),true=lists:member("priv/data.txt",Ns),
    false=lists:any(fun(N)->lists:prefix("test/",N) orelse lists:prefix("build/",N) orelse lists:prefix("dev/",N) end,Ns),
    {ok,Ds}=erl_tar:extract(binary_to_list(D),[memory,compressed]),
    lists:keymember("index.html",1,Ds) andalso lists:keymember("assets/icon.svg",1,Ds).

%% Split scanner tokens at term-ending dots and parse each complete Erlang
%% term. Reversing the accumulators restores the original metadata order.
terms([],[],Acc)->lists:reverse(Acc);
terms([{dot,_}=D|Rest],Pending,Acc)->{ok,T}=erl_parse:parse_term(lists:reverse([D|Pending])),terms(Rest,[],[T|Acc]);
terms([T|Rest],Pending,Acc)->terms(Rest,[T|Pending],Acc).


%% Extract links and the declared file list from metadata.config. The Gleam
%% test compares them with the author-supplied manifest and guide sources.
package_metadata(P)->
    {ok,Outer}=erl_tar:extract(binary_to_list(P),[memory]),
    {"metadata.config",M}=lists:keyfind("metadata.config",1,Outer),
    {ok,Tokens,_}=erl_scan:string(binary_to_list(M)),
    Terms=terms(Tokens,[],[]),
    {proplists:get_value(<<"links">>,Terms),proplists:get_value(<<"files">>,Terms)}.

%% Read declared runtime requirements independently of the publisher's Report.
package_requirements(P) ->
    {ok, Outer} = erl_tar:extract(binary_to_list(P), [memory]),
    {"metadata.config", M} = lists:keyfind("metadata.config", 1, Outer),
    {ok, Tokens, _} = erl_scan:string(binary_to_list(M)),
    Metadata = terms(Tokens, [], []),
    [{N, proplists:get_value(<<"app">>, Properties),
         proplists:get_value(<<"requirement">>, Properties),
         proplists:get_value(<<"optional">>, Properties)} ||
        {N, Properties} <- proplists:get_value(<<"requirements">>, Metadata)].

archive_text(P, Name) ->
    {ok, Outer} = erl_tar:extract(binary_to_list(P), [memory]),
    {"contents.tar.gz", Contents} = lists:keyfind("contents.tar.gz", 1, Outer),
    {ok, Files} = erl_tar:extract({binary, Contents}, [memory, compressed]),
    case lists:keyfind(binary_to_list(Name), 1, Files) of
        {_, Text} -> Text;
        false -> <<>>
    end.


%% Reparse the exact published Erlang as a foreign build tool would. Runtime
%% templates are Erlang modules, so generated-Pooka no_auto_import options must
%% not accidentally disable their BIFs and guard tests.
compiles_generated_sources(P) ->
    {ok, Outer} = erl_tar:extract(binary_to_list(P), [memory]),
    {"contents.tar.gz", Contents} = lists:keyfind("contents.tar.gz", 1, Outer),
    {ok, Files} = erl_tar:extract({binary, Contents}, [memory, compressed]),
    lists:all(fun({_, Text}) ->
        {ok, Tokens, _} = erl_scan:string(unicode:characters_to_list(Text)),
        Forms = source_forms(Tokens, [], []),
        case compile:forms(Forms, [binary, return_errors, return_warnings]) of
            {ok, _, _} -> true;
            {ok, _, _, _} -> true;
            _ -> false
        end
    end, [{N,B} || {N,B} <- Files, lists:prefix("src/", N), lists:suffix(".erl", N)]).

source_forms([], [], Acc) -> lists:reverse(Acc);
source_forms([{dot,_}=Dot | Rest], Pending, Acc) ->
    {ok, Form} = erl_parse:parse_form(lists:reverse([Dot|Pending])),
    source_forms(Rest, [], [Form|Acc]);
source_forms([Token|Rest], Pending, Acc) -> source_forms(Rest, [Token|Pending], Acc).
