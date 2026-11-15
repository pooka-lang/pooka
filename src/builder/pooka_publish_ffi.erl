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
         confirm/1, response/3, request/4, terminal/0, secret/1, secret/2, ask/1, notice/1,
         otp/0, api_key_from/2, detailed_response/3]).

%% An empty primary variable should not hide a usable fallback key.
api_key() -> api_key_from(os:getenv("HEX_API_KEY"), os:getenv("HEXPM_API_KEY")).
api_key_from(Primary, Fallback) ->
    case credential(Primary) of <<>> -> credential(Fallback); Key -> Key end.
credential(false) -> <<>>;
credential(Value) -> string:trim(unicode:characters_to_binary(Value)).
otp() -> credential(os:getenv("HEX_OTP")).

%% stdin and stderr must both be real terminal streams. In particular, a pipe
%% must never become a credential source just because stdout is a terminal.
terminal() ->
    case io:getopts(standard_io) of
        Options when is_list(Options) ->
            proplists:get_value(stdin, Options, false) andalso
            proplists:get_value(stderr, Options, false);
        _ -> false
    end.

notice(Message) -> io:put_chars(standard_error, Message), nil.
ask(Prompt) ->
    case terminal() of
        false -> false;
        true ->
            io:put_chars(standard_error, Prompt),
            case io:get_line(standard_io, "") of
                Line when is_list(Line); is_binary(Line) ->
                    lists:member(string:lowercase(string:trim(chars(Line))), ["y", "yes"]);
                _ -> false
            end
    end.

%% OTP owns hidden input and the terminal modes on Unix and Windows. Always
%% restore cooked mode, even after EOF or a read error; never use a shell or
%% fall back to visible input. See https://www.erlang.org/doc/apps/stdlib/io.html#get_password/0.
%%
%% secret(<<"Hex API key (hidden): ">>) -> {ok, <<"one-invocation-key">>}
secret(Prompt) -> secret(Prompt, fun io:get_password/0).

%% The reader is injectable so EOF/error restoration can be exercised while a
%% real terminal is still present. Production always uses OTP's hidden reader.
secret(Prompt, Read) ->
    case terminal() of
        false -> {error, <<"Hidden input requires an interactive terminal. Set HEX_API_KEY (or HEXPM_API_KEY) for non-interactive publication.">>};
        true ->
            try
                ok = shell:start_interactive({noshell, raw}),
                try
                    io:put_chars(standard_error, Prompt),
                    Read()
                of
                    Value when is_list(Value); is_binary(Value) ->
                        case credential(Value) of
                            <<>> -> {error, <<"Publication cancelled; no credential was entered.">>};
                            Key -> {ok, Key}
                        end;
                    _ -> {error, <<"Publication cancelled; no credential was entered.">>}
                after
                    ok = shell:start_interactive({noshell, cooked}),
                    io:put_chars(standard_error, "\n")
                end
            catch _:_ ->
                {error, <<"Could not read hidden input. Set HEX_API_KEY (or HEXPM_API_KEY) and retry.">>}
            end
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
    ask(<<"Upload the prepared files? [y/N] ">>).

post(URL, Key, Body) ->
    case request(URL, Key, otp(), Body) of
        {error, {http_failure, _, Detail, _}} -> {error, Detail};
        {error, {transport_failure, Detail}} -> {error, Detail};
        Result -> Result
    end.

request(URL0, Key, Code, Body) ->
    try
        URL = chars(URL0),
        #{scheme := "https", host := "hex.pm"} = uri_string:parse(URL),
        {ok, _} = application:ensure_all_started(inets),
        {ok, _} = application:ensure_all_started(ssl),
        SSL = [{verify, verify_peer}, {cacerts, public_key:cacerts_get()},
            {server_name_indication, "hex.pm"},
            {customize_hostname_check, [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}],
        OTP = case Code of <<>> -> []; _ -> [{"x-hex-otp", chars(Code)}] end,
        Headers = [{"authorization", chars(Key)}, {"accept", "application/json"}, {"user-agent", "pooka/0.2"} | OTP],
        case httpc:request(post, {URL, Headers, "application/octet-stream", Body},
                [{ssl, SSL}, {autoredirect, false}, {timeout, 60000}, {connect_timeout, 10000}], [{body_format, binary}]) of
            {ok, {{_, Status, _}, ResponseHeaders, ResponseBody}} -> detailed_response(Status, ResponseHeaders, ResponseBody);
            {error, _} -> {error, {transport_failure, <<"Could not confirm the Hex upload. Check connectivity.">>}}
        end
    catch _:_ -> {error, {transport_failure, <<"Could not confirm the Hex upload.">>}}
    end.

%% Keep status and explicit verification challenges structured for the session.
%% Do not infer an OTP challenge merely from permission-denied status 403.
detailed_response(Code, Headers, Body) ->
    case response(Code, Headers, Body) of
        {error, Detail} -> {error, {http_failure, Code, Detail, verification(Headers, Body)}};
        Success -> Success
    end.

verification(Headers, Body) ->
    Header = lists:any(fun({K, V}) ->
        string:lowercase(chars(K)) =:= "x-hex-otp" andalso
        string:lowercase(chars(V)) =:= "required"
    end, Headers),
    Data = try json:decode(Body) catch _:_ -> #{} end,
    Message = case Data of #{<<"message">> := M} when is_binary(M) -> string:lowercase(M); _ -> <<>> end,
    Header orelse lists:member(Message, [<<"two factor required">>,
        <<"two-factor authentication required">>,
        <<"two factor authentication is required for this request">>]).

%% A staged upload is accepted, but is not public. Keep that state distinct
%% from both a rejected request and a published release. The Gleam publisher
%% can then attach documentation before the author approves the release.
response(Code, Headers, Body) when Code >= 200, Code < 300 ->
    Data = try json:decode(Body) catch _:_ -> #{} end,
    Staged = case Data of #{<<"status">> := <<"staged">>} -> true; _ -> false end,
    HeaderStaged = lists:any(fun({K, V}) ->
        string:lowercase(chars(K)) =:= "location" andalso
        string:find(chars(V), "/staged") =/= nomatch
    end, Headers),
    case Staged orelse HeaderStaged of
        true -> {ok, {staged, approval_url(Data)}};
        false -> {ok, published}
    end;
response(Code, Headers, Body) ->
    Prefix = io_lib:format("Hex rejected the upload (HTTP ~p).", [Code]),
    Detail = response_detail(Body),
    Hint = case Code of
        401 -> " Check HEX_API_KEY (or HEXPM_API_KEY).";
        403 -> case verification(Headers, Body) of
            true -> " Hex requested verification; set HEX_OTP to a fresh code and retry.";
            false -> " Check the API key's publishing permissions."
        end;
        _ -> ""
    end,
    {error, unicode:characters_to_binary([Prefix, "\n", Detail, Hint])}.

%% Print only Hex's own dashboard URL, never an arbitrary URL from a response.
approval_url(#{<<"html_url">> := URL}) when is_binary(URL) ->
    case URL of
        <<"https://hex.pm/dashboard/staged-releases/", _/binary>> ->
            case byte_size(URL) =< 2048 andalso
                 lists:all(fun(C) -> C >= 33 andalso C =< 126 end, binary_to_list(URL)) of
                true -> URL;
                false -> <<"https://hex.pm/dashboard/staged-releases">>
            end;
        _ -> <<"https://hex.pm/dashboard/staged-releases">>
    end;
approval_url(_) -> <<"https://hex.pm/dashboard/staged-releases">>.

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
