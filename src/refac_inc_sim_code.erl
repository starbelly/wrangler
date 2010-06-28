%% Copyright (c) 2010, Huiqing Li, Simon Thompson
%% All rights reserved.
%%
%% Redistribution and use in source and binary forms, with or without
%% modification, are permitted provided that the following conditions are met:
%%     %% Redistributions of source code must retain the above copyright
%%       notice, this list of conditions and the following disclaimer.
%%     %% Redistributions in binary form must reproduce the above copyright
%%       notice, this list of conditions and the following disclaimer in the
%%       documentation and/or other materials provided with the distribution.
%%     %% Neither the name of the copyright holders nor the
%%       names of its contributors may be used to endorse or promote products
%%       derived from this software without specific prior written permission.
%%
%% THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS ''AS IS''
%% AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE 
%% IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE 
%% ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDERS AND CONTRIBUTORS 
%% BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR 
%% CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF 
%% SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR 
%% BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, 
%% WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR 
%% OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF 
%% ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
%% ===========================================================================================
%% Purpose: Incremental, and on-line, similar code detection for Erlang programs.
%%
%% Author contact: hl@kent.ac.uk, sjt@kent.ac.uk
%% 
-module(refac_inc_sim_code).

-export([inc_sim_code_detection/8]).

-include("../include/wrangler.hrl").

-define(DefaultSimiScore, 0.8).

-define(DEFAULT_LEN, 5).
-define(DEFAULT_TOKS, 20).
-define(DEFAULT_FREQ, 2).
-define(DEFAULT_SIMI_SCORE, 0.8).
-define(DEFAULT_NEW_VARS, 5).

-define(ASTTab, list_to_atom(filename:join(?WRANGLER_DIR, "plt/ast_tab"))).
-define(FileHashTab, list_to_atom(filename:join(?WRANGLER_DIR, "plt/file_hash_tab"))).
-define(VarTab, list_to_atom(filename:join(?WRANGLER_DIR, "plt/var_tab"))).
-define(ExpHashTab, list_to_atom(filename:join(?WRANGLER_DIR, "plt/exp_hash_tab"))).
-define(ExpSeqFile, list_to_atom(filename:join(?WRANGLER_DIR, "plt/exp_seq_file"))).

-record(threshold, 
	{min_len = ?DEFAULT_LEN,
	 min_freq= ?DEFAULT_FREQ,
	 min_toks= ?DEFAULT_TOKS,
	 max_new_vars =?DEFAULT_NEW_VARS,
	 simi_score=?DEFAULT_SIMI_SCORE}).

-record(tabs, 
	{ast_tab,
	 var_tab, 
	 file_hash_tab,
	 exp_hash_tab}).


%% TODO: CHECK THE GENERATION OF NEW VARS;
%%      ADD COMMMENTS;
%%      GENRATE THE FUNCTION CALL AUTOMATICALLY;
%%      REUSE.


%%% % clone record; 
%% -record(clone, 
%% 	{ranges, 
%% 	 len, 
%% 	 freq, 
%% 	 au}).

-spec(inc_sim_code_detection/8::(DirFileList::[filename()|dir()], MinLen::float(), MinToks::integer(),
				 MinFreq::integer(),  MaxVars:: integer(),SimiScore::float(), 
				 SearchPaths::[dir()], TabWidth::integer()) -> {ok, string()}).
inc_sim_code_detection(DirFileList, MinLen, MinToks, MinFreq, MaxVars, SimiScore, SearchPaths, TabWidth) ->
    ?wrangler_io("\nCMD: ~p:sim_code_detection(~p,~p,~p,~p, ~p,~p,~p).\n",
		 [?MODULE, DirFileList, MinLen, MinToks, MinFreq, SimiScore, SearchPaths, TabWidth]),
    Files = refac_util:expand_files(DirFileList, ".erl"),
    case Files of
	[] ->
	    ?wrangler_io("Warning: No files found in the searchpaths specified.", []);
	_ ->
	    Tabs=#tabs{ast_tab=from_dets(ast_tab, ?ASTTab),
		       var_tab=from_dets(var_tab, ?VarTab),
		       file_hash_tab=from_dets(file_hash_tab, ?FileHashTab),
		       exp_hash_tab=from_dets(expr_hash_tab, ?ExpHashTab)},
	    Threshold=#threshold{min_len=MinLen, 
				 min_freq=MinFreq, 
				 min_toks=MinToks, 
				 max_new_vars=MaxVars,
				 simi_score=SimiScore},
	    ASTPid = start_ast_process(Tabs#tabs.ast_tab),	    
	    inc_sim_code_detection(Files, Threshold, Tabs, ASTPid, SearchPaths, TabWidth),
	    stop_ast_process(ASTPid),
	    to_dets(Tabs#tabs.ast_tab, ?ASTTab),
	    to_dets(Tabs#tabs.var_tab, ?VarTab),
	    to_dets(Tabs#tabs.file_hash_tab, ?FileHashTab),
	    to_dets(Tabs#tabs.exp_hash_tab, ?ExpHashTab)	    
    end,
    {ok, "Clone detection finish."}.


inc_sim_code_detection(Files, Thresholds, Tabs, ASTPid, SearchPaths, TabWidth) ->
    Time1 = time(),
    generalise_and_hash_ast(Files, Thresholds, Tabs, ASTPid,SearchPaths, TabWidth),
    ?wrangler_io("Generalise and has hash finished.\n", []),
    Dir = filename:dirname(hd(Files)),
    Cs = get_clone_candidates(ASTPid, Thresholds, Dir),
    ?debug("\nInitial candiates finished\n", []),
    ?wrangler_io("\nNumber of initial clone candidates: ~p\n", [length(Cs)]),
    CloneCheckerPid = start_clone_check_process(),
    TmpASTTab= ets:new(tmp_ast_tab, [set, public]),
    Cs2 = examine_clone_candidates(Cs, Thresholds, Tabs, TmpASTTab,CloneCheckerPid, 1),
    ets:delete(TmpASTTab),
    stop_clone_check_process(CloneCheckerPid),
    Time2 = time(),
    refac_code_search_utils:display_clone_result(Cs2, "Similar"),
    refac_io:format("Time used: \n~p\n",[{Time1,Time2}]).
    
 
%% Serialise, in breath-first order, and generalise each expression in the AST,
%% and insert them into the AST table. Each object in the AST table has the following format:
%% {{FileName, FunName, Arity, Index}, ExprAST}, where Index is used to identify a specific 
%% expression in the function. 

%%QUESTION: how to check whether a file/function has been changed or not.
%% for files, use MD5; for functions, a function has to be parsed and prettyprinted before
%% calculating its MD5 value.

generalise_and_hash_ast(Files, Threshold, Tabs, ASTPid, SearchPaths, TabWidth) ->	     
   %% refac_io:format("\nLists:~p\n", [ets:tab2list(Tabs#tabs.file_hash_tab)]),
    lists:foreach(fun(File) ->
			  NewCheckSum=refac_misc:filehash(File),
			  case ets:lookup(Tabs#tabs.file_hash_tab, File) of
			      [{File, NewCheckSum}]->
				  refac_io:format("\nFile Not changed\n"),
				  ok;
			      [{File, _NewCheckSum1}]->
				  refac_io:format("\n File changed\n"),
				  ets:insert(Tabs#tabs.file_hash_tab, {File, NewCheckSum}),
				  generalise_and_hash_ast_1(File,Threshold, Tabs, 
							    ASTPid, false, SearchPaths, TabWidth);
			      [] ->
				  refac_io:format("New file\n"),
				  ets:insert(Tabs#tabs.file_hash_tab, {File, NewCheckSum}),
				  generalise_and_hash_ast_1(File,Threshold, Tabs, 
							    ASTPid, true, SearchPaths, TabWidth)
			  end
		  end, Files).


generalise_and_hash_ast_1(FName, Threshold, Tabs, ASTPid, IsNewFile, SearchPaths, TabWidth) ->
    Fun = fun (Form) ->
		  case refac_syntax:type(Form) of
		    function ->
			FunName = refac_syntax:atom_value(refac_syntax:function_name(Form)),
			Arity = refac_syntax:function_arity(Form),
			MinLen = Threshold#threshold.min_len,
			HashVal = erlang:md5(refac_prettypr:format(Form)),
			case IsNewFile of
			    true -> 
				generalise_and_hash_a_form(FName, Form, FunName, Arity, HashVal, MinLen, Tabs, ASTPid);
			    false ->
				case ets:lookup(Tabs#tabs.var_tab, {FName, FunName, Arity}) of
				    [{{FName, FunName, Arity}, HashVal, _VarInfo}] ->
					ok;   %% this function has not been syntacaically changed.
				    _ -> 
					generalise_and_hash_a_form(FName, Form, FunName, Arity, HashVal, MinLen, Tabs, ASTPid)
				end
			end;
		      _ -> ok
		  end
	  end,
    {ok, {AnnAST, _Info}} = refac_util:quick_parse_annotate_file(FName, SearchPaths, TabWidth),
    refac_syntax:form_list_elements(AnnAST),
    lists:foreach(fun (F) -> Fun(F) end, refac_syntax:form_list_elements(AnnAST)).

generalise_and_hash_a_form(FName, Form, FunName, Arity, HashVal, MinLen, Tabs, ASTPid) ->
    {Form1,_} = abs_to_relative_loc(Form),
    refac_io:format("Form1:\n~p\n", [Form1]),
    AllVars = refac_misc:collect_var_source_def_pos_info(Form1),
    ets:insert(Tabs#tabs.var_tab, {{FName, FunName, Arity}, HashVal, AllVars}),
    ast_traverse_api:full_tdTP(fun generalise_and_hash_ast_2/2,
			       Form1, {FName, FunName, Arity, ASTPid, MinLen}).

abs_to_relative_loc(Form) ->
    {L,_C} = refac_syntax:get_pos(Form),
    refac_io:format("L:\n~p\n", [L]),
    ast_traverse_api:full_tdTP(fun do_abs_to_relative_loc/2, Form,  L).

do_abs_to_relative_loc(Node, StartLine)->
    As = refac_syntax:get_ann(Node),
    As1 = [abs_to_relative_loc_in_ann(A, StartLine)||A<-As],
    {refac_syntax:set_ann(Node, As1), true}.

abs_to_relative_loc_in_ann(Ann, StartLine) ->
    case Ann of
	{range, {{L1, C1},{L2, C2}}} ->
	    {range, {{to_relative(L1,StartLine), C1}, {to_relative(L2,StartLine), C2}}};
	{bound, Vars} ->
	    {bound, [{V, {to_relative(L,StartLine),C}}||{V, {L,C}}<-Vars]};
	{free, Vars} ->
	    {free, [{V, {to_relative(L,StartLine),C}}||{V, {L,C}}<-Vars]};
	{def, Locs} ->
	    {def, [{to_relative(L,StartLine),C}||{L, C}<-Locs]};
	{fun_def, {M, F, A,{L1, C1},{L2, C2}}} ->
	    {fun_def, {M, F, A, {to_relative(L1,StartLine),C1}, 
		       {to_relative(L2,StartLine), C2}}};
	{toks, _} ->
	    {toks, []};
	{env, _} ->
	    {env, []};
	_ -> Ann
    end.
to_relative(Line, StartLine) ->
    case Line >0 of 
	true ->
	    Line-StartLine+1;
	false ->
	    Line
    end.

		
generalise_and_hash_ast_2(Node, {FName, FunName, Arity, ASTPid, MinLen}) ->
    F=fun(Body) ->
	      case length(Body)>=MinLen of
	       	  true ->  
		      %% only store those expression sequences whose length is 
		      %% greater than the threshold specified.
		      insert_to_ast_tab(ASTPid, {{FName, FunName, Arity}, Body});
		  false ->
		      ok
	      end
      end,
    case refac_syntax:type(Node) of
	clause ->
	    Body = refac_syntax:clause_body(Node),
	    F(Body),
	    {Node, false};
	block_expr ->
	    Body = refac_syntax:block_expr_body(Node),
	    F(Body),		
	    {Node, false};
	try_expr ->
	    Body = refac_syntax:try_expr_body(Node),
	    F(Body),
	    {Node, false};
	_ -> {Node, false}
    end.

%% returns true if the expression can be replaced by a variable. 
%% Note: we don't replace arbitary expressions with variables!
variable_replaceable(Exp) ->
    case lists:keysearch(category, 1, refac_syntax:get_ann(Exp)) of
	{value, {category, record_field}} -> false;
	{value, {category, record_type}} -> false;
	{value, {category, guard_expression}} -> false;
	{value, {category, macro_name}} -> false;
	{value, {category, pattern}} ->
	    refac_syntax:is_literal(Exp) orelse
		refac_syntax:type(Exp) == variable;
	_ ->
	    T = refac_syntax:type(Exp),
	    not lists:member(T, [match_expr, operator, generator,case_expr, if_expr, fun_expr, 
				 receive_expr, clause, query_expr, try_expr,
				 catch_expr, cond_expr, block_expr]) andalso
		refac_misc:get_var_exports(Exp) == [] 
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                                                                    %%
%% Store the AST representation of expression statements in ETS table %%
%%                                                                    %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
start_ast_process(ASTTab) ->
    HashPid = start_hash_process(),
    spawn_link(fun()-> 
		       ast_loop(ASTTab, {'_','_','_', 1, HashPid})
	       end).

stop_ast_process(Pid)->
    Pid ! stop.

insert_to_ast_tab(Pid, {{M, F, A}, ExprASTs}) ->
    Pid ! {add, {{M, F, A}, ExprASTs}}.

get_clone_candidates(Pid, Thresholds, Dir) ->
    Pid ! {get_clone_candidates, self(), Thresholds, Dir},
    receive
      {Pid, Cs} ->
	  Cs
    end.

ast_loop(ASTTab, {CurM, CurF, CurA, Index, HashPid}) ->
    receive
      {add, {{M, F, A}, ExprASTs}} ->
	  case {M, F, A} == {CurM, CurF, CurA} of
	    true ->
		Len = length(ExprASTs),
		ExprASTsWithIndex = lists:zip(ExprASTs, lists:seq(0, Len - 1)),
		[begin
		     NoOfToks = no_of_tokens(E),
		     ets:insert(ASTTab, {{M, F, A, Index + I}, E}),   %%TODO: WHAT ELSE INFO CAN BE REMOVED?
		     E1 = do_generalise(E),
		     HashVal = erlang:md5(refac_prettypr:format(E1)),
		     StartEndLoc=refac_misc:get_start_end_loc(E),
		     insert_hash(HashPid, {HashVal, {{M, F, A, Index + I}, NoOfToks, StartEndLoc}})
		 end || {E, I} <- ExprASTsWithIndex],
		  insert_dummy_entry(HashPid),
		  ast_loop(ASTTab, {CurM, CurF, CurA, Index + Len, HashPid});
	    false ->
		Len = length(ExprASTs),
		ExprASTsWithIndex = lists:zip(ExprASTs, lists:seq(1, Len)),
		[begin
		     NoOfToks = no_of_tokens(E),
		     ets:insert(ASTTab, {{M, F, A, I}, E}),
		     E1 = do_generalise(E),
		     HashVal = erlang:md5(refac_prettypr:format(E1)),
		     StartEndLoc=refac_misc:get_start_end_loc(E),
		     insert_hash(HashPid, {HashVal, {{M, F, A, I}, NoOfToks, StartEndLoc}})
		 end || {E, I} <- ExprASTsWithIndex],
		  insert_dummy_entry(HashPid),
		  ast_loop(ASTTab, {M, F, A, Len + 1, HashPid})
	  end;
      {get_clone_candidates, From, Thresholds, Dir} ->
	    Cs = get_clone_candidates(HashPid, Thresholds, Dir),
	    From ! {self(), Cs},
	    ast_loop(ASTTab, {CurM, CurF, CurA, Index, HashPid});
      stop ->
	    stop_hash_process(HashPid),
	    ok;
	_Msg -> 
	    ?wrangler_io("Unexpected message:\n~p\n",[_Msg]),
	    ok
    end.
	    
    
do_generalise(Node) ->
    F0 =fun (T, _Others) ->
		case variable_replaceable(T) of
		    true ->
			{refac_syntax:variable('Var'), true};
		    false -> {T, false}
		end
	end,
    element(1, ast_traverse_api:stop_tdTP(F0, Node, [])).
    
	
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                                                                    %%
%%  Hash the AST representation of expressions using MD5, and map     %%
%%  sequence of expression into sequences of indexes.                 %%
%%                                                                    %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

start_hash_process() ->	
    ExpHashTab =from_dets(expr_hash_tab, ?ExpHashTab),
    case file:read_file(?ExpSeqFile) of
	{ok, Binary} ->
	   %% refac_io:format("Data:\n~p\n", [binary_to_term(Binary)]),
	    Data=binary_to_term(Binary);
	_Res ->
	    %%refac_io:format("Res:\n~p\n", [Res]),
	    Data=[{{{'_','_','_','_'},0, {0,0}},'#'}]
	end,
    spawn_link(fun()->hash_loop({1,ExpHashTab,Data}) end).

stop_hash_process(Pid) ->
    Pid!stop.

insert_hash(Pid, {HashVal, Elem={{_M,_F, _A, _Index}, _NumofTok, _StartEndLoc}}) ->
    Pid ! {add, {HashVal, Elem}}.

insert_dummy_entry(Pid) ->
    Pid ! add_dummy.

hash_loop({Index, ExpHashTab, Data}) ->
    receive
      {add, {Key, {{M, F, A, Index1}, NumOfToks,StartEndLoc}}} ->
	  case ets:lookup(ExpHashTab, Key) of
	    [{Key, I}] ->
		hash_loop({Index, ExpHashTab, [{{{M, F, A, Index1}, NumOfToks, StartEndLoc}, I}| Data]});
	      [] -> ets:insert(ExpHashTab, {Key, Index}),
		  hash_loop({Index + 1, ExpHashTab, [{{{M, F, A, Index1}, NumOfToks, StartEndLoc}, Index}| Data]})
	  end;
      add_dummy ->
	  hash_loop({Index, ExpHashTab, [{{{'_', '_', '_', '_'}, 0, {0,0}}, '#'}| Data]});
      {get_clone_candidates, From, Thresholds, Dir} ->
	    Cs = search_for_clones(Dir, lists:reverse(Data), Thresholds),
	    From ! {self(), Cs},
	    hash_loop({Index, ExpHashTab, Data});
	stop ->
	    to_dets(ExpHashTab, ?ExpHashTab),
	    file:write_file(?ExpSeqFile, term_to_binary(lists:reverse(Data))),
	    ok
    end.



%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                                                                    %%
%%  Hash the AST representation of expressions using MD5, and map     %%
%%  sequence of expression into sequences of indexes.                 %%
%%                                                                    %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
start_clone_check_process() ->
    spawn_link(fun()->clone_check_loop([]) end).

stop_clone_check_process(Pid) ->
    Pid ! stop.

add_new_clones(Pid, Clones) ->
    Pid ! {add_clone, Clones}.

get_final_clone_classes(Pid, ASTTab) ->
    Pid ! {get_clones, self(), ASTTab},
    receive
      {Pid, Cs} ->
	  Cs
    end.

clone_check_loop(Cs) ->
    receive
	{add_clone,  Clones} ->
	    clone_check_loop(Clones++Cs);
	{get_clones, From, _ASTTab} ->
	    Cs0=remove_sub_clones(Cs),
	    Cs1=[{AbsRanges, Len, Freq, AntiUnifier}||
		    {_, {Len, Freq}, AntiUnifier,AbsRanges}<-Cs0],
	    From ! {self(), Cs1},
	    clone_check_loop(Cs);       
	stop ->
	    ok;
	_Msg -> 
	    ?wrangler_io("Unexpected message:\n~p\n",[_Msg]),
	    clone_check_loop(Cs)
    end.
 
%%=============================================================================
examine_clone_candidates([], _Thresholds, Tabs,_TmpASTTab, Pid, _Num) ->
    get_final_clone_classes(Pid, Tabs#tabs.ast_tab);
examine_clone_candidates([C| Cs], Thresholds, Tabs, TmpASTTab, Pid, Num) ->
    output_progress_msg(Num),
    case examine_a_clone_candidate(C, Thresholds, Tabs, TmpASTTab) of
	[] ->
	  ok;
	ClonesWithAU ->
	    add_new_clones(Pid, ClonesWithAU)
    end,
    examine_clone_candidates(Cs, Thresholds, Tabs, TmpASTTab,Pid, Num + 1).

examine_a_clone_candidate(_C={Ranges, {_Len, _Freq}}, Thresholds,Tabs, TmpASTTab) ->
    ASTTab=Tabs#tabs.ast_tab,
    Ranges1=lists:append(Ranges),
    lists:foreach(fun({Key,_, _}) ->
			  ets:insert(TmpASTTab, ets:lookup(ASTTab, Key))
		  end, Ranges1),
    Clones=examine_clone_class_members(Ranges, Thresholds,Tabs, TmpASTTab, []),
    ClonesWithAU = [{Rs, {Len, Freq}, get_anti_unifier(TmpASTTab, Info)}
     		    || {Rs, {Len, Freq}, Info} <- Clones],
    ClonesWIthAUInAbsoluteLocs=[get_clone_class_in_absolute_locs(Clone)||Clone<-ClonesWithAU],
    ets:delete_all_objects(TmpASTTab),
    ClonesWIthAUInAbsoluteLocs.
   

examine_clone_class_members(Rs, Thresholds, _, _, Acc) 
  when length(Rs)< Thresholds#threshold.min_freq ->
    remove_sub_clones(Acc);

examine_clone_class_members(Ranges, Thresholds,Tabs, TmpASTTab, Acc) ->
    %%refac_io:format("Ranges:\n~p\n", [Ranges]),
    [Range1|Rs]=Ranges,
    Exprs1 = get_expr_list(Range1, TmpASTTab),
    Res = [begin 
	       Exprs2= get_expr_list(Range2, TmpASTTab),
	       do_anti_unification({Range1, Exprs1}, {Range2, Exprs2})
	   end|| Range2<-Rs,
		 Range2/=Range1],
    InitialLength = length(Range1),
    %% refac_io:format("Freq:\n~p\n", [length(Ranges)]),
    %% refac_io:format("InitaialLength:\n~p\n",[InitialLength]),
    Clones = process_au_result(Res, Thresholds, Tabs, TmpASTTab),
    MaxCloneLength= case Clones ==[] of 
			true -> 0;
			_-> element(1, element(2, hd(Clones)))
		    end,
    %% refac_io:format("MaxCloneLength:\n~p\n", [MaxCloneLength]),
    case MaxCloneLength /= InitialLength of
	true ->
	    examine_clone_class_members(Rs, Thresholds,Tabs, TmpASTTab, Clones ++ Acc);
	false ->
	    Rs1 = element(1, hd(Clones)),
	    RemainedRanges = Ranges -- Rs1,
	    examine_clone_class_members(RemainedRanges, Thresholds,Tabs, TmpASTTab, Clones ++ Acc)

    end.

process_au_result(AURes, Thresholds, Tabs, TmpASTTab) ->
    %% refac_io:format("AURES:\n~p\n", [length(AURes)]),
    Res = [process_one_au_result(OneAURes, Thresholds, Tabs, TmpASTTab)
	   || OneAURes <- AURes],
    %% refac_io:format("RES:\n~p\n",[Res]),
    ClonePairs = lists:append(Res),
    get_clone_classes(ClonePairs, Thresholds, Tabs, TmpASTTab).

process_one_au_result(OneAURes, Thresholds, _Tabs, TmpASTTab) ->
    SubAULists=group_au_result(OneAURes),
    %% refac_io:format("SubAUList:\n~p\n", [length(SubAULists)]),
    ClonePairs =lists:append([get_clone_pairs(SubAUList, Thresholds, TmpASTTab)||SubAUList<-SubAULists]),
    ClonePairs1 =[lists:unzip3(CP)||CP<-ClonePairs],
    remove_sub_clone_pairs(ClonePairs1).

group_au_result([])->
    [];
group_au_result(AURes) ->
    {AUResList1,AUResList2} =
	lists:splitwith(fun({_,_, S}) ->S/=none end, AURes),
    case AUResList2 of
	[] ->
	    [AUResList1];
	[_|T] ->
	    case AUResList1/=[] of
		true ->
		    [AUResList1]++group_au_result(T);
		false ->
		    group_au_result(T)
	    end
    end.

get_clone_pairs(AURes, Thresholds, TmpASTTab) ->
    ClonePairs=get_clone_pairs(AURes, Thresholds, TmpASTTab, {[],[]},[]),
   %% refac_io:format("ClonePairs:\n~p\n", [ClonePairs]),
    ClonePairs.
get_clone_pairs([], Thresholds, TmpASTTab, {_, ClonePairAcc}, Acc) ->
    case length(ClonePairAcc) < Thresholds#threshold.min_len of
	true -> Acc;
	_ -> 
	    ClonePairAcc1 = decompose_clone_pair_by_simi_score(
			      lists:reverse(ClonePairAcc), Thresholds, TmpASTTab),
	    ClonePairAcc1++Acc
    end;  
get_clone_pairs([CurPair={_, _,SubSt}|AURes], Thresholds, TmpASTTab, 
		{VarSubAcc, ClonePairAcc}, Acc) ->
    VarSub = get_var_subst(SubSt),
    case var_sub_conflicts(VarSub,VarSubAcc) of
	true ->
	    case length(ClonePairAcc)>=Thresholds#threshold.min_len of
		true ->
		    ClonePairAcc1 = decompose_clone_pair_by_simi_score(
				      lists:reverse(ClonePairAcc), Thresholds, TmpASTTab),
		    NewAcc = ClonePairAcc1++Acc,			     
		    get_clone_pairs(AURes, Thresholds, TmpASTTab, {[], []},NewAcc);
		false ->
		    get_clone_pairs(AURes, Thresholds, TmpASTTab, {[], []},Acc)
	    end;
	false ->
	    get_clone_pairs(AURes, Thresholds, TmpASTTab, 
			    {VarSub++VarSubAcc, [CurPair]++ClonePairAcc}, Acc)
    end.


decompose_clone_pair_by_simi_score(ClonePair, Thresholds, TmpASTTab) ->
    {Range1, Range2, Subst} = lists:unzip3(ClonePair),
    Exprs1 = get_expr_list(Range1, TmpASTTab),
    Exprs2 = get_expr_list(Range2, TmpASTTab),
    {SubExprs1, SubExprs2} = lists:unzip(lists:append(Subst)),
    Score1 = simi_score(Exprs1, SubExprs1),
    case Score1 >= Thresholds#threshold.simi_score andalso
	   simi_score(Exprs2, SubExprs2) >= Thresholds#threshold.simi_score
	of
      true ->
	  [ClonePair];
      false ->
	  RangeExprPairs1 = lists:zip(Range1, Exprs1),
	  RangeExprPairs2 = lists:zip(Range2, Exprs2),
	  ClonePairsWithExpr = lists:zip3(RangeExprPairs1, RangeExprPairs2, Subst),
	  %% refac_io:format("ClonePairswithExpr:\n~p\n",[ClonePairsWithExpr]),
	  ClonePairWithSimiScore = [{{ExprKey1, Expr1}, {ExprKey2, Expr2}, Sub,
				     simi_score(Expr1, SubEs1), simi_score(Expr2, SubEs2)}
				    || {{ExprKey1, Expr1}, {ExprKey2, Expr2}, Sub} <- ClonePairsWithExpr,
				       {SubEs1, SubEs2} <- [lists:unzip(Sub)]],
	  decompose_clone_pair_by_simi_score_1(ClonePairWithSimiScore, Thresholds, [])
    end.

decompose_clone_pair_by_simi_score_1([], _, Acc)->
    Acc;
decompose_clone_pair_by_simi_score_1(ClonePairWithSimiScore, Thresholds, Acc) ->
    ClonePairs1 = lists:dropwhile(fun({_, _, _, Score1, Score2}) ->
					  Score1 < Thresholds#threshold.simi_score*0.9 orelse
					      Score2 < Thresholds#threshold.simi_score*0.9
				  end, ClonePairWithSimiScore),
    case length(ClonePairs1)>=Thresholds#threshold.min_len of 
	false ->
	   %% refac_io:format("\nDDDDDD\n"),
	    Acc;
	true ->
	    {ClonePairs2, ClonePairs3} =
		lists:splitwith(fun({_, _, _, Score1, Score2}) ->
					 Score1 >= Thresholds#threshold.simi_score*0.9 andalso
					     Score2 >= Thresholds#threshold.simi_score*0.9
				end, ClonePairs1),
	    case length(ClonePairs2)>=Thresholds#threshold.min_len of
		true ->
		    NewClonePairs2=[{ExprKey1, ExprKey2, Sub}||{{ExprKey1,_}, {ExprKey2,_}, Sub, _,_}<-ClonePairs2],
		    case length(ClonePairs3)>=Thresholds#threshold.min_len of
			true ->
			    decompose_clone_pair_by_simi_score_1(ClonePairs3, Thresholds, [NewClonePairs2|Acc]);  
			false ->
			    [NewClonePairs2|Acc]
		    end;
		false ->
		    case length(ClonePairs3)>=Thresholds#threshold.min_len  of
			true ->
			    decompose_clone_pair_by_simi_score_1(ClonePairs3, Thresholds, Acc);
			false ->
			    Acc
		    end
	    end
    end.
	    
    



simi_score(Expr, SubExprs) ->
    case no_of_nodes(Expr) of
      0 -> 0;
      ExprSize ->
	    NonVarExprs = [E || E <- SubExprs, refac_syntax:type(E) =/= variable],
	    NoOfNewVars = length(NonVarExprs),
	    Res = 1 - (no_of_nodes(SubExprs) - length(SubExprs)
		       + NoOfNewVars * (NoOfNewVars + 1) / 2) / ExprSize,
	    %% Res =1 -((no_of_nodes(SubExprs)-length(SubExprs))/ExprSize),
	    Res
    end.
   

var_sub_conflicts(VarSubs, CurVarSubs) ->
    lists:any(fun({DefPos, E})->
			 case lists:keysearch(DefPos, 1, CurVarSubs) of
			     {value, {DefPos, E1}} ->
				 E/=E1;
			     false ->
				 false
			 end
	      end, VarSubs).

get_var_subst(SubSt) ->
    F=fun({E1, E2}) ->
	      {value, {def, DefPos}} = lists:keysearch(def, 1, refac_syntax:get_ann(E1)),
	      {DefPos, refac_prettypr:format(reset_attrs(E2))}
      end,	      
    [F({E1,E2})||{E1,E2}<-SubSt, 
    refac_syntax:type(E1)==variable, not is_macro_name(E1)].

remove_sub_clone_pairs([]) ->[];
remove_sub_clone_pairs(CPs) ->
    SortedCPs = lists:sort(fun({Rs1,_,_}, {Rs2, _, _}) ->
					  length(Rs1)>length(Rs2)
				  end, CPs),
    %% refac_io:format("SoredCPs:\n~p\n",[SortedCPs]),
    remove_sub_clone_pairs(SortedCPs, []).
remove_sub_clone_pairs([], Acc) ->
    lists:reverse(Acc);
remove_sub_clone_pairs([CP={Rs, _,_}|CPs], Acc) ->
    case lists:any(fun({Rs1, _,_}) ->
			   Rs--Rs1==[] 
		   end, Acc) of
	true ->
	    remove_sub_clone_pairs(CPs,Acc);
	_ -> remove_sub_clone_pairs(CPs, [CP|Acc])
    end.
		
get_clone_classes(ClonePairs,Thresholds, Tabs, TmpASTTab) ->
    RangeGroups = lists:usort([Rs || {Rs, _, _} <- ClonePairs]),
    %%refac_io:format("ClonePairs:\n~p\n", [ClonePairs]),
    %% refac_io:format("RangeGroups:\n~p\n", [RangeGroups]),
    CloneClasses = lists:append([get_one_clone_class(Range, ClonePairs, Thresholds, Tabs, TmpASTTab) 
				 || Range <- RangeGroups]),
    %%refac_io:format("CloneClasses:\n~p\n", [CloneClasses]),
    lists:keysort(2, CloneClasses).
 
get_one_clone_class(Range, ClonePairs, Thresholds, Tabs, TmpASTTab) ->
    Res = lists:append([get_one_clone_class_1(Range, ClonePair, Tabs, TmpASTTab)
			|| ClonePair <- ClonePairs]),
    Freq = length(Res) + 1,
    case Freq >= Thresholds#threshold.min_freq of
      true ->
	  Exprs = get_expr_list(Range, TmpASTTab),
	  [{{FName, FunName, Arity, _}, _, _}| _] = Range,
	  VarTab = Tabs#tabs.var_tab,
	  VarsToExport = get_vars_to_export(Exprs, {FName, FunName, Arity}, VarTab),
	  {Ranges, ExportVars, SubSt} = lists:unzip3(Res),
	  ExportVars1 = {element(1, lists:unzip(VarsToExport)), lists:usort(lists:append(ExportVars))},
	  [{[Range| Ranges], {length(Range), length(Ranges) + 1}, {Range, SubSt, ExportVars1}}];
      _ ->
	  []
    end.
get_one_clone_class_1(Range, _ClonePair = {Range1, Range2, Subst}, Tabs, TmpASTTab) ->
    case Range -- Range1 == [] of
      true ->
	    Len = length(Range),
	    R = hd(Range),
	    StartIndex=length(lists:takewhile(fun (R0) -> R0 /= R end, Range1))+1,
	   %% refac_io:format("StartIndex:\n~p\n",[StartIndex]),
	    SubRange2 = lists:sublist(Range2, StartIndex, Len),
	    SubSubst = lists:append(lists:sublist(Subst, StartIndex, Len)),
	    Exprs2 = get_expr_list(SubRange2, TmpASTTab),
	    [{{FName, FunName, Arity, _}, _, _}| _] = SubRange2,
	    VarTab = Tabs#tabs.var_tab,
	    VarsToExport2 = get_vars_to_export(Exprs2, {FName, FunName, Arity}, VarTab),
	    EVs = [E1 || {E1, E2} <- SubSubst, refac_syntax:type(E2) == variable,
			 lists:member({refac_syntax:variable_name(E2), get_var_define_pos(E2)},
				      VarsToExport2)],
	    [{SubRange2, EVs, SubSubst}];
      	false ->
	    []
    end.

					 
    



do_anti_unification({Range1,Exprs1}, {Range2, Exprs2}) ->
   %% refac_io:format("Data:\n~p\n",[{{Range1,Exprs1}, {Range2, Exprs2}}]),
    ZippedExprs1=lists:zip(Range1, Exprs1),
    ZippedExprs2=lists:zip(Range2, Exprs2),
    ZippedExprs=lists:zip(ZippedExprs1, ZippedExprs2),
    [begin
	 {Index1, Index2,
	  do_anti_unification_1(E1,E2)}
     end|| {{Index1,E1}, {Index2, E2}}<-ZippedExprs].
    
do_anti_unification_1(E1, E2) ->
    SubSt=anti_unification:anti_unification(E1,E2),
    case SubSt of 
	none -> none;
	_ -> case subst_sanity_check(E1, SubSt) of
		 true ->
		     SubSt;
		 false ->
		     none
	     end
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                                                                  %%
%%  Remove sub-clones                                               %%
%%                                                                  %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
remove_sub_clones(Cs) ->
    remove_sub_clones(lists:reverse(lists:keysort(2,Cs)),[]).
remove_sub_clones([], Acc_Cs) ->
    lists:reverse(Acc_Cs);
remove_sub_clones([C|Cs], Acc_Cs) ->
    case is_sub_clone(C, Acc_Cs) of
	true -> 
	    remove_sub_clones(Cs, Acc_Cs);
	false ->remove_sub_clones(Cs, [C|Acc_Cs])
    end.

is_sub_clone({Ranges, {Len, Freq},Str,AbsRanges}, ExistingClones) ->
    case ExistingClones of 
	[] -> false;
	[{Ranges1, {_Len1, _Freq1}, _, _AbsRanges1}|T] ->
	    case is_sub_ranges(Ranges, Ranges1) of 
		true -> 
		    true;
		false -> is_sub_clone({Ranges, {Len, Freq},Str, AbsRanges}, T)
	    end
	end;

is_sub_clone({Ranges, {Len, Freq},Str}, ExistingClones) ->
    case ExistingClones of 
	[] -> false;
	[{Ranges1, {_Len1, _Freq1}, _}|T] ->
	    case is_sub_ranges(Ranges, Ranges1) of 
		true -> 
		    true;
		false -> is_sub_clone({Ranges, {Len, Freq},Str}, T)
	    end
    end;
is_sub_clone({Ranges, {Len, Freq}}, ExistingClones) ->
    case ExistingClones of 
	[] -> false;
	[{Ranges1, {_Len1, _Freq1}}|T] ->
	    case is_sub_ranges(Ranges, Ranges1) of 
		true -> 
		    true;
		false -> is_sub_clone({Ranges, {Len, Freq}}, T)
	    end
    end.

is_sub_ranges(Ranges1, Ranges2) ->
    lists:all(fun (R1)  -> 
		      lists:any(fun (R2) ->
					R1--R2==[]
				end, Ranges2) 
	      end, Ranges1).


get_var_define_pos(V) ->
    {value, {def, DefinePos}} = lists:keysearch(def,1, refac_syntax:get_ann(V)),
    DefinePos.


get_anti_unifier(TmpASTTab, {ExprKeys, SubSt, ExportVars}) ->
    Exprs1 = [ExpAST || {ExprKey, _,_} <- ExprKeys, {_Key, ExpAST} <- ets:lookup(TmpASTTab, ExprKey)],
    refac_prettypr:format(anti_unification:generate_anti_unifier(Exprs1, SubSt, ExportVars)).


   
get_clone_member_start_end_loc(Range)->
    {{File, _, _, _}, _Toks, {{StartLine, StartCol},_}} = hd(Range),
    {_ExprKey1, _Toks1,{EndLine, EndCol}}= lists:last(Range),
    {{File, StartLine, StartCol}, {File, EndLine, EndCol}}.
  
get_clone_class_in_absolute_locs({Ranges, {Len, Freq}, AntiUnifier}) ->
     StartEndLocs = [get_clone_member_start_end_loc(R) || R <- Ranges],
    {Ranges, {Len, Freq}, AntiUnifier,StartEndLocs}.

get_expr_list(ExprKeys=[{{_FName, _FunName, _Arity, _Index}, _Toks, _StartEndLoc}|_T], ASTTab)->
    [ExpAST||{ExprKey,_,_}<-ExprKeys, {_Key, ExpAST}<-ets:lookup(ASTTab, ExprKey)].
 

get_vars_to_export(Es, {FName, FunName, Arity}, VarTab) ->
    AllVars = ets:lookup(VarTab, {FName, FunName, Arity}),
    {_, EndLoc} = refac_misc:get_start_end_loc(lists:last(Es)),
      case AllVars of
	  [] -> [];
	  [{_, _, Vars}] ->
	      ExprBdVarsPos = [Pos || {_Var, Pos} <- refac_misc:get_bound_vars(Es)],
	      [{V, DefPos} || {V, SourcePos, DefPos} <- Vars,
			    SourcePos > EndLoc,
			      lists:subtract(DefPos, ExprBdVarsPos) == []]
      end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                                                            %%
%%        Search for cloned candidates                        %%
%%                                                            %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
search_for_clones(Dir, Data, Thresholds) ->
    MinLen = Thresholds#threshold.min_len,
    MinToks= Thresholds#threshold.min_toks,
    MinFreq= Thresholds#threshold.min_freq,
    F0 = fun (I) ->
		 case is_integer(I) of
		     true -> integer_to_list(I) ++ ",";
		     false -> atom_to_list(I)
		 end
	 end,
    F = fun ({Elem={{_M,_F,_A, _Index},_NumOfToks, _StartEndLoc}, I}) ->
		lists:duplicate(length(F0(I)), {I, Elem})
	end,
    IndexStr = lists:append([F0(I) || {_, I} <- Data]),
    SuffixTreeExec = filename:join(?WRANGLER_DIR, "bin/suffixtree"),
    Cs = suffix_tree:get_clones_by_suffix_tree(Dir, IndexStr ++ "&", MinLen, 
					       MinFreq, "0123456789,#&", 1, SuffixTreeExec),
    Cs1 = lists:append([strip_a_clone({[{S, E}| Ranges], {Len, Freq}}, SubStr, MinLen, MinFreq)
			|| {[{S, E}| Ranges], Len, Freq} <- Cs,
			   SubStr <- [lists:sublist(IndexStr, S, E - S + 1)]]),
    Cs2 = refac_code_search_utils:remove_sub_clones([{R, Len, Freq} || {R, {Len, Freq}} <- Cs1]),
    NewData = lists:append([F(Elem) || Elem <- Data]),
    get_clones_in_ranges([{R, {Len, Freq}} || {R, Len, Freq} <- Cs2],
			 NewData, MinLen, MinToks, MinFreq).
   
strip_a_clone({Ranges, {Len, F}}, Str, MinLen, MinFreq) ->
    {Str1, Str2} = lists:splitwith(fun(C) ->C==$# orelse C ==$, end, Str),
    {Str21, Str22} = lists:splitwith(fun(C) ->C==$# orelse C ==$, end, lists:reverse(Str2)),
    case Str22=="" of 
	true -> [];
	_ -> NewRanges = [{S+length(Str1), E-length(Str21)}|| {S, E} <-Ranges],
	     NewLen = Len-length(Str1) -length(Str21),
	     case NewLen >= MinLen*2-1 of
		 true ->
		     split_a_clone({NewRanges,{NewLen, F}},lists:reverse(Str22), MinLen, MinFreq);
		 _ -> []
	     end	    
    end.

split_a_clone(_, "", _, _)->[];
split_a_clone({Ranges, {Len, F}}, Str, MinLen, MinFreq) ->
    {Str1, Str2} = lists:splitwith(fun(C) -> C=/=$# end, Str),
    Len1 = case lists:last(Str1) of 
	       $, ->length(Str1)-1;
	       _ -> length(Str1)
	   end,
    {Str21, Str22} = lists:splitwith(fun(C) -> C==$# end, Str2),
    {NewRanges, RemainedRanges} = lists:unzip([{{S, S+Len1-1}, {S+length(Str1)+length(Str21), E}}
					       ||{S, E} <-Ranges]),
    case Len1 >= MinLen*2-1 of 
	true ->
	    NewRanges1 = remove_overlapped_ranges(NewRanges),
	    NewFreq = length(NewRanges1),
	    case NewFreq>=MinFreq of
		true ->
		    case Str22 of 
			"" ->[{NewRanges1, {Len1, NewFreq}}];
			_ -> [{NewRanges1, {Len1, NewFreq}} | 
			      split_a_clone({RemainedRanges, {Len, F}}, Str22, MinLen,MinFreq)]
		    end;
		false when Str22==""->
		    [];
		false ->
		    split_a_clone({RemainedRanges, {Len, F}}, Str22, MinLen,MinFreq)
	    end;
	false when Str22==""->
	    [];
	false->split_a_clone({RemainedRanges, {Len, F}}, Str22, MinLen,MinFreq)
    end.
  
remove_overlapped_ranges(Rs) ->
    Rs1 = lists:sort(Rs),
    R = hd(Rs1),
    remove_overlapped_ranges(tl(Rs1), R, [R]).
remove_overlapped_ranges([], _, Acc) ->
    lists:reverse(Acc);
remove_overlapped_ranges([{S, E}| Rs], {S1, E1}, Acc) ->
    case S1 =< S andalso S =< E1 of
      true ->
	  remove_overlapped_ranges(Rs, {S1, E1}, Acc);
      false ->
	  remove_overlapped_ranges(Rs, {S, E}, [{S, E}| Acc])
    end.
get_clones_in_ranges(Cs, Data, _MinLen, MinToks, MinFreq) ->
    F0 = fun ({S, E}) ->
		 {_, Ranges} = lists:unzip(lists:sublist(Data, S, E - S + 1)),
		 refac_misc:remove_duplicates(Ranges)
	 end,
    F = fun ({Ranges, {_Len, Freq}}) ->
		case Freq >= MinFreq of
		  true ->
			NewRanges = [F0(R) || R <- Ranges],
			{NewRanges, {length(hd(NewRanges)), Freq}};
		    _ -> []
		end
	end,
    NewCs=[F(C) || C <- Cs],
    NewCs1=remove_short_clones(NewCs, MinToks,MinFreq),
    NewCs1.
  
remove_short_clones(Cs, MinToks, MinFreq) ->
    F= fun({Rs, {Len, _Freq}}) ->
	       Rs1=[R||R<-Rs, {_Ranges, NumToks,_StartEndLocs}<-[lists:unzip3(R)] ,
		       lists:sum(NumToks)>=MinToks],
	       Freq1 = length(Rs1),
	       case Freq1>=MinFreq of
		   true ->
		       [{Rs1, {Len, Freq1}}];
		   false->
		       []
	       end
       end,
    lists:append([F({Rs, {Len, Freq}})||{Rs, {Len, Freq}}<-Cs]).

no_of_tokens(Node) when is_list(Node)->
    Str = refac_prettypr:format(refac_syntax:block_expr(Node)),
    {ok, Toks,_}=refac_scan:string(Str, {1,1}, 8, unix),
    length(Toks)-2;
no_of_tokens(Node) ->
    Str = refac_prettypr:format(Node),
    {ok, Toks,_} =refac_scan:string(Str, {1,1}, 8, unix),
    length(Toks).
subst_sanity_check(Expr1, SubSt) ->
    BVs = refac_misc:get_bound_vars(Expr1),
    F = fun ({E1, E2}) ->
		case refac_syntax:type(E1) of
		  variable ->
		      case is_macro_name(E1) of
			true ->
			    false;  
			_ ->
			    {value, {def, DefPos}} = lists:keysearch(def, 1, refac_syntax:get_ann(E1)),
			    %% local vars should have the same substitute.
			    not lists:any(fun ({E11, E21}) ->
						  refac_syntax:type(E11) == variable andalso
						    {value, {def, DefPos}} == lists:keysearch(def, 1, refac_syntax:get_ann(E11))
						      andalso
						      refac_prettypr:format(reset_attrs(E2))
							=/= refac_prettypr:format(reset_attrs(E21))
					  end, SubSt)
		      end;
		  _ ->
		      %% the expression to be replaced should not contain local variables.
		      BVs -- refac_misc:get_free_vars(E1) == BVs
		end
	end,
    lists:all(F, SubSt).


is_macro_name(Exp) ->
    {value, {category, macro_name}} == 
	lists:keysearch(category, 1, refac_syntax:get_ann(Exp)).
      
reset_attrs(Node) ->
    ast_traverse_api:full_buTP(fun (T, _Others) ->
				       T1 = refac_syntax:set_ann(T, []),
				       refac_syntax:remove_comments(T1)
			       end,
			       Node, {}).

no_of_nodes(Nodes) when is_list(Nodes) ->
    lists:sum([no_of_nodes(N)||N<-Nodes]);
no_of_nodes(Node) ->
    case refac_syntax:is_leaf(Node) of
	true -> 1;
	_ ->
	    lists:sum([no_of_nodes(T)||
			  T<-refac_syntax:subtrees(Node)])
    end.


output_progress_msg(Num) ->
    case Num of 
	1 ->
	    ?wrangler_io("\nChecking the first clone candidate...", []);
	2 ->
	    ?wrangler_io("\nChecking the second clone candidate...", []);
	3 ->
	    ?wrangler_io("\nChecking the third clone candidate...", []);
	_ ->
	    ?wrangler_io("\nChecking the ~pth clone candidate...", [Num])
    end.



from_dets(Ets, Dets) when is_atom(Ets) ->
    EtsRef = ets:new(Ets, [set, public]),
    case dets:open_file(Dets, [{access, read}]) of
      {ok, D} ->
	  true = ets:from_dets(EtsRef, D),
	  ok = dets:close(D),
	  EtsRef;
      {error, _Reason} -> 
	    EtsRef
    end.

to_dets(Ets, Dets) ->
    try file:delete(Dets) 
    catch 
	{error, {file_error, _, enoent}} -> ok;
	{error, Reason} -> throw({error, Reason})
    end,
    MinSize = ets:info(Ets, size),
    Res= dets:open_file(Dets, [{min_no_slots, MinSize}]),
    {ok, DetsRef} = Res,
    ok = dets:from_ets(DetsRef, Ets),
    ok = dets:sync(DetsRef),
    ok = dets:close(DetsRef),
    ets:delete(Ets).
	




%% Some notes:

%% Threshold parameters:
%% MinLen; MinToks; MinFreq; Similairty Score.
%% Data to cache:
%% Dets/ets tables: AST table, Var table, HashVal table;
%% file:  expression seq/index file. list-> to file; 



%% refac_inc_sim_code:inc_sim_code_detection(["c:/cygwin/home/hl/suites/bearer_handling_and_qos/test"],5, 20, 2, 5,0.8,[],8).
%% refac_inc_sim_code:inc_sim_code_detection(["c:/cygwin/home/hl/test/ch2.erl"],3, 0, 2, 5,0.8,[],8).
