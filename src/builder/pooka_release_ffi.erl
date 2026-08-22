%% SPDX-License-Identifier: Apache-2.0

%%% Assemble the runtime travelling party.
%%%
%%% Use OTP release tooling at the Erlang boundary and return structured success
%%% or failure. Release packaging must not hide tool output when assembly fails.
%%%
%%% ```text
%%% OTP application resources -> release output
%%% ```

-module(pooka_release_ffi).
-include_lib("kernel/include/file.hrl").
-export([create/6]).

%% Assemble the release from its application closure and generated launcher resources.
create(Shipment0,Destination,Name0,Version0,Entry0,IncludeErts) ->
    case pooka_export_ffi:temporary_directory(Destination) of
        {error,_}=E->E;
        {ok,Stage0}->
            Stage=binary_to_list(Stage0), Shipment=binary_to_list(Shipment0),
            try
                Name=binary_to_atom(Name0,utf8), Version=binary_to_list(Version0), Entry=binary_to_atom(Entry0,utf8),
                true=re:run(Version,"^[0-9]+\\.[0-9]+\\.[0-9]+(?:[-+][0-9A-Za-z.+-]+)?$",[{capture,none}])=:=match,
                {ok,Names}=file:list_dir(Shipment),
                Candidates=maps:from_list([begin
                    P=filename:join(Shipment,N),
                    {ok,[{application,A,Props}]}=file:consult(filename:join([P,"ebin",N++".app"])),
                    {A,{P,Props}}
                end || N<-Names,filelib:is_dir(filename:join(Shipment,N))]),
                Apps=closure([Name,sasl],Candidates,#{}),
                Lib=filename:join(Stage,"lib"), ok=filelib:ensure_dir(filename:join(Lib,"placeholder")),
                Copied=maps:map(fun(A,{P,Props})->
                    V=proplists:get_value(vsn,Props),true=is_list(V),true=filename:basename(atom_to_list(A)++"-"++V)=:=atom_to_list(A)++"-"++V,
                    Target=filename:join(Lib,atom_to_list(A)++"-"++V),
                    copy_tree(filename:join(P,"ebin"),filename:join(Target,"ebin")),
                    case filelib:is_dir(filename:join(P,"priv")) of true->copy_tree(filename:join(P,"priv"),filename:join(Target,"priv"));false->ok end,
                    
                    case filelib:is_dir(filename:join(P,"native")) of true->copy_tree(filename:join(P,"native"),filename:join(Target,"native"));false->ok end,
                    {Target,Props}
                end,Apps),
                {Root,RootProps}=maps:get(Name,Copied),
                Callback=list_to_atom("pooka@"++atom_to_list(Name)++"@@release"),
                BeamFile=filename:join([Root,"ebin",atom_to_list(Callback)++".beam"]),
                false=filelib:is_file(BeamFile),
                {ok,Callback,Beam}=compile:forms(callback(Callback,Entry),[binary,return_errors]),
                ok=file:write_file(BeamFile,Beam),
                Props1=lists:keystore(mod,1,RootProps,{mod,{Callback,[]}}),
                Props2=lists:keystore(modules,1,Props1,{modules,[Callback|proplists:get_value(modules,Props1,[])]}),
                write_term(filename:join([Root,"ebin",atom_to_list(Name)++".app"]),{application,Name,Props2}),
                Releases=filename:join([Stage,"releases",Version]),ok=filelib:ensure_dir(filename:join(Releases,"placeholder")),
                Order=order([Name,sasl],Apps,[]),
                Rel={release,{atom_to_list(Name),Version},{erts,erlang:system_info(version)},[{A,proplists:get_value(vsn,element(2,maps:get(A,Apps)))} || A<-Order]},
                Base=filename:join(Releases,atom_to_list(Name)),write_term(Base++".rel",Rel),
                Paths=[filename:join(P,"ebin") || {P,_}<-maps:values(Copied)],
                case systools:make_script(Base,[{path,Paths},{variables,[{"RELEASE_LIB",Lib}]},silent]) of
                    {ok,_,_}->ok;ok->ok;Other->error({boot_script,Other})
                end,
                write_term(filename:join(Releases,"sys.config"),[]),
                ok=file:write_file(filename:join([Stage,"releases","start_erl.data"]),[erlang:system_info(version)," ",Version,"\n"]),
                
                ReleaseRecord={release,atom_to_list(Name),Version,erlang:system_info(version),[{A,proplists:get_value(vsn,element(2,maps:get(A,Apps))),"lib/"++atom_to_list(A)++"-"++proplists:get_value(vsn,element(2,maps:get(A,Apps)))} || A<-Order],permanent},
                write_term(filename:join([Stage,"releases","RELEASES"]),[ReleaseRecord]),
                case IncludeErts of true->copy_tree(filename:join(code:root_dir(),"erts-"++erlang:system_info(version)),filename:join(Stage,"erts-"++erlang:system_info(version)));false->ok end,
                Launcher=filename:join([Stage,"bin",atom_to_list(Name)]),ok=filelib:ensure_dir(Launcher),
                ok=file:write_file(Launcher,launcher(atom_to_list(Name),Version,IncludeErts)),ok=file:change_mode(Launcher,8#755),
                pooka_export_ffi:publish_directory(Stage0,Destination)
            catch C:R:Stack->{error,unicode:characters_to_binary(io_lib:format("~tp: ~tp (~tp)",[C,R,lists:sublist(Stack,3)]))}
            after file:del_dir_r(Stage) end
    end.

%% Collect the OTP applications required by the release rather than copying an arbitrary
%% development code path.
closure([],_,Seen)->Seen;
closure([A|Rest],Candidates,Seen)->
    case maps:is_key(A,Seen) of true->closure(Rest,Candidates,Seen);false->
        {P,Props}=case maps:find(A,Candidates) of
            {ok,X}->X;
            error->Dir=code:lib_dir(A),true=is_list(Dir),{ok,[{application,A,Ps}]}=file:consult(filename:join([Dir,"ebin",atom_to_list(A)++".app"])),{Dir,Ps}
        end,
        closure(proplists:get_value(applications,Props,[])++proplists:get_value(included_applications,Props,[])++Rest,Candidates,Seen#{A=>{P,Props}})
    end.
order([],_,Seen)->Seen;
order([A|Rest],Apps,Seen)->case lists:member(A,Seen) of true->order(Rest,Apps,Seen);false->
    {_,Props}=maps:get(A,Apps),Prior=order(proplists:get_value(applications,Props,[]),Apps,Seen),order(Rest,Apps,Prior++[A]) end.
write_term(Path,Term)->ok=file:write_file(Path,io_lib:format("~tp.~n",[Term])).
copy_tree(Source,Target)->
    case file:read_link_info(Source) of
        {ok,#file_info{type=directory}}->{ok,Names}=file:list_dir(Source),ok=filelib:ensure_dir(filename:join(Target,"placeholder")),lists:foreach(fun(N)->copy_tree(filename:join(Source,N),filename:join(Target,N)) end,Names);
        {ok,#file_info{type=regular,mode=Mode}}->{ok,_}=file:copy(Source,Target),ok=file:change_mode(Target,Mode);
        Other->error({invalid_release_resource,Source,Other})
    end.






callback(Module,Entry)->
    A=fun(X)->{atom,1,X} end,V=fun(X)->{var,1,X} end,
    Call=fun(M,F,Args)->{call,1,{remote,1,A(M),A(F)},Args} end,
    Worker={'fun',1,{clauses,[{clause,1,[],[],[Call(Entry,main,[]),{'receive',1,[{clause,1,[A(stop)],[],[A(ok)]}]}]}]}},
    [{attribute,1,module,Module},{attribute,1,behaviour,application},{attribute,1,export,[{start,2},{stop,1}]},
     {function,1,start,2,[{clause,1,[V('_'),V('_')],[],[{tuple,1,[A(ok),Call(erlang,spawn_link,[Worker])]}]}]},
     {function,1,stop,1,[{clause,1,[V('_')],[],[A(ok)]}]}].
launcher(Name,V,Include)->
    Runtime=case Include of true->["ROOTDIR=$BASE\nBINDIR=$BASE/erts-",erlang:system_info(version),"/bin\nEMU=beam\nPROGNAME=erl\nexport ROOTDIR BINDIR EMU PROGNAME\nERL=$BINDIR/erlexec\n"];false->"ERL=${ERL:-erl}\n" end,
    ["#!/bin/sh\nset -eu\nBASE=$(CDPATH= cd -- \"$(dirname -- \"$0\")/..\" && pwd)\n",Runtime,
     "COMMAND=${1-run}\nif [ \"$#\" -gt 0 ]; then shift; fi\ncase \"$COMMAND\" in\nrun) exec \"$ERL\" -noshell -boot \"$BASE/releases/",V,"/",Name,"\" -boot_var RELEASE_LIB \"$BASE/lib\" -config \"$BASE/releases/",V,"/sys\" -extra \"$@\" ;;\nconsole) exec \"$ERL\" -boot \"$BASE/releases/",V,"/",Name,"\" -boot_var RELEASE_LIB \"$BASE/lib\" -config \"$BASE/releases/",V,"/sys\" -extra \"$@\" ;;\n*) echo 'usage: ",Name," [run|console] [arguments...]' >&2; exit 1 ;;\nesac\n"].
