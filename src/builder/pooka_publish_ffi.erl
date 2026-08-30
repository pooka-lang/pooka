%% SPDX-License-Identifier: Apache-2.0

%%% Prepare two parcels: source for the registry, pages for its reading room.
%%%
%%% Generated Erlang exists only in the in-memory publication file list. Ordinary
%%% builds still use compile:forms and keep their binary abstract-form artifacts.
%%% A foreign build tool can compile the parcel without installing Pooka.
%%%
%%% ```text
%%% production BEAM -> abstract code -> src/*.erl + src/*.app.src
%%% ```
-module(pooka_publish_ffi).
-include_lib("kernel/include/file.hrl").
-export([archive/12, sources/1, post/3, api_key/0,
         confirm/1, response/3]).

api_key() ->
    case os:getenv("HEX_API_KEY") of
        false -> case os:getenv("HEXPM_API_KEY") of
            false -> <<>>;
            Value -> unicode:characters_to_binary(Value)
        end;
        Value -> unicode:characters_to_binary(Value)
    end.

%% Read the production application's own module inventory, never sibling/test
%% modules. Erlang FFI includes are already expanded in abstract code, so their
%% published source is self-contained too.
sources(Ebin0) ->
    Ebin = chars(Ebin0),
    try
        [App] = filelib:wildcard(filename:join(Ebin, "*.app")),
        {ok, [{application, Name, Properties}]} = file:consult(App),
        Modules = lists:sort(proplists:get_value(modules, Properties)),
        Erlang = [{unicode:characters_to_binary("src/" ++ atom_to_list(M) ++ ".erl"),
                   source(read(filename:join(Ebin, atom_to_list(M) ++ ".beam")),
                          filelib:is_regular(filename:join([filename:dirname(Ebin),
                              "_pooka_artefacts", atom_to_list(M) ++ ".abstr"])))} || M <- Modules],
        {ok, [{unicode:characters_to_binary("src/" ++ atom_to_list(Name) ++ ".app.src"),
               read(App)} | Erlang]}
    catch throw:{publish, Message} -> {error, Message};
          Class:Reason -> problem("Could not prepare generated Erlang", Class, Reason)
    end.

%% erl_pp prints complete forms, including record/type declarations. Keep the
%% generated modules' no_auto_import option, but do not apply it to Erlang FFI.
%% Remove machine-local file paths from the portable parcel.
%%
%% ```erlang
%% {function,L,answer,0,Clauses} -> answer() -> 42.
%% ```
%% https://www.erlang.org/doc/apps/erts/absform.html#module-declarations-and-forms
source(Binary, Generated) ->
    case beam_lib:chunks(Binary, [abstract_code]) of
        {ok, {_, [{abstract_code, {raw_abstract_v1, Forms}}]}} ->
            Portable = [case Form of
                {attribute, L, file, {Path, Line}} ->
                    {attribute, L, file, {filename:basename(Path), Line}};
                _ -> Form
            end || Form <- Forms],
            Options = case Generated of
                true -> [{attribute, 1, compile, no_auto_import},
                         {attribute, 1, compile, [nowarn_unused_vars, nowarn_unused_function, nowarn_nomatch, nowarn_ignored]}];
                false -> []
            end,
            %% Latin-1 source is not sufficient for Pooka strings and docs.
            unicode:characters_to_binary(["%% coding: utf-8\n",
                [erl_pp:form(portable_form(F), [{hook, fun explicit_bif/4}, {encoding, utf8}]) || F <- Portable ++ Options]]);
        _ -> fail("A module has no Erlang abstract code. Rebuild its FFI with debug_info before publishing.")
    end.

%% erl_pp normally shortens erlang:setelement(...) to setelement(...).
%% That changes meaning when a generated module shadows a BIF or disables
%% auto-imports. Mark only explicit Erlang calls for a small printing hook.
%% legalize_vars also repairs compiler-generated record variables from Erlang FFI.
%%
%% ```erlang
%% {call,L,{remote,L,{atom,L,erlang},{atom,L,length}},[Xs]}
%% % must remain erlang:length(Xs), even beside a local length/1.
%% ```
%% https://www.erlang.org/doc/apps/erts/absform.html#expressions
portable_form({function, _, _, _, _} = Form) ->
    explicit_calls(erl_pp:legalize_vars(Form));
portable_form(Form) -> explicit_calls(Form).

explicit_calls({call, Line, {remote, _, {atom, _, erlang}, {atom, _, Function}}, Args}) ->
    {pooka_explicit_erlang_call, Line, Function, [explicit_calls(A) || A <- Args]};
explicit_calls(Tuple) when is_tuple(Tuple) ->
    list_to_tuple([explicit_calls(E) || E <- tuple_to_list(Tuple)]);
explicit_calls(List) when is_list(List) -> [explicit_calls(E) || E <- List];
explicit_calls(Value) -> Value.

explicit_bif({pooka_explicit_erlang_call, Line, Function, Args}, Indent, _Prec, Options) ->
    ["erlang:", erl_pp:expr({atom, Line, Function}), "(",
     erl_pp:exprs(Args, Indent, Options), ")"].

%% The whole output directory is replaced only after both archives are ready.
%% Duplicate paths are errors: silently preferring source over generated code
%% would let a tarball compile differently from the checked production build.
archive(Root0, Docs0, Name, Version, Description, Licences, Links,
        Requirements, PageSources, Generated, Tools, IncludeSources) ->
    Root = chars(Root0),
    Destination = filename:join([Root, "build", "publish", chars(Name)]),
    case filelib:ensure_dir(Destination) of
        {error, Reason} -> problem("Could not create publication directory", error, Reason);
        ok -> archive_ready(Root, Docs0, Name, Version, Description, Licences, Links,
                            Requirements, PageSources, Generated, Tools, IncludeSources, Destination)
    end.

archive_ready(Root, Docs0, Name, Version, Description, Licences, Links,
              Requirements, PageSources, Generated, Tools, IncludeSources, Destination) ->
    case pooka_export_ffi:temporary_directory(binary(Destination)) of
        {error, _} = Error -> Error;
        {ok, Stage0} ->
            Stage = chars(Stage0),
            try
                Selected = case IncludeSources of
                    true ->
                        {ok, Names} = file:list_dir(Root),
                        [N || N <- lists:sort(Names), publishable(N)];
                    false -> []
                end,
                Guides = case IncludeSources of
                    true -> [safe_path(chars(P)) || P <- PageSources];
                    false -> []
                end,
                Original = lists:append([files(Root, N) || N <- lists:usort(Selected ++ Guides)]),
                Extra = [{safe_path(chars(N)), B} || {N, B} <- Generated],
                Files = unique_files(Original ++ Extra),
                FileNames = [binary(N) || {N, _} <- Files],
                Metadata = [{<<"name">>, Name}, {<<"app">>, Name}, {<<"version">>, Version},
                    {<<"description">>, Description}, {<<"licenses">>, Licences},
                    {<<"links">>, Links}, {<<"build_tools">>, Tools}, {<<"files">>, FileNames},
                    {<<"requirements">>, [{N, [{<<"app">>, A}, {<<"optional">>, O},
                        {<<"requirement">>, R}, {<<"repository">>, <<"hexpm">>}]} || {N,A,R,O} <- Requirements]}],
                Meta = iolist_to_binary([io_lib:format("~tp.~n", [Term]) || Term <- Metadata]),
                Inner = filename:join(Stage, "contents.tar.gz"),
                check_size(lists:sum([byte_size(B) + 1024 || {_, B} <- Files]), 134217728),
                ok = erl_tar:create(Inner, Files, [compressed]),
                Contents = read(Inner),
                Check = binary:encode_hex(crypto:hash(sha256, [<<"3">>, Meta, Contents])),
                PackageName = chars(Name) ++ "-" ++ chars(Version) ++ ".tar",
                ok = erl_tar:create(filename:join(Stage, PackageName),
                    [{"VERSION", <<"3">>}, {"metadata.config", Meta},
                     {"contents.tar.gz", Contents}, {"CHECKSUM", Check}], []),
                check_size(byte_size(read(filename:join(Stage, PackageName))), 16777216),
                ok = file:delete(Inner),
                {ok, DocNames} = file:list_dir(chars(Docs0)),
                PageFiles = lists:append([files(chars(Docs0), N) || N <- lists:sort(DocNames)]),
                %% Documentation generation already stages README assets. The
                %% archive must match the local preview exactly, without a
                %% second copy that could collide or change after rendering.
                DocFiles = PageFiles,
                DocsName = chars(Name) ++ "-" ++ chars(Version) ++ "-docs.tar.gz",
                check_size(lists:sum([byte_size(B) + 1024 || {_, B} <- DocFiles]), 134217728),
                ok = erl_tar:create(filename:join(Stage, DocsName), DocFiles, [compressed]),
                check_size(byte_size(read(filename:join(Stage, DocsName))), 16777216),
                case pooka_export_ffi:publish_directory(Stage0, binary(Destination)) of
                    {ok, nil} -> {ok, {binary(filename:join(Destination, PackageName)),
                                      binary(filename:join(Destination, DocsName)), FileNames}};
                    Error -> Error
                end
            catch throw:{publish, Message} -> {error, Message};
                  Class:Reason -> problem("Could not create publication archives", Class, Reason)
            after file:del_dir_r(Stage)
            end
    end.

check_size(Size, Limit) when Size =< Limit -> ok;
check_size(_, _) -> fail("Publication archive exceeds Hex's 16 MiB compressed or 128 MiB uncompressed limit.").

publishable(Name) ->
    lists:member(Name, ["pooka.toml", "src", "ffi", "priv", "include", "assets"])
        orelse lists:any(fun(Prefix) -> lists:prefix(Prefix, string:lowercase(Name)) end,
                         ["readme", "license", "licence", "changelog"]).

safe_path(Path) ->
    Parts = filename:split(Path),
    case filename:pathtype(Path) =:= relative andalso
         not lists:member("..", Parts) andalso Path =/= "" of
        true -> filename:join([P || P <- Parts, P =/= "."]);
        false -> fail("Publication files must have relative paths inside the package.")
    end.

unique_files(Files) ->
    Names = [N || {N, _} <- Files],
    case length(Names) =:= length(lists:usort(Names)) of
        true -> lists:keysort(1, Files);
        false -> fail("A source file conflicts with a generated publication file. Rename or remove the conflicting file.")
    end.

files(Root, Relative) ->
    Path = filename:join(Root, Relative),
    case file:read_link_info(Path) of
        {ok, #file_info{type = directory}} ->
            {ok, Names} = file:list_dir(Path),
            lists:append([files(Root, filename:join(Relative, N)) || N <- lists:sort(Names), not ignored(N)]);
        {ok, #file_info{type = regular}} -> [{Relative, read(Path)}];
        _ -> fail("Publication resources must be regular files or directories; symbolic links are not included.")
    end.

ignored(Name) ->
    lists:prefix(".", Name) orelse
        lists:member(Name, ["build", "test", "dev", "node_modules"]) orelse
        lists:suffix("~", Name) orelse lists:suffix(".beam", Name) orelse
        lists:suffix(".abstr", Name).

%% Do not echo credentials or store them in the project. EOF is a refusal, so
%% piping a command without --yes cannot accidentally approve publication.
confirm(Preview) ->
    io:put_chars(standard_error, Preview),
    case io:get_line(standard_io, "Publish this package and its documentation? [y/N] ") of
        Line when is_list(Line) -> lists:member(string:lowercase(string:trim(Line)), ["y", "yes"]);
        _ -> false
    end.

post(URL0, Key, Body) ->
    try
        URL = chars(URL0),
        #{scheme := "https", host := "hex.pm"} = uri_string:parse(URL),
        {ok, _} = application:ensure_all_started(inets),
        {ok, _} = application:ensure_all_started(ssl),
        SSL = [{verify, verify_peer}, {cacerts, public_key:cacerts_get()},
            {server_name_indication, "hex.pm"},
            {customize_hostname_check, [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}],
        OTP = case os:getenv("HEX_OTP") of false -> []; OtpCode -> [{"x-hex-otp", OtpCode}] end,
        Headers = [{"authorization", chars(Key)}, {"accept", "application/json"}, {"user-agent", "pooka/0.1"} | OTP],
        case httpc:request(post, {URL, Headers, "application/octet-stream", Body},
                [{ssl, SSL}, {autoredirect, false}, {timeout, 60000}, {connect_timeout, 10000}], [{body_format, binary}]) of
            {ok, {{_, Code, _}, ResponseHeaders, ResponseBody}} -> response(Code, ResponseHeaders, ResponseBody);
            {error, _} -> {error, <<"Could not connect to Hex. Check connectivity and retry.">>}
        end
    catch _:_ -> {error, <<"Could not send the Hex upload.">>}
    end.

%% A staged release is not public yet. Never announce it as a finished upload;
%% point the author at Hex so they can approve it and retry documentation.
response(Code, Headers, _Body) when Code >= 200, Code < 300 ->
    case lists:any(fun({K, V}) -> string:lowercase(chars(K)) =:= "location" andalso
                    string:find(chars(V), "/staged") =/= nomatch end, Headers) of
        true -> {error, <<"Hex staged this upload for review. Approve it in your Hex dashboard, then retry the documentation upload if needed.">>};
        false -> {ok, nil}
    end;
response(Code, _, Body) ->
    Prefix = io_lib:format("Hex rejected the upload (HTTP ~p).", [Code]),
    Detail = response_detail(Body),
    Hint = case Code of
        401 -> " Check HEX_API_KEY (or HEXPM_API_KEY).";
        403 -> " If Hex requests two-factor authentication, set HEX_OTP to a fresh code and retry.";
        _ -> ""
    end,
    {error, unicode:characters_to_binary([Prefix, "\n", Detail, Hint])}.

response_detail(Body) ->
    Text = try json:decode(Body) of
        #{<<"message">> := Message, <<"errors">> := Errors} when is_map(Errors) ->
            [Message, [["\n", Key, ": ", io_lib:format("~tp", [Value])] || {Key, Value} <- lists:sort(maps:to_list(Errors))]];
        #{<<"message">> := Message} when is_binary(Message) -> Message;
        _ -> Body
    catch _:_ -> Body
    end,
    %% Registry text is untrusted terminal input; preserve newlines, not control
    %% sequences. Bound it by characters so UTF-8 is never cut in half.
    Characters = case unicode:characters_to_list(iolist_to_binary(Text)) of
        List when is_list(List) -> List;
        {_, Prefix, _} -> Prefix
    end,
    unicode:characters_to_binary(lists:sublist([C || C <- Characters,
        C =:= 10 orelse C =:= 9 orelse (C >= 32 andalso C =/= 127 andalso not (C >= 128 andalso C =< 159))], 4096)).

read(Path) ->
    case file:read_file(Path) of
        {ok, Bytes} -> Bytes;
        {error, Reason} -> fail(io_lib:format("Could not read ~ts: ~tp", [filename:basename(Path), Reason]))
    end.

fail(Message) -> throw({publish, unicode:characters_to_binary(Message)}).
problem(Label, Class, Reason) ->
    {error, unicode:characters_to_binary(io_lib:format("~ts (~tp: ~tp).", [Label, Class, Reason]))}.
chars(Value) when is_binary(Value) -> unicode:characters_to_list(Value);
chars(Value) when is_list(Value) -> Value.
binary(Value) -> unicode:characters_to_binary(Value).
