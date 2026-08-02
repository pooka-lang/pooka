%% SPDX-License-Identifier: Apache-2.0

%%% Store checked reports in a closed drawer.
%%%
%%% Read and write versioned cache terms with failure-tolerant filesystem
%%% operations. Cached compiler state is an optimization, not an authority over
%%% fresh source.
%%%
%%% ```text
%%% cache key -> saved report, or a cache miss
%%% ```

-module(pooka_analysis_cache_ffi).
-export([key/2,load/3,save/4]).
key(Source,Imports) -> crypto:hash(sha256,term_to_binary({analysis_v1,pooka_beam_ffi:build_fingerprint(),Source,Imports},[deterministic])).
path(Directory,Identity) ->
    Name=binary:encode_hex(crypto:hash(sha256,Identity),lowercase),
    filename:join(unicode:characters_to_list(Directory),binary_to_list(Name) ++ ".cache").


%% Verify the cache version, requested key and payload hash before decoding a typed report.
%% Any read/shape failure is an ordinary cache miss.
load(Directory,Identity,Key) ->
    try
        {ok,Bytes}=file:read_file(path(Directory,Identity)),
        {pooka_analysis_v2,Key,Hash,Atoms,Payload}=binary_to_term(Bytes,[safe]),
        true=crypto:hash(sha256,term_to_binary({Atoms,Payload}))=:=Hash,
        _=[binary_to_atom(Atom,utf8) || Atom <- Atoms],
        Value=binary_to_term(Payload,[safe]),
        true=is_tuple(Value) andalso element(1,Value)=:=module andalso tuple_size(Value)=:=5,
        {ok,Value}
    catch _:_ -> {error,nil} end.
%% Write a compressed, hashed cache payload through the atomic writer. Failure to cache
%% must not make a successfully checked program fail.
save(Directory,Identity,Key,Value) ->
    try
        Path=path(Directory,Identity),ok=filelib:ensure_dir(Path),
        Payload=term_to_binary(Value,[compressed]),
        Atoms=[atom_to_binary(Atom,utf8) || Atom <- sets:to_list(atoms(Value,sets:new([{version,2}])))],
        Bytes=term_to_binary({pooka_analysis_v2,Key,crypto:hash(sha256,term_to_binary({Atoms,Payload})),Atoms,Payload}),
        _=pooka_package_ffi:write_atomic(unicode:characters_to_binary(Path),Bytes),nil
    catch _:_ -> nil end.

atoms(Value,Found) when is_atom(Value) -> sets:add_element(Value,Found);
atoms(Value,Found) when is_tuple(Value) -> atoms(tuple_to_list(Value),Found);
atoms([Head|Tail],Found) -> atoms(Tail,atoms(Head,Found));
atoms(Value,Found) when is_map(Value) -> atoms(maps:to_list(Value),Found);
atoms(_,Found) -> Found.
