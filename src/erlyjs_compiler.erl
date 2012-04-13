%%%---------------------------------------------------------------------------------------
%%% @author     Roberto Saccon <rsaccon@gmail.com> [http://rsaccon.com]
%%% @copyright  2007 Roberto Saccon
%%% @doc        Javascript to Erlang compiler
%%% @end
%%%
%%%
%%% The MIT License
%%%
%%% Copyright (c) 2007 Roberto Saccon
%%%
%%% Permission is hereby granted, free of charge, to any person obtaining a copy
%%% of this software and associated documentation files (the "Software"), to deal
%%% in the Software without restriction, including without limitation the rights
%%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%%% copies of the Software, and to permit persons to whom the Software is
%%% furnished to do so, subject to the following conditions:
%%%
%%% The above copyright notice and this permission notice shall be included in
%%% all copies or substantial portions of the Software.
%%%
%%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
%%% THE SOFTWARE.
%%%
%%%---------------------------------------------------------------------------------------
-module(erlyjs_compiler).
-author('rsaccon@gmail.com').

%% API
-export([parse/1, parse_transform/1, compile/2, compile/3]).

-import(erlyjs_global, [get_mod_func/3]).


-record(js_ctx, {
    out_dir = "ebin",
    global = false,
    args = [],
    reader = {file, read_file},
    action = get,
    force_recompile = false,
    module = [],
    verbose = true}).

-record(ast_inf, {              %%  additional info about a parse transfomed AST
    export_asts = [],           %%  Module header export statements
    global_asts = [],           %%  Exported Erlang functions
    internal_func_asts = []}).  %%  Internal Erlang functions

-record(scope, {                %%  represents a Javascript variable scope
    var_dict = dict:new()}).    %%  Key: JsName, Value: {ErlName, Metadata}

-record(trav, {                 %%  traverses the whole tree
    js_scopes = [#scope{}],     %%  for Javascript variables scopes
    names = [],                 %%  for temporary use: [{JsNameAsKey, {ErlName, Metadata}}, ...]
    var_counter = 0,            %%  for unique Erlang variable names
    func_counter = 0}).         %%  for unique internal Erlang function names


compile(File, Module) ->
    compile(File, Module, []).

compile(File, Module, Options) ->
    Ctx = init_js_ctx(File, Module, Options),
    {M, F} = Ctx#js_ctx.reader,
    case catch M:F(File) of
    {ok, Data} ->
        crypto:start(),
        CheckSum = binary_to_list(crypto:sha(Data)),
        case parse(CheckSum, Data, Ctx) of
        ok ->
            ok;
        {ok, JsParseTree} ->
            trace(?MODULE, ?LINE, "JsParseTree", JsParseTree, Ctx),
            try p_t_root(JsParseTree, Ctx, #trav{}) of
                {AstList, Info, _} ->
                    Forms = forms(CheckSum, Module, AstList, Info),
                    trace(?MODULE, ?LINE, "Forms", Forms, Ctx),
                    compile_forms(Forms, Ctx)
            catch
                throw:Error ->
                    Error
            end;
        Error ->
            Error
        end;
    _ ->
        {error, "reading " ++ File ++ " failed "}
    end.


parse(Data) when is_binary(Data) ->
    parse(binary_to_list(Data));
parse(Data) ->
    case erlyjs_scan:string(Data) of
    {ok, Tokens, _} -> erlyjs_parser:parse(Tokens);
    Err -> Err
    end.


parse_transform(JsParseTree) ->
    parse_transform(JsParseTree, #js_ctx{}, #trav{}).


%%====================================================================
%% Internal functions
%%====================================================================

init_js_ctx(_File, Module, Options) ->
    Ctx = #js_ctx{},
    #js_ctx{
        module = list_to_atom(Module),
        out_dir = proplists:get_value(out_dir, Options,  Ctx#js_ctx.out_dir),
        verbose = proplists:get_value(verbose, Options, Ctx#js_ctx.verbose),
        reader = proplists:get_value(reader, Options, Ctx#js_ctx.reader),
        force_recompile = proplists:get_value(force_recompile, Options, Ctx#js_ctx.force_recompile)}.


parse(_, Data, #js_ctx{force_recompile = true}) ->
    parse(Data);
parse(CheckSum, Data, Ctx) ->
    Module = Ctx#js_ctx.module,
    case catch Module:checksum() of
    CheckSum -> ok;
    _ -> parse(Data)
    end.


forms(Checksum, Module, FuncAsts, Info) ->
    FuncAsts2 = lists:append([FuncAsts, Info#ast_inf.internal_func_asts]),

    InitFuncAstBody = case Info#ast_inf.global_asts of
    [] ->
        [erl_syntax:tuple([erl_syntax:atom("error"),
            erl_syntax:atom("no_global_code")])];
    List ->
        lists:reverse([erl_syntax:atom(ok) | List])
    end,
    InitFuncAst = erl_syntax:function(erl_syntax:atom("jsinit"),
        [erl_syntax:clause([], none, InitFuncAstBody)]),

    ResetFuncAstFunBodyCase = erl_syntax:application(erl_syntax:atom(string),
        erl_syntax:atom(str), [erl_syntax:variable("KeyString"), erl_syntax:string("js_")]),
    ResetFuncAstFunBody = [
        erl_syntax:match_expr(
            erl_syntax:tuple([erl_syntax:variable("Key"), erl_syntax:underscore()]),
                erl_syntax:variable("X")),
        erl_syntax:match_expr(erl_syntax:variable("KeyString"),
            erl_syntax:application(none, erl_syntax:atom(atom_to_list),
                [erl_syntax:variable("Key")])),
        erl_syntax:case_expr(ResetFuncAstFunBodyCase, [
            erl_syntax:clause([erl_syntax:integer(1)], none, [
                erl_syntax:application(none, erl_syntax:atom(erase),
                    [erl_syntax:variable("Key")])]),
            erl_syntax:clause([erl_syntax:underscore()], none, [erl_syntax:atom(ok)])])],
    ResetFuncAstBody = [
        erl_syntax:application(erl_syntax:atom(lists), erl_syntax:atom(map), [
            erl_syntax:fun_expr([erl_syntax:clause(
                [erl_syntax:variable("X")], none, ResetFuncAstFunBody)]),
            erl_syntax:application(none, erl_syntax:atom(get), [])]),
        erl_syntax:atom(ok)],
    ResetFuncAst = erl_syntax:function(erl_syntax:atom("jsreset"),
       [erl_syntax:clause([], none, ResetFuncAstBody)]),

    ChecksumFuncAst = erl_syntax:function(erl_syntax:atom("checksum"),
          [erl_syntax:clause([], none, [erl_syntax:string(Checksum)])]),

    ModuleAst = erl_syntax:attribute(erl_syntax:atom(module), [erl_syntax:atom(Module)]),
    ExportInit = erl_syntax:arity_qualifier(erl_syntax:atom("jsinit"), erl_syntax:integer(0)),
    ExportReset = erl_syntax:arity_qualifier(erl_syntax:atom("jsreset"), erl_syntax:integer(0)),
    ExportChecksum = erl_syntax:arity_qualifier(erl_syntax:atom("checksum"), erl_syntax:integer(0)),
    ExportAst = erl_syntax:attribute(erl_syntax:atom(export),
        [erl_syntax:list([ExportInit, ExportReset, ExportChecksum | Info#ast_inf.export_asts])]),
    [erl_syntax:revert(X) || X <- [ModuleAst, ExportAst, InitFuncAst, ResetFuncAst, ChecksumFuncAst | FuncAsts2]].


compile_forms(Forms, Ctx) ->
    CompileOptions = case Ctx#js_ctx.verbose of
    true -> [debug_info, verbose, report_errors, report_warnings];
    _ -> [debug_info]
    end,
    case compile:forms(Forms, CompileOptions) of
    {ok, Module1, Bin} ->
        case Ctx#js_ctx.verbose of
        true ->
            io:format("Erlang source:~n~n"),
            io:put_chars(erl_prettypr:format(erl_syntax:form_list(Forms))),
            io:format("~n");
        _ ->
            ok
        end,
        Path = filename:join([Ctx#js_ctx.out_dir, atom_to_list(Module1) ++ ".beam"]),
        case file:write_file(Path, Bin) of
        ok ->
            code:purge(Module1),
            case code:load_binary(Module1, atom_to_list(Module1) ++ ".erl", Bin) of
            {module, _} -> ok;
            _ -> {error, "code reload failed"}
            end;
        {error, Reason} ->
            {error, lists:concat(["beam generation failed (", Reason, "): ", Path])}
        end;
    error ->
        {error, "compilation failed"}
    end.


p_t_root(JsParseTree, Ctx, Trav) ->
    parse_transform(JsParseTree, Ctx#js_ctx{global = true}, Trav).


p_t(JsParseTree, Ctx, Trav) ->
    parse_transform(JsParseTree, Ctx#js_ctx{global = false}, Trav).


parse_transform(JsParseTree, Ctx, Trav) when is_list(JsParseTree) ->
    {AstInfList, {_, Trav1}} = lists:mapfoldl(fun ast/2, {Ctx, Trav}, JsParseTree),
    {AstList, Inf} = lists:mapfoldl(
        fun({XAst, XInf}, InfAcc) ->
            {XAst, append_info(XInf, InfAcc)}
        end, #ast_inf{}, AstInfList),
    {lists:flatten(AstList), Inf, Trav1};
parse_transform(JsParseTree, Ctx, Trav) ->
    {{Ast, Inf}, {_, Trav1}} = ast(JsParseTree, {Ctx, Trav}),
    {Ast, Inf, Trav1}.


ast({identifier, _, true}, {Ctx, Trav}) ->
    {{erl_syntax:atom(true), #ast_inf{}}, {Ctx, Trav}};
ast({identifier, _, false}, {Ctx, Trav}) ->
    {{erl_syntax:atom(false), #ast_inf{}}, {Ctx, Trav}};
ast({integer, _, Value}, {Ctx, Trav}) ->
    {{erl_syntax:integer(Value), #ast_inf{}}, {Ctx, Trav}};
ast({float, _, Value}, {Ctx, Trav}) ->
    {{erl_syntax:float(Value), #ast_inf{}}, {Ctx, Trav}};
ast({string, _, Value}, {Ctx, Trav}) ->
    {{erl_syntax:string(Value), #ast_inf{}}, {Ctx, Trav}}; %% TODO: binary instead of string
ast({{'[', _L},  Value}, {Ctx, Trav}) ->
    %% TODO: implementation and tests, this just works for empty lists
    {{erl_syntax:list(Value), #ast_inf{}}, {Ctx, Trav}};
ast({{identifier, _, undefined}, _}, {Ctx, Trav}) ->
    {{erl_syntax:atom(undefined), #ast_inf{}}, {Ctx, Trav}};
ast({{identifier, _, 'Infinity'}, _}, {Ctx, Trav}) ->
    {{erl_syntax:atom('Infinity'), #ast_inf{}}, {Ctx, Trav}};
ast({{identifier, _, 'NaN'}, _}, {Ctx, Trav}) ->
    {{erl_syntax:atom('NaN'), #ast_inf{}}, {Ctx, Trav}};
ast({identifier, _, Name}, {Ctx, Trav}) ->
    var_ast(Name, Ctx, Trav);
ast({{{string, _, String}, Names}, {'(', Args}}, {Ctx, Trav}) ->
    call(string, String, Names, Args, Ctx, Trav);
ast({{{identifier, _, Name}, Names}, {'(', Args}}, {Ctx, Trav}) ->
    call(Name, Names, Args, Ctx, Trav);
ast({apply, {identifier, _, Name} , {'(', Args}}, {Ctx, Trav}) ->
    call(Name, [], Args, Ctx, Trav);
ast({apply, Call, {'(', Args}}, {Ctx, Trav}) ->
    {{Ast, Inf}, {Ctx1, Trav1}} = ast(Call, {Ctx#js_ctx{action = get}, Trav}),
    {Args1, _, _} = p_t(Args, Ctx1, Trav1),
    {{erl_syntax:application(none, Ast, [erl_syntax:list(Args1)]), Inf}, {Ctx1, Trav1}};
ast({{identifier, _, Name}, [length]}, {Ctx, Trav}) ->
    {{{_Var, Metadata}, Inf}, _} = var_ast(Name, Ctx#js_ctx{action = get_all}, Trav),
    case Metadata of
    {_, Props} ->
        case proplists:get_value(length, Props) of
        undefined -> {{erl_syntax:atom(undefined), Inf}, {Ctx, Trav}};
        Length -> {{Length, Inf}, {Ctx, Trav}}
        end;
    _ ->
        {{erl_syntax:atom(undefined), Inf}, {Ctx, Trav}}
    end;
ast({{identifier, _, Name}, Value}, {Ctx, Trav}) ->
    var_declare(Name, Value, Ctx, Trav);
ast({var, DeclarationList}, {Ctx, Trav}) ->
    {Ast, Inf, Trav1} = p_t(DeclarationList, Ctx#js_ctx{action = set}, Trav),
    maybe_global({{Ast, Inf}, {Ctx, Trav1}});
ast({return, Expression}, {Ctx, Trav}) ->
    ast(Expression, {Ctx, Trav});
ast({function, {params, Params, body, Body}}, {Ctx, Trav}) ->
    Body1 = case element(1, lists:last(Body)) of
    return -> Body;
    _ -> lists:append(Body, [{return, undefined}])
    end,
    func(Params, Body1, Ctx, Trav);
ast({function, {identifier, _L2, Name}, {params, Params, body, Body}}, {Ctx, Trav}) ->
    Body1 = case element(1, lists:last(Body)) of
    return -> Body;
    _ -> lists:append(Body, [{return, undefined}])
    end,
    func(Name, Params, Body1, Ctx, Trav);
ast({op, {Op, _}, In}, {Ctx, Trav}) ->
    {Out, _, #trav{var_counter = VarCounter}} = p_t(In, Ctx, Trav),
    {{erlyjs_operators:ast(Op, Out), #ast_inf{}}, {Ctx, Trav#trav{var_counter = VarCounter}}};
ast({op, {Op, _}, In1, In2}, {Ctx, Trav}) ->
    {Out1, _, #trav{var_counter = VarCounter1}} = p_t(In1, Ctx, Trav),
    {Out2, _, #trav{var_counter = VarCounter2}} = p_t(In2, Ctx, Trav#trav{var_counter = VarCounter1}),
    {{erlyjs_operators:ast(Op, Out1, Out2), #ast_inf{}}, {Ctx, Trav#trav{var_counter = VarCounter2}}};
ast({op, {Op, postfix, _}, {identifier, _, Name}}, {Ctx, Trav}) ->
    {{In, _}, _} = var_ast(Name, Ctx, Trav),
    {{In1, _}, {_, Trav1}} = var_ast(Name, Ctx#js_ctx{action = set}, Trav),
    case erl_syntax:is_leaf(In) of
    true -> % must be a local variable
        Ast = erl_syntax:match_expr(In1, erlyjs_operators:ast(Op, In)),
        {{erl_syntax:block_expr([Ast, In]), #ast_inf{}}, {Ctx, Trav1}};
    false -> % must be a global variable then
        Ast1 = erl_syntax:match_expr(In1, In),
        KV = [erl_syntax:atom(global_prefix(Name)), erlyjs_operators:ast(Op, In1)],
        Ast2 = erl_syntax:application(none, erl_syntax:atom(put), KV),
        {{erl_syntax:block_expr([Ast1, Ast2, In1]), #ast_inf{}}, {Ctx, Trav1}}
    end;
ast({op, Op, In1, In2, In3}, {Ctx, Trav}) ->
    {Out1, _, #trav{var_counter = VarCounter1}} = p_t(In1, Ctx, Trav),
    {Out2, _, #trav{var_counter = VarCounter2}} = p_t(In2, Ctx, Trav#trav{var_counter = VarCounter1}),
    {Out3, _, #trav{var_counter = VarCounter3}} = p_t(In3, Ctx, Trav#trav{var_counter = VarCounter2}),
    {{erlyjs_operators:ast(Op, Out1, Out2, Out3), #ast_inf{}}, {Ctx, Trav#trav{var_counter = VarCounter3}}};
ast({assign, {'=', _}, {identifier, _, Name}, In1}, {Ctx, Trav}) ->
    {{Out2, _}, {_, Trav1}} = var_ast(Name, Ctx#js_ctx{action = set}, Trav),
    {Out3, Inf, _} = p_t(In1, Ctx, Trav),
    assign_ast('=', Name, Out2, Out3, Inf, Ctx, Trav1);
ast({assign, {Op, _}, {identifier, _, Name}, In1}, {Ctx, Trav}) ->
    {{Out2, _}, _} = var_ast(Name, Ctx, Trav),
    {Out3, Inf, Trav1} = p_t(In1, Ctx, Trav),
    {{Out4, _}, {_, Trav2}} = var_ast(Name, Ctx#js_ctx{action = set}, Trav1),
    assign_ast('=', Name, Out4, erlyjs_operators:ast(assign_to_op(Op), Out2, Out3), Inf, Ctx, Trav2);
ast({'if', Cond, Stmt}, {#js_ctx{global = true} = Ctx, Trav}) ->
    {Cond2, _, #trav{var_counter = VarCounter}} = p_t(Cond, Ctx, Trav),
    Trav2 = Trav#trav{var_counter = VarCounter, names = add_names(Trav)},
    {Stmt2, _, Trav3} = p_t(Stmt, Ctx, Trav2),
    ReturnVarsElse = get_vars_init(Trav, Trav3, Ctx),
    Ast = erl_syntax:case_expr(Cond2, [
        erl_syntax:clause([erl_syntax:atom(true)], none, [Stmt2]),
        erl_syntax:clause([erl_syntax:underscore()], none, [ReturnVarsElse])]),
    {{[], #ast_inf{global_asts = [Ast]}}, {Ctx, trav_clean(Trav3)}};
ast({'if', Cond, Stmt}, {Ctx, Trav}) ->
    {Cond2, _, #trav{var_counter = VarCounter}} = p_t(Cond, Ctx, Trav),
    TravIfIn = Trav#trav{var_counter = VarCounter, names = add_names(Trav)},
    {Stmt2, _, Trav2} = p_t(Stmt, Ctx, TravIfIn),
    NameKeys = get_name_keys(Trav2),
    [ReturnVarsIf] = get_vars_list(NameKeys, [Trav2], Trav, Ctx),
    ReturnVarsElse = get_vars_init(Trav, Trav2, Ctx),
    {Vars, Trav3} =  get_vars_result(NameKeys, Trav2, Trav2, Ctx),
    Ast = erl_syntax:match_expr(Vars, erl_syntax:case_expr(Cond2, [
        erl_syntax:clause([erl_syntax:atom(true)], none, append_asts(Stmt2, ReturnVarsIf)),
        erl_syntax:clause([erl_syntax:underscore()], none, [ReturnVarsElse])])),
     {{Ast, #ast_inf{}}, {Ctx, trav_clean(Trav3)}};
ast({'ifelse', Cond, StmtIf, StmtElse}, {#js_ctx{global = true} = Ctx, Trav}) ->
    {Cond2, _, #trav{var_counter = VarCounter}} = p_t(Cond, Ctx, Trav),
    TravIfIn = Trav#trav{var_counter = VarCounter, names = add_names(Trav)},
    {StmtIf2, _, #trav{var_counter = VarCounter2}} = p_t(StmtIf, Ctx, TravIfIn),
    TravElseIn = Trav#trav{var_counter = VarCounter2, names = add_names(Trav)},
    {StmtElse2, _, Trav3} = p_t(StmtElse, Ctx, TravElseIn),
    Ast = erl_syntax:case_expr(Cond2, [
        erl_syntax:clause([erl_syntax:atom(true)], none, [StmtIf2]),
        erl_syntax:clause([erl_syntax:underscore()], none, [StmtElse2])]),
    {{[], #ast_inf{global_asts = [Ast]}}, {Ctx, trav_clean(Trav3)}};
ast({'ifelse', Cond, StmtIf, StmtElse}, {Ctx, Trav}) ->
    {Cond2, _, #trav{var_counter = VarCounter}} = p_t(Cond, Ctx, Trav),
    TravIfIn = Trav#trav{var_counter = VarCounter, names = add_names(Trav)},
    {StmtIf2, _, #trav{var_counter = VarCounter1} = Trav2} = p_t(StmtIf, Ctx, TravIfIn),
    TravElseIn = Trav#trav{var_counter = VarCounter1, names = add_names(Trav)},
    {StmtElse2, _, Trav3} = p_t(StmtElse, Ctx, TravElseIn),
    NameKeys = get_name_keys(Trav2, Trav3),
    [ReturnVarsIf, ReturnVarsElse] = get_vars_list(NameKeys, [Trav2, Trav3], Trav, Ctx),
    {Vars, Trav4} =  get_vars_result(NameKeys, Trav3, Trav3, Ctx),
    Ast = erl_syntax:match_expr(Vars, erl_syntax:case_expr(Cond2, [
        erl_syntax:clause([erl_syntax:atom(true)], none, append_asts(StmtIf2, ReturnVarsIf)),
        erl_syntax:clause([erl_syntax:underscore()], none, append_asts(StmtElse2, ReturnVarsElse))])),
    {{Ast, #ast_inf{}}, {Ctx, trav_clean(Trav4)}};
ast({do_while, Stmt, Cond}, {#js_ctx{global = true} = Ctx, Trav}) ->
    {OutStmt, _, Trav2} = p_t(Stmt, Ctx, trav_prepare_func(Trav)),
    {OutCond, _, Trav3} = p_t(Cond, Ctx, Trav2),
    AstFuncCond = erl_syntax:case_expr(OutCond, [
        erl_syntax:clause([erl_syntax:atom(true)], none,
            [erl_syntax:application(none, func_name(Trav2), [])]),
        erl_syntax:clause([erl_syntax:underscore()], none,
            [get_global_vars(Trav2)])]),
    Func = erl_syntax:function(func_name(Trav2),
        [erl_syntax:clause([], none, append_asts(OutStmt, AstFuncCond))]),
    Ast = erl_syntax:application(none, func_name(Trav2), []),
    {{[], #ast_inf{internal_func_asts = [Func], global_asts = [Ast]}}, {Ctx, trav_clean(Trav3)}};
ast({do_while, Stmt, Cond}, {Ctx, Trav}) ->
    {OutStmt, _, Trav2} = p_t(Stmt, Ctx, trav_prepare_func(Trav)),
    {OutCond, _, Trav3} = p_t(Cond, Ctx, Trav2),
    VarsBefore = get_vars_init(Trav, Trav2, Ctx),
    VarsAfterStmt = get_vars_snapshot(Trav2),
    {VarsAfter, Trav4} = get_vars_result(Trav2, Trav3, Ctx),
    AstFuncCond = erl_syntax:case_expr(OutCond, [
        erl_syntax:clause([erl_syntax:atom(true)], none,
            [erl_syntax:application(none, func_name(Trav2), [VarsAfterStmt])]),
        erl_syntax:clause([erl_syntax:underscore()], none,
            [VarsAfterStmt])]),
    Func = erl_syntax:function(func_name(Trav2),
        [erl_syntax:clause([VarsBefore], none, append_asts(OutStmt, AstFuncCond))]),
    Ast = erl_syntax:match_expr(VarsAfter,
        erl_syntax:application(none, func_name(Trav2), [VarsBefore])),
    {{[Ast], #ast_inf{internal_func_asts = [Func]}}, {Ctx, trav_clean(Trav4)}};
ast({while, Cond, Stmt}, {#js_ctx{global = true} = Ctx, Trav}) ->
    {OutCond, _, #trav{var_counter = VarCounter}} = p_t(Cond, Ctx, Trav),
    Trav2 = Trav#trav{
        var_counter = VarCounter,
        names = add_names(Trav),
        func_counter = wrap_inc_func_counter(Trav)},
    {OutStmt, _, Trav3} = p_t(Stmt, Ctx, Trav2),
    AstFuncCond = erl_syntax:case_expr(OutCond, [
        erl_syntax:clause([erl_syntax:atom(true)], none,
            append_asts(OutStmt, erl_syntax:application(none, func_name(Trav3), []))),
        erl_syntax:clause([erl_syntax:underscore()], none,
            [get_global_vars(Trav3)])]),
    Func = erl_syntax:function(func_name(Trav3),
        [erl_syntax:clause([], none, [AstFuncCond])]),
    Ast = erl_syntax:application(none, func_name(Trav3), []),
    {{[], #ast_inf{internal_func_asts = [Func], global_asts = [Ast]}}, {Ctx, trav_clean(Trav3)}};
ast({while, Cond, Stmt}, {Ctx, Trav}) ->
    {OutCond, _, #trav{var_counter = VarCounter}} = parse_transform(Cond, Ctx, Trav),
    Trav2 = Trav#trav{
        var_counter = VarCounter,
        names = add_names(Trav),
        func_counter = wrap_inc_func_counter(Trav)},
    {OutStmt, _, Trav3} = p_t(Stmt, Ctx, Trav2),
    VarsBefore = get_vars_init(Trav, Trav3, Ctx),
    VarsAfterStmt = get_vars_snapshot(Trav3),
    {VarsAfter, Trav4} = get_vars_result(Trav3, Trav3, Ctx),
    AstFuncCond = erl_syntax:case_expr(OutCond, [
        erl_syntax:clause([erl_syntax:atom(true)], none,
            append_asts(OutStmt, erl_syntax:application(none, func_name(Trav2), [VarsAfterStmt]))),
        erl_syntax:clause([erl_syntax:underscore()], none,
            [VarsBefore])]),
    Func = erl_syntax:function(func_name(Trav2),
        [erl_syntax:clause([VarsBefore], none, [AstFuncCond])]),
    Ast = erl_syntax:match_expr(VarsAfter,
        erl_syntax:application(none, func_name(Trav3), [VarsBefore])),
    {{[Ast], #ast_inf{internal_func_asts = [Func]}}, {Ctx, trav_clean(Trav4)}};
ast({for, Init, Cond, Final, Stmt}, {#js_ctx{global = true} = Ctx, Trav}) ->
    {OutInit, _, Trav2} = p_t(Init, Ctx, Trav),
    {OutCond, _, Trav3} = p_t(Cond, Ctx, trav_prepare_func(Trav2)),
    {OutStmt, _, Trav4} = p_t(Stmt, Ctx, Trav3),
    {FinalExpr, _, Trav5} = p_t(Final, Ctx, Trav4),
    Stmts = append_asts(OutStmt, FinalExpr), %%% currently only works with full assignment expression as FinalExpr
    AstFuncCond = erl_syntax:case_expr(OutCond, [
        erl_syntax:clause([erl_syntax:atom(true)], none,
            append_asts(Stmts, erl_syntax:application(none, func_name(Trav3), []))),
        erl_syntax:clause([erl_syntax:underscore()], none,
            [get_global_vars(Trav4)])]),
    Func = erl_syntax:function(func_name(Trav4),
        [erl_syntax:clause([], none, [AstFuncCond])]),
    Ast = erl_syntax:application(none, func_name(Trav3), []),
    {{[], #ast_inf{internal_func_asts = [Func], global_asts = append_asts(Ast, OutInit)}}, {Ctx, trav_clean(Trav5)}};
ast({for, Init, Cond, Final, Stmt}, {Ctx, Trav}) ->
    {OutInit, _, Trav2} = p_t(Init, Ctx, Trav),
    {OutCond, _, Trav3} = p_t(Cond, Ctx, trav_prepare_func(Trav2)),
    {OutStmt, _, Trav4} = p_t(Stmt, Ctx, Trav3),
    {FinalExpr, _, Trav5} = p_t(Final, Ctx, Trav4),
    VarsBefore = get_vars_init(Trav2, Trav5, Ctx),
    VarsAfterStmt = get_vars_snapshot(Trav5),
    {VarsAfter, Trav6} = get_vars_result(Trav5, Trav5, Ctx),
    Stmts = append_asts(OutStmt, FinalExpr), %%% currently only works with full assignment expression as FinalExpr
    AstFuncCond = erl_syntax:case_expr(OutCond, [
        erl_syntax:clause([erl_syntax:atom(true)], none,
            append_asts(Stmts, erl_syntax:application(none, func_name(Trav3), [VarsAfterStmt]))),
        erl_syntax:clause([erl_syntax:underscore()], none,
            [VarsBefore])]),
    Func = erl_syntax:function(func_name(Trav3),
        [erl_syntax:clause([VarsBefore], none, [AstFuncCond])]),
    Ast = erl_syntax:match_expr(VarsAfter,
        erl_syntax:application(none, func_name(Trav5), [VarsBefore])),
    {{append_asts(OutInit, Ast), #ast_inf{internal_func_asts = [Func]}}, {Ctx, trav_clean(Trav6)}};
ast({switch, Cond, CaseList, {_, DefaultStmts}}, {#js_ctx{global = true} = Ctx, Trav}) ->
   {Cond2, _, Trav2} = p_t(Cond, Ctx, Trav),
   CaseList2 = CaseList ++ [{default, DefaultStmts}],
   {List, Trav3} =  get_switch_clause_list(CaseList2, trav_prepare(Trav2), Ctx),
   Clauses =  lists:map(
       fun({Label, Guard, Stmts, _, _}) ->
           erl_syntax:clause([Label], Guard, Stmts)
       end, List),
   Ast = erl_syntax:case_expr(Cond2, Clauses),
   {{[], #ast_inf{global_asts = [Ast]}}, {Ctx, trav_clean(Trav3)}};
ast({switch, Cond, CaseList, {_, DefaultStmts}}, {Ctx, Trav}) ->
    {Cond2, _, Trav2} = p_t(Cond, Ctx, Trav),
    CaseList2 = CaseList ++ [{default, DefaultStmts}],
    {List, Trav3} =  get_switch_clause_list(CaseList2, trav_prepare(Trav2), Ctx),
    NameKeys = get_name_keys(List),
    TravList = [ X || {_,_,_,_,X} <- List],
    StmtsReturnVarsList = get_vars_list(NameKeys, TravList, Trav, Ctx),
    {Vars, Trav4} =  get_vars_result(NameKeys, Trav3, Trav3, Ctx),
    Clauses =  lists:map(
        fun({{Label, Guard, Stmts, _, _}, StmtsReturnVars}) ->
            erl_syntax:clause([Label], Guard, append_asts(Stmts, StmtsReturnVars))
        end, lists:zip(List, StmtsReturnVarsList)),
    Ast = erl_syntax:match_expr(Vars, erl_syntax:case_expr(Cond2, Clauses)),
    {{Ast, #ast_inf{}}, {Ctx, trav_clean(Trav4)}};
ast(undefined, {Ctx, Trav}) ->
    {{erl_syntax:atom(undefined), #ast_inf{}}, {Ctx, Trav}};
ast(Unknown, _) ->
    throw({error, lists:concat(["Unknown token: ", Unknown])}).


func_name(Trav) ->
    erl_syntax:atom(lists:concat(["func_", Trav#trav.func_counter])).



var_ast(Key, #js_ctx{action = set} = Ctx, Metadata, Trav) ->
    Scope = hd(Trav#trav.js_scopes),
    {ErlName, Trav2} = build_var_name(Key, Trav),
    Dict = dict:store(Key, {ErlName, Metadata}, Scope#scope.var_dict),
    Names = case Trav2#trav.names of
    [] -> [];
    [H|T] -> [dict:store(Key, {ErlName, Metadata}, H) | T]
    end,
    Trav3 = Trav2#trav{
        js_scopes = [#scope{var_dict = Dict} | tl(Trav#trav.js_scopes)],
        names = Names},
    {{erl_syntax:variable(ErlName), #ast_inf{}}, {Ctx, Trav3}}.

var_ast(Key, #js_ctx{action = set} = Ctx, Trav) ->
    var_ast(Key, #js_ctx{action = set} = Ctx, {}, Trav);
var_ast(undefined, #js_ctx{action = get} = Ctx, Trav) ->
    {{erl_syntax:atom(undefined), #ast_inf{}}, {Ctx, Trav}};
var_ast('Infinity', #js_ctx{action = get} = Ctx, Trav) ->
    {{erl_syntax:atom('Infinity'), #ast_inf{}}, {Ctx, Trav}};
var_ast('NaN', #js_ctx{action = get} = Ctx, Trav) ->
    {{erl_syntax:atom('NaN'), #ast_inf{}}, {Ctx, Trav}};
var_ast(Key, #js_ctx{action = get} = Ctx, Trav) ->
    {{{Ast, _}, Inf}, _} = var_ast(Key, Ctx#js_ctx{action = get_all}, Trav),
    {{Ast, Inf}, {Ctx, Trav}};
var_ast(Key, #js_ctx{action = get_all} = Ctx, Trav) ->
    case name_search(Key, Trav#trav.js_scopes, []) of
    not_found ->
        throw({error, lists:concat(["ReferenceError: ", Key, " is not defined"])});
    {global, {Name, Metadata}} ->
        Args = [erl_syntax:atom(Name)],
        Ast = erl_syntax:application(none, erl_syntax:atom(get), Args),
        {{{Ast, Metadata}, #ast_inf{}}, {Ctx, Trav}};
    {Name, Metadata} ->
        {{{erl_syntax:variable(Name), Metadata}, #ast_inf{}}, {Ctx, Trav}}
    end.

var_declare(Key, [], Ctx, #trav{js_scopes = [GlobalScope]}=Trav) ->
    Dict = dict:store(Key, {global_prefix(Key), []}, GlobalScope#scope.var_dict),
    Args = [erl_syntax:atom(global_prefix(Key)), erl_syntax:atom(undefined)],
    Ast = erl_syntax:application(none, erl_syntax:atom(put), Args),
    Trav2 = Trav#trav{js_scopes=[#scope{var_dict = Dict}]},
    {{Ast,  #ast_inf{}}, {Ctx, Trav2}};
var_declare(Key, {identifier, _, undefined}, Ctx, #trav{js_scopes = [_]}=Trav) ->
    {_, {_, Trav2}}  = var_ast(Key, Ctx, Trav),
    Args = [erl_syntax:atom(global_prefix(Key)), erl_syntax:atom(undefined)],
    Ast = erl_syntax:application(none, erl_syntax:atom(put), Args),
    {{Ast,  #ast_inf{}}, {Ctx, Trav2}};
var_declare(Key, {identifier, _, 'Infinity'}, Ctx,  #trav{js_scopes = [_]}=Trav) ->
    {_, {_, Trav2}}  = var_ast(Key, Ctx, Trav),
    Args = [erl_syntax:atom(global_prefix(Key)), erl_syntax:atom('Infinity')],
    Ast = erl_syntax:application(none, erl_syntax:atom(put), Args),
    {{Ast,  #ast_inf{}}, {Ctx, Trav2}};
var_declare(Key, {identifier, _, 'NaN'}, Ctx,  #trav{js_scopes = [_]}=Trav) ->
    {_, {_, Trav2}}  = var_ast(Key, Ctx, Trav),
    Args = [erl_syntax:atom(global_prefix(Key)), erl_syntax:atom('NaN')],
    Ast = erl_syntax:application(none, erl_syntax:atom(put), Args),
    {{Ast,  #ast_inf{}}, {Ctx, Trav2}};
var_declare(Key, Value, Ctx,  #trav{js_scopes = [GlobalScope]}=Trav) ->
    Dict = dict:store(Key, {global_prefix(Key), []}, GlobalScope#scope.var_dict),
    Trav2 = Trav#trav{js_scopes=[#scope{var_dict = Dict}]},
    {ValueAst, Inf, Trav3} = parse_transform(Value, Ctx, Trav2),
    Args = [erl_syntax:atom(global_prefix(Key)), ValueAst],
    Ast = erl_syntax:application(none, erl_syntax:atom(put), Args),
    {{append_asts(Inf#ast_inf.global_asts, Ast),  #ast_inf{}}, {Ctx, Trav3}};
var_declare(Key, [], Ctx, Trav) ->
    {{AstVariable, _}, {_, Trav2}}  = var_ast(Key, Ctx, Trav),
    Ast = erl_syntax:match_expr(AstVariable, erl_syntax:atom(undefined)),
    {{Ast, #ast_inf{}}, {Ctx, Trav2}};
var_declare(Key, {identifier, _, undefined}, Ctx, Trav) ->
    {{AstVar, Inf}, {_, Trav2}}  = var_ast(Key, Ctx, Trav),
    {{erl_syntax:match_expr(AstVar, erl_syntax:atom(undefined)), Inf}, {Ctx, Trav2}};
var_declare(Key, {identifier, _, 'Infinity'}, Ctx, Trav) ->
    {{AstVar, Inf}, {_, Trav2}}  = var_ast(Key, Ctx, Trav),
    {{erl_syntax:match_expr(AstVar, erl_syntax:atom('Infinity')), Inf}, {Ctx, Trav2}};
var_declare(Key, {identifier, _, 'NaN'}, Ctx, Trav) ->
    {{AstVar, Inf}, {_, Trav2}}  = var_ast(Key, Ctx, Trav),
    {{erl_syntax:match_expr(AstVar, erl_syntax:atom('NaN')), Inf}, {Ctx, Trav2}};
var_declare(Key, Value, Ctx, Trav) ->
    {{AstVariable, _}, {_, Trav2}}  = var_ast(Key, Ctx, Trav),
    {AstValue, Inf, Trav3} = parse_transform(Value, Ctx, Trav2),
    Ast = erl_syntax:match_expr(AstVariable, AstValue),
    {{Ast, Inf}, {Ctx, Trav3}}.


name_search(_, [], _) ->
    not_found;
name_search(Key, [H | T], Trav) ->
    case dict:find(Key, H#scope.var_dict) of
    {ok, {ErlName, Metadata}} ->
        case T of
        [] -> {global, {global_prefix(Key), Metadata}};
        _ -> {ErlName, Metadata}
        end;
    error ->
        name_search(Key, T, [H | Trav])
    end.


get_name_keys(L) when is_list(L) ->
    lists:usort([Key || {Key, _} <- lists:flatten([element(4, X) || X <- L])]);


get_name_keys(Trav) ->
    lists:usort([ Key || {Key, _} <- lists:flatten(
        dict:to_list(hd(Trav#trav.names)))]).

get_name_keys(Trav1, Trav2) ->
    lists:usort([ Key || {Key, _} <- lists:flatten(lists:append([
        dict:to_list(hd(Trav1#trav.names)),
        dict:to_list(hd(Trav2#trav.names))]))]).


get_vars_init(Trav1, Trav2, Ctx) ->
    erl_syntax:tuple(sort_vars(dict:fold(
      fun(Key, _, AccTravIn) ->
          {{Ast, _}, {_, _}} = var_ast(Key, Ctx, Trav1),
          [Ast| AccTravIn]
      end, [], hd(Trav2#trav.names)))).


get_vars_snapshot(Trav) ->
    erl_syntax:tuple(sort_vars(dict:fold(
        fun(_, {Val, _Metadata}, AccTravIn) ->
            [erl_syntax:variable(Val) | AccTravIn]
        end, [], hd(Trav#trav.names)))).


get_vars_list(NameKeys, TravList, Trav, Ctx) ->
    lists:map(
      fun(X) ->
          erl_syntax:tuple(lists:map(
              fun(Key) ->
                  case dict:find(Key, hd(X#trav.names)) of
                  {ok, {Val, _Metadata}} -> erl_syntax:variable(Val);
                  error -> element(1, element(1, var_ast(Key, Ctx, Trav)))
                  end
              end, NameKeys))
      end, TravList).


get_global_vars(Trav) ->
    L = dict:to_list(hd(Trav#trav.names)),
    erl_syntax:tuple([erl_syntax:application(none, erl_syntax:atom(get),
        [erl_syntax:atom(global_prefix(Key))]) || {Key, _} <-  L]).


get_vars_result(Trav, TravSet, Ctx) ->
    get_vars_result(get_name_keys(Trav), Trav, TravSet, Ctx).

get_vars_result(NameKeys, Trav, TravInit, Ctx) ->
    TravInit = Trav#trav{var_counter = TravInit#trav.var_counter},
    {VarsAfter, Trav2} = lists:mapfoldl(
        fun(Key, AccTravIn) ->
            {{Ast, _}, {_, AccTravOut}} = var_ast(Key, Ctx#js_ctx{action = set}, AccTravIn),
            {Ast, AccTravOut}
        end,  TravInit, NameKeys),
    {erl_syntax:tuple(sort_vars(VarsAfter)), Trav2}.


get_switch_clause_list(CaseList, Trav, Ctx) ->
    %% TODO: eliminate possibility of inner shadow variables
    lists:mapfoldl(
        fun
            ({default, StmtsIn}, AccTravIn) ->
                AccTravIn2 = trav_reset(AccTravIn),
                LabelOut = erl_syntax:underscore(),
                {StmtsOut, _, AccTravOut} = p_t(StmtsIn, Ctx, AccTravIn2),
                Names = dict:to_list(hd(AccTravOut#trav.names)),
                {{LabelOut, none, StmtsOut, Names, AccTravOut}, AccTravOut};
            ({[LabelIn], StmtsIn}, AccTravIn) ->
                AccTravIn2 = trav_reset(AccTravIn),
                case lists:last(StmtsIn) of
                {break, _} ->
                    StmtsIn2 = lists:reverse(tl(lists:reverse(StmtsIn))),
                    {LabelOut, _, _} = p_t(LabelIn, Ctx, AccTravIn2),
                    {StmtsOut, _, AccTravOut} = p_t(StmtsIn2, Ctx, AccTravIn2),
                    Names = dict:to_list(hd(AccTravOut#trav.names)),
                    {{LabelOut, none, StmtsOut, Names, AccTravOut}, AccTravOut};
                 _ ->
                     exit(not_implemented_yet)
                end;
            ({LabelsIn, StmtsIn}, AccTravIn) ->
                AccTravIn2 = trav_reset(AccTravIn),
                case lists:last(StmtsIn) of
                {break, _} ->
                    StmtsIn2 = lists:reverse(tl(lists:reverse(StmtsIn))),
                    {LabelsOut, _, _} = p_t(LabelsIn, Ctx, AccTravIn2),
                    Guards = erl_syntax:disjunction(
                        lists:map(
                            fun(Label) ->
                                erl_syntax:infix_expr(
                                    erl_syntax:variable("X"),
                                    erl_syntax:operator('=='), Label)
                            end, LabelsOut)),
                    {StmtsOut, _, AccTravOut} = p_t(StmtsIn2, Ctx, AccTravIn2),
                    Names = dict:to_list(hd(AccTravOut#trav.names)),
                    {{erl_syntax:variable("X"), Guards, StmtsOut, Names, AccTravOut}, AccTravOut};
                 _ ->
                     exit(not_implemented_yet)
                end
        end, Trav, CaseList).


sort_vars(Vars) ->
    lists:sort(
        fun(VarNode0, VarNode1) ->
            Var0 = erl_syntax:variable_literal(VarNode0),
            Var1 = erl_syntax:variable_literal(VarNode1),
            string:substr(Var0, string:chr(Var0, $_) + 1)
                < string:substr(Var1, string:chr(Var1, $_) + 1)
        end, Vars).


func(Params, Body, Ctx, Trav) ->
    {ArgsVar, ArgsAst, Trav1} = arguments_p_t(Params, Ctx, Trav),
    {BodyAst, Inf, _} = p_t(Body, Ctx#js_ctx{action = get}, wrap_add_scope(Trav1)),
    Ast = erl_syntax:fun_expr([erl_syntax:clause([ArgsVar], none, append_asts(ArgsAst, BodyAst))]),
    {{Ast, Inf}, {Ctx, Trav1}}.

func(Name, Params, Body, Ctx, Trav) ->
    case Ctx#js_ctx.global of
    true->
        {ArgsVar, ArgsAst, Trav1} = arguments_p_t(Params, Ctx, Trav),
        {BodyAst, Inf, _} = p_t(Body, Ctx#js_ctx{action = get}, wrap_add_scope(Trav1)),
        Ast = erl_syntax:function(erl_syntax:atom(global_prefix(Name)),
                  [erl_syntax:clause([ArgsVar], none, append_asts(ArgsAst, BodyAst))]),
        Export = erl_syntax:arity_qualifier(
                     erl_syntax:atom(global_prefix(Name)),
                     erl_syntax:integer(1)),
        Exports = [Export | Inf#ast_inf.export_asts],
        {{Ast, Inf#ast_inf{export_asts = Exports}}, {Ctx, Trav1}};
    _ ->
        {{FunVar, _}, {_, Trav1}} = var_ast(Name, Ctx#js_ctx{action = set}, {function, [{length, erl_syntax:integer(length(Params))}]}, Trav),
        {ArgsVar, ArgsAst, Trav2} = arguments_p_t(Params, Ctx, Trav1),
        {BodyAst, Inf, _} = p_t(Body, Ctx#js_ctx{action = get}, wrap_add_scope(Trav2)),
        Ast = erl_syntax:fun_expr([erl_syntax:clause([ArgsVar], none, append_asts(ArgsAst, BodyAst))]),
        {{erl_syntax:match_expr(FunVar, Ast), Inf}, {Ctx, Trav2}}
    end.

arguments_p_t([], Ctx, Trav) ->
    {{Args, _}, {_, Trav1}} = var_ast(arguments, Ctx#js_ctx{action = set}, {arguments, [{length, erl_syntax:integer(0)}]}, Trav),
    {Args, [], Trav1};
arguments_p_t(Params, Ctx, Trav) ->
    {VarName, Trav1} = build_var_name("arguments_length", Trav),
    ArgsLen = erl_syntax:variable(VarName),
    {{Args, _}, {_, Trav2}} = var_ast(arguments, Ctx#js_ctx{action = set}, {arguments, [{length, ArgsLen}]}, Trav1),
    {Params1, _, Trav3} = p_t(Params, Ctx#js_ctx{action = set}, Trav2),
    Clauses = lists:map(
        fun(I) ->
            Guard = erl_syntax:infix_expr(
                        ArgsLen,
                        erl_syntax:operator('>='),
                        erl_syntax:integer(I)),
            ArgVals = lists:map(
                fun(J)  ->
                    case J =< I of
                    true ->
                        erl_syntax:application(
                            erl_syntax:atom(lists),
                            erl_syntax:atom(nth),
                            [erl_syntax:integer(J), Args]);
                    false ->
                        erl_syntax:atom(undefined)
                    end
                end, lists:seq(1, length(Params1))),
            Body = erl_syntax:match_expr(
                       erl_syntax:list(Params1),
                       erl_syntax:list(ArgVals)),
            erl_syntax:clause([ArgsLen], Guard, [Body])
        end, lists:seq(length(Params1), 0, -1)),
    AstList = erl_syntax:case_expr(
                  erl_syntax:application(none, erl_syntax:atom(length), [Args]),
                  Clauses),
    {Args, AstList, Trav3}.


call(string, String, DotSepNames, Args, Ctx, Trav) ->
    Arity = length(Args),
    case get_mod_func(String, DotSepNames, Arity) of
    {Mod, Func, _} ->
        call2(Mod, Func, erl_syntax:string(String), Args, Ctx, Trav);
    _ ->
        throw({error, lists:concat(["No such function: ",
            pprint_name("String", DotSepNames, Arity)])})
    end.

call(Name, DotSepNames, Args, Ctx, Trav) ->
    Arity = length(Args),
    case get_mod_func(Name, DotSepNames, Arity) of
    {Mod, Func} ->
        call2(Mod, Func, Args, Ctx, Trav);
    {Mod, Func, Arg} ->
        {{VarArgs, _}, _} = var_ast(Arg, Ctx#js_ctx{action = get}, Trav),
        call2(Mod, Func, VarArgs, Args, Ctx, Trav);
    _ ->
        {{VarArgs, _}, _} = var_ast(Name, Ctx#js_ctx{action = get}, Trav),
        {Args1, _, Trav1} = p_t(Args, Ctx, Trav),
        Ast = erl_syntax:application(none, VarArgs, [erl_syntax:list(Args1)]),
        maybe_global({{Ast, #ast_inf{}}, {Ctx, Trav1}})
    end.

call2(Mod, Func, Args, Ctx, Trav) ->
    {Args2, _, Trav2} = p_t(Args, Ctx, Trav),
    FuncAst = erl_syntax:application(erl_syntax:atom(Mod), erl_syntax:atom(Func), Args2),
    call3(FuncAst, Ctx, Trav2).

call2(Mod, Func, Arg, Args, Ctx, Trav) ->
    {Args2, _, Trav2} = p_t(Args, Ctx, Trav),
    FuncAst = erl_syntax:application(erl_syntax:atom(Mod), erl_syntax:atom(Func), [Arg | Args2]),
    call3(FuncAst, Ctx, Trav2).

call3(FuncAst, Ctx, Trav) ->
    {VarVal, Trav2} = build_var_name("Val", Trav),
    {VarErr, Trav3} = build_var_name("Err", Trav2),
    ClauseOk = erl_syntax:clause([erl_syntax:variable(VarVal)],
        none, [erl_syntax:variable(VarVal)]),
    ClauseCatch = erl_syntax:clause([erl_syntax:variable(VarErr)], none,
        [erl_syntax:tuple([erl_syntax:atom(error), erl_syntax:variable(VarErr)])]),
    Ast = erl_syntax:try_expr([FuncAst], [ClauseOk], [ClauseCatch]),
    maybe_global({{Ast, #ast_inf{}}, {Ctx, Trav3}}).


assign_ast('=', Name, _, Ast2, _, Ctx, #trav{js_scopes = [_]} = Trav) ->
    %% TODO: dynamic typechecking
    Ast = erl_syntax:application(none, erl_syntax:atom(put), [
        erl_syntax:atom(global_prefix(Name)), Ast2]),
    maybe_global({{Ast, #ast_inf{}}, {Ctx, Trav}});
assign_ast('=', _, Ast1, Ast2, _, Ctx, Trav) ->
    %% TODO: dynamic typechecking
    Ast = erl_syntax:match_expr(Ast1, Ast2),
    maybe_global({{Ast, #ast_inf{}}, {Ctx, Trav}});
assign_ast(Unknown, _, _, _, _, _, _) ->
    throw({error, lists:concat(["Unknown assignment operator: ", Unknown])}).


maybe_global({{Ast, Inf}, {#js_ctx{global = true} = Ctx, Trav}}) ->
    GlobalAsts = append_asts(Inf#ast_inf.global_asts, Ast),
    {{[], Inf#ast_inf{global_asts = GlobalAsts}}, {Ctx, Trav}};
maybe_global({AstInf, CtxTrav}) ->
    {AstInf, CtxTrav}.


append_asts(Ast1, Ast2) when is_list(Ast1), is_list(Ast2) ->
    lists:append(Ast1, Ast2);
append_asts(Ast1, Ast2) when is_list(Ast1) ->
    lists:append(Ast1, [Ast2]);
append_asts(Ast1, Ast2) when is_list(Ast2) ->
    lists:append([Ast1], Ast2);
append_asts(Ast1, Ast2) ->
    [Ast1, Ast2].


append_info(Info1, Info2) ->
    #ast_inf{
        export_asts = lists:append(Info1#ast_inf.export_asts, Info2#ast_inf.export_asts),
        global_asts = lists:append(Info1#ast_inf.global_asts, Info2#ast_inf.global_asts),
        internal_func_asts = lists:append(
            Info1#ast_inf.internal_func_asts, Info2#ast_inf.internal_func_asts)}.


assign_to_op(Assign) ->
    list_to_atom(tl(lists:reverse(string:strip(atom_to_list(Assign), both, $')))).


global_prefix(Name) ->
    lists:concat(["js_", Name]).


build_var_name(Key, Trav) ->
   ErlName = lists:concat(["V", Trav#trav.var_counter, "_", Key]),
   {ErlName, Trav#trav{var_counter = Trav#trav.var_counter + 1}}.


%% TODO: eliminate
add_names(Trav) -> [dict:new() | Trav#trav.names].

trav_prepare(Trav) -> Trav#trav{names = [dict:new() | Trav#trav.names]}.

trav_prepare_func(Trav) ->
    Trav#trav{
        names = [dict:new() | Trav#trav.names],
        func_counter = Trav#trav.func_counter + 1}.

trav_clean(Trav) -> Trav#trav{names = tl(Trav#trav.names)}.

trav_reset(Trav) -> Trav#trav{names = [dict:new() | tl(Trav#trav.names)]}.

%% TODO: eliminate
wrap_inc_func_counter(Trav) -> Trav#trav.func_counter + 1.

wrap_add_scope(Trav) -> Trav#trav{js_scopes = [#scope{} | Trav#trav.js_scopes]}.


pprint_name(Name, [], Arity)  ->
    lists:concat([Name, "/", Arity]);
pprint_name(_, DotSepNames, Arity)  ->
    lists:concat([string:join([atom_to_list(X) || X <- DotSepNames], "."),"/", Arity]).


trace(Module, Line, Title, Content, Ctx) ->
    case Ctx#js_ctx.verbose of
    true -> io:format("TRACE ~p:~p ~p: ~p~n",[Module, Line, Title, Content]);
    _ -> ok
    end.
