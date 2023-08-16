open Ast
open Llvm
open Llvm_analysis
open Llvm_scalar_opts
open Llvm_all_backends

type llvm_info = {
  context          : Llvm.llcontext;
  the_module       : Llvm.llmodule;
  builder          : Llvm.llbuilder;
  i8               : Llvm.lltype;
  i32              : Llvm.lltype;
  i64              : Llvm.lltype;
  c32              : int -> Llvm.llvalue;
  c64              : int -> Llvm.llvalue;
  the_nl           : Llvm.llvalue;
  funcs            : Llvm.llvalue list ref;
  build_in_table   : (string, Llvm.llvalue) Hashtbl.t;
  the_writeInteger : Llvm.llvalue;
  the_writeString  : Llvm.llvalue;
}

let symbol_table : (string, Llvm.llvalue) Hashtbl.t list ref = ref []

let fun_refs    : (Llvm.llvalue, bool list) Hashtbl.t =  Hashtbl.create 10

(*
let build_in_defs =
  let table = Hashtbl.create 10 in
  let declare_fun def =
    let fun_type =
      Llvm.function_type (Llvm.void_type context) [| i32 |] in
    let the_writeInteger =
      Llvm.declare_function "writeInteger" writeInteger_type info.the_module in
  let defs =
    { id = "writeString"; args = { id="str"; atype=ECharacter([-1]); ref=false; pos={line_start=0;line_end=0;char_start=0;char_end=0} }::[]; ret = ENothing; pos={line_start=0;line_end=0;char_start=0;char_end=0} }::
    { id = "writeInteger"; args = { id="i"; atype=EInteger([]); ref=false; pos={line_start=0;line_end=0;char_start=0;char_end=0} }::[]; ret = ENothing; pos={line_start=0;line_end=0;char_start=0;char_end=0} }::
    { id = "readInteger"; args = []; ret = EInteger([]); pos={line_start=0;line_end=0;char_start=0;char_end=0} }::
    { id = "strlen"; args = { id="str"; atype=ECharacter([-1]); ref=false; pos={line_start=0;line_end=0;char_start=0;char_end=0} }::[]; ret = EInteger([]); pos={line_start=0;line_end=0;char_start=0;char_end=0} }::
    []
  in List.iter (fun (def:func_decl) -> Hashtbl.add table def.id (Efuncdef(def, ref false)) ) defs; table



  let writeInteger_type =
    Llvm.function_type (Llvm.void_type context) [| i32 |] in
  let the_writeInteger =
    Llvm.declare_function "writeInteger" writeInteger_type the_module in
*)

(* ------------------------------------------------- *)


let open_scope () =
  symbol_table :=  (Hashtbl.create 10) :: !symbol_table

let close_scope () =
  symbol_table := List.tl !symbol_table

let current_scope () =
  List.hd !symbol_table

let lookup_head info id =
  try Some(Hashtbl.find info.build_in_table id)
  with Not_found ->
    try
      Some (Hashtbl.find (current_scope ()) id)
    with Not_found -> None

let lookup info id =
  let rec walk id st =
    match st with
    | [] -> None
    | cs :: scopes -> try
                        Some (Hashtbl.find cs id)
                      with Not_found -> walk id scopes
  in 
    try Some(Hashtbl.find info.build_in_table id)
    with Not_found -> walk id !symbol_table


(* REMEMBER: check that ids dont confict with fix fun ids eg print *)
let insert id llval =
  if Hashtbl.mem (current_scope ()) id then
    failwith "insert"
  else
    Hashtbl.add (current_scope ()) id llval

let remove_head id =
  Hashtbl.remove (current_scope ()) id



(* ------------------------------------------------- *)



(* the following functions are helpers for handling expressions *)

let codegen_int info i = info.c32 i
let codegen_char info c = Llvm.const_int (Llvm.i8_type info.context) (Char.code c)

let codegen_uop info oper expr =
  match oper with
  | UnopPlus  ->  expr
  | UnopMinus ->  Llvm.build_neg expr "negtmp" info.builder

let codegen_bop info oper expr1 expr2 =
  match oper with
  | BopAdd  ->  Llvm.build_add  expr1 expr2 "addtmp" info.builder
  | BopSub  ->  Llvm.build_sub  expr1 expr2 "subtmp" info.builder
  | BopMul  ->  Llvm.build_mul  expr1 expr2 "multmp" info.builder
  | BopDiv  ->  Llvm.build_sdiv expr1 expr2 "divtmp" info.builder
  | BopMod  ->  Llvm.build_srem expr1 expr2 "modtmp" info.builder


let rec codegen_type info atype =
  match atype with
  | EInteger(lst)   ->  (match lst with
                        | []      ->  info.i32
                        | -1::tl  ->  failwith "codegen_type"
                        | hd::tl  ->  Llvm.array_type (codegen_type info (EInteger(tl))) hd)
  | ECharacter(lst) ->  (match lst with
                        | []      ->  Llvm.i8_type info.context
                        | -1::tl  ->  failwith "codegen_type"
                        | hd::tl  ->  Llvm.array_type (codegen_type info (ECharacter(tl))) hd)
  | EString         ->  failwith "codegen_type"
  | ENothing        ->  Llvm.void_type info.context

let id_get_llvalue info id =
  match lookup info id with
  | Some(llval) ->  llval
  | _           ->  failwith "id_get_llvalue"


let rec codegen_lval info lval =
  match lval with
  | EAssId(id,_)            ->  id_get_llvalue info id
  | EAssString(str,_)       ->  let str_type = Llvm.array_type info.i8 (1 + String.length str) in
                                let the_str = Llvm.declare_global str_type str info.the_module in
                                Llvm.set_linkage Llvm.Linkage.Private the_str;
                                Llvm.set_global_constant true the_str;
                                Llvm.set_initializer (Llvm.const_stringz info.context str) the_str;
                                Llvm.set_alignment 1 the_str;
                                the_str
  | EAssArrEl(lval,expr,_)  ->  Llvm.build_gep (codegen_lval info lval)
                                [| info.c32 0; (codegen_expr info expr) |]
                                "pointer"
                                info.builder

and codegen_lval_load info lval =
  match lval with
  | EAssId(id,_)            ->  let llval = id_get_llvalue info id in
                                Llvm.build_load llval "lval_tmp" info.builder
  | EAssString(str,_)       ->  failwith "codegen_lval_load"
  | EAssArrEl(lval,expr,_)  ->  let llval = Llvm.build_gep (codegen_lval info lval)
                                [| info.c32 0; (codegen_expr info expr) |]
                                "pointer"
                                info.builder in
                                Llvm.build_load llval "lval_tmp" info.builder

and codegen_expr info ast =
  match ast with
  | EInt(i, _)                    ->  codegen_int       info i
  | EChar(c, _)                   ->  codegen_char      info c
  | ELVal(lval, _)                ->  codegen_lval_load info lval
  | EFuncCall(id, params, _)      ->  codegen_call_func info id params
  | EUnOp(op, expr, _)            ->  begin
                                        let e = codegen_expr info expr in
                                        codegen_uop info op e
                                      end
  | EBinOp(op, expr1, expr2, _)   ->  begin 
                                        let e1 = codegen_expr info expr1 
                                        and e2 = codegen_expr info expr2 in 
                                        codegen_bop info op e1 e2 
                                      end


and codegen_call_func info id params =
  let rec walk params ref_lst =
    (let get_llval param ref =
      if (ref == false) then (codegen_expr info param)
      else (match param with
            | ELVal(lval, _)  ->  let llval = codegen_lval info lval in
                                  (match lval with EAssId(_,_) -> llval
                                  | _ -> Llvm.build_gep llval [| info.c32 0; info.c32 0 |] "" info.builder)
            | _               ->  failwith "codegen_call_func") in
    match params, ref_lst with
    | [], []                              ->  []
    | param::rest_params, ref::rest_refs  ->  (get_llval param ref) :: (walk rest_params rest_refs)
    | _, _                                -> failwith "codegen_call_func") in
  let func = id_get_llvalue info id in
  let ref_lst = (try Hashtbl.find fun_refs func
                with Not_found ->  failwith "codegen_call_func") in
  Llvm.build_call func (Array.of_list (walk params ref_lst)) "" info.builder

(* the following functions are helpers for handling statements *)
let codegen_ret info =
  ignore (Llvm.build_ret_void info.builder);
  let ret_bb = append_block info.context "after_ret" (List.hd !(info.funcs)) in
  position_at_end ret_bb info.builder

let codegen_retval info expr =
  ignore (Llvm.build_ret (codegen_expr info expr) info.builder);
  let ret_bb = append_block info.context "after_ret" (List.hd !(info.funcs)) in
  position_at_end ret_bb info.builder

let rec codegen_cond info cond =
  match cond with
  | ELbop(oper, cond1, cond2, _)  ->  begin
                                        let c1 = codegen_cond info cond1
                                        and c2 = codegen_cond info cond2 in
                                        match oper with
                                        | LbopAnd ->  Llvm.build_and c1 c2 "andtemp" info.builder
                                        | LbopOr  ->  Llvm.build_or  c1 c2 "ortemp"  info.builder
                                      end
  | ELuop(oper, cond, _)          ->  begin
                                        let c = codegen_cond info cond in
                                        match oper with
                                        | LuopNot ->  Llvm.build_neg c "negtemp" info.builder
                                      end
  | EComp(oper, expr1, expr2, _)  ->  begin
                                        let e1 = codegen_expr info expr1
                                        and e2 = codegen_expr info expr2 in
                                        match oper with
                                        | CompEq    ->  Llvm.build_icmp Llvm.Icmp.Eq  e1 e2 "if_cond" info.builder
                                        | CompNeq   ->  Llvm.build_icmp Llvm.Icmp.Ne  e1 e2 "if_cond" info.builder
                                        | CompGr    ->  Llvm.build_icmp Llvm.Icmp.Sgt e1 e2 "if_cond" info.builder
                                        | CompLs    ->  Llvm.build_icmp Llvm.Icmp.Slt e1 e2 "if_cond" info.builder
                                        | CompGrEq  ->  Llvm.build_icmp Llvm.Icmp.Sge e1 e2 "if_cond" info.builder
                                        | CompLsEq  ->  Llvm.build_icmp Llvm.Icmp.Sle e1 e2 "if_cond" info.builder
                                      end




let codegen_ass info lval expr =
  let llval = codegen_lval info lval in
  ignore (Llvm.build_store expr llval info.builder)

let rec codegen_stmt info statement =
  match statement with
  | EEmpty(_)                       ->  ((*do nothing*))
  | EBlock(block, _)                ->  codegen_block     info block
  | ECallFunc(id, params, _)        ->  ignore(codegen_call_func info id params)
  | EAss(lval, expr, _)             ->  codegen_ass       info lval (codegen_expr info expr)
  | EIf(cond, stmt, _)              ->  codegen_if        info cond stmt
  | EIfElse(cond, stmt1, stmt2, _)  ->  codegen_ifelse    info cond stmt1 stmt2
  | EWhile(cond, stmt, _)           ->  codegen_while     info cond stmt
  | ERet(_)                         ->  codegen_ret       info
  | ERetVal(expr, _)                ->  codegen_retval    info expr

and codegen_block info block =
  match block with
  | EListStmt(stmt_list, _) -> List.iter (codegen_stmt info) stmt_list


  and codegen_if info cond stmt =
  let c       = codegen_cond info cond in
  let bb      = Llvm.insertion_block info.builder in
  let f       = Llvm.block_parent bb in
  let then_bb = Llvm.append_block info.context "then" f in
  let after_bb = Llvm.append_block info.context "after" f in
  ignore (Llvm.build_cond_br c then_bb after_bb info.builder);
  Llvm.position_at_end then_bb info.builder;
  codegen_stmt info stmt;
  ignore (Llvm.build_br after_bb info.builder);
  Llvm.position_at_end after_bb info.builder

and codegen_ifelse info cond stmt1 stmt2 =
  let c        = codegen_cond info cond in
  let bb       = Llvm.insertion_block info.builder in
  let f        = Llvm.block_parent bb in
  let then_bb  = Llvm.append_block info.context "then" f in
  let else_bb  = Llvm.append_block info.context "else" f in
  let after_bb = Llvm.append_block info.context "after" f in
  ignore (Llvm.build_cond_br c then_bb else_bb info.builder);
  Llvm.position_at_end then_bb info.builder;
  codegen_stmt info stmt1;
  ignore (Llvm.build_br after_bb info.builder);
  Llvm.position_at_end else_bb info.builder;
  codegen_stmt info stmt2;
  ignore (Llvm.build_br after_bb info.builder);
  Llvm.position_at_end after_bb info.builder

and codegen_while info cond stmt =
  let bb      = Llvm.insertion_block info.builder in
  let f       = Llvm.block_parent bb in
  let cond_bb = Llvm.append_block info.context "cond" f in
  let body_bb = Llvm.append_block info.context "body" f in
  let after_bb = Llvm.append_block info.context "after" f in
  ignore (Llvm.build_br cond_bb info.builder);
  Llvm.position_at_end cond_bb info.builder;
  let c = codegen_cond info cond in
  ignore (Llvm.build_cond_br c body_bb after_bb info.builder);
  Llvm.position_at_end body_bb info.builder;
  codegen_stmt info stmt;
  ignore (Llvm.build_br cond_bb info.builder);
  Llvm.position_at_end after_bb info.builder

let rec main_codegen_stmt info statement =
  match statement with
  | EBlock(block, _)                ->  main_codegen_block  info block
  | ERet(_)                         ->  codegen_retval      info (EInt(0, {line_start=0;line_end=0;char_start=0;char_end=0}))
  | _                               ->  codegen_stmt        info statement

and main_codegen_block info block =
  match block with
  | EListStmt(stmt_list, _) -> List.iter (main_codegen_stmt info) stmt_list

(* define main - compile and dump function *)

let codegen_param info param =
  if param.ref then Llvm.pointer_type (codegen_type info param.atype)
  else (codegen_type info param.atype)

let rec insert_params func (args:func_args list) n=
  match args with
  | []      ->  ()
  | hd::tl  ->  insert hd.id (Llvm.param func n); insert_params func tl (n+1)

let rec codegen_localdef info def =
  match def with
  | EFuncDef(func)        ->  let ffunc_type = Llvm.function_type (codegen_type info func.ret) (Array.of_list (List.map (codegen_param info) func.args)) in (* fix array *)
                              let ffunc = Llvm.declare_function func.id ffunc_type info.the_module in
                              let bb = Llvm.append_block info.context "entry" ffunc in
                              insert func.id ffunc;
                              Hashtbl.add fun_refs ffunc (List.map (fun x -> x.ref) func.args);
                              open_scope ();
                              insert_params ffunc func.args 0;
                              insert func.id ffunc;
                              info.funcs := ffunc::!(info.funcs);
                              Llvm.position_at_end bb info.builder;
                              List.iter (fun x -> codegen_localdef info x; Llvm.position_at_end bb info.builder) func.local_defs;
                              codegen_block info func.body;
                              (match func.ret with
                              | ENothing  ->  ignore (Llvm.build_ret_void info.builder)
                              | _         ->  ignore (Llvm.build_ret (info.c32 0) info.builder));
                              info.funcs := List.tl !(info.funcs);
                              close_scope ();
  | EFuncDecl(func_decl)  ->  failwith "codegen_localdef"
  | EVarDef(var)          ->  let ltype = codegen_type info var.atype in
                              let llval = Llvm.build_alloca ltype var.id info.builder in
                              Llvm.set_initializer (Llvm.const_null ltype) llval;
                              insert var.id llval

let rec main_codegen_localdef info def =
match def with
| EFuncDef(func)        ->  codegen_localdef info def
| EFuncDecl(func_decl)  ->  codegen_localdef info def
| EVarDef(var)          ->  let ltype = codegen_type info var.atype in
                            let llval = Llvm.declare_global ltype var.id info.the_module in
                            Llvm.set_linkage Llvm.Linkage.Private llval;
                            Llvm.set_initializer (Llvm.const_null ltype) llval;
                            insert var.id llval

let llvm_compile_and_dump main_func =
  (* Initialize *)
  Llvm_all_backends.initialize ();
  let context = Llvm.global_context () in
  let the_module = Llvm.create_module context "grace program" in
  let builder = Llvm.builder context in
  let pm = Llvm.PassManager.create () in
  List.iter (fun f -> f pm) [
    (*
    Llvm_scalar_opts.add_memory_to_register_promotion;
    Llvm_scalar_opts.add_instruction_combination;
    Llvm_scalar_opts.add_reassociation;
    Llvm_scalar_opts.add_gvn;
    Llvm_scalar_opts.add_cfg_simplification;
    *)
  ];
  (* Initialize types *)
  let i8 = Llvm.i8_type context in
  let i32 = Llvm.i32_type context in
  let i64 = Llvm.i64_type context in
  (* Initialize constant functions *)
  let c32 = Llvm.const_int i32 in
  let c64 = Llvm.const_int i64 in
  (* Initialize global variables *)
  let nl = "\n" in
  let nl_type = Llvm.array_type i8 (1 + String.length nl) in
  let the_nl = Llvm.declare_global nl_type "nl" the_module in
  Llvm.set_linkage Llvm.Linkage.Private the_nl;
  Llvm.set_global_constant true the_nl;
  Llvm.set_initializer (Llvm.const_stringz context nl) the_nl;
  Llvm.set_alignment 1 the_nl;
  (* Create symbol table for build in functions *)
  let build_in_table = Hashtbl.create 10 in
  (* Initialize library functions *)
  let writeInteger_type =
    Llvm.function_type (Llvm.void_type context) [| i32 |] in
  let the_writeInteger =
    Llvm.declare_function "writeInteger" writeInteger_type the_module in
  let writeString_type =
    Llvm.function_type (Llvm.void_type context) [| Llvm.pointer_type i8 |] in
  let the_writeString =
    Llvm.declare_function "writeString" writeString_type the_module in
  let readInteger_type =
    Llvm.function_type i32 [| |] in
  let the_readInteger =
    Llvm.declare_function "readInteger" readInteger_type the_module in
  Hashtbl.add build_in_table "writeInteger" the_writeInteger;
  Hashtbl.add build_in_table "writeString" the_writeString;
  Hashtbl.add build_in_table "readInteger" the_readInteger;
  Hashtbl.add fun_refs the_writeInteger [false];
  Hashtbl.add fun_refs the_writeString [true];
  Hashtbl.add fun_refs the_readInteger [];
  open_scope ();
  (* Define and start and main function *)
  let main_type = Llvm.function_type i32 [| |] in
  let main = Llvm.declare_function "main" main_type the_module in
  let bb = Llvm.append_block context "entry" main in
  (* Emit the program code *)
  let info = {
    context          = context;
    the_module       = the_module;
    builder          = builder;
    i8               = i8;
    i32              = i32;
    i64              = i64;
    c32              = c32;
    c64              = c64;
    the_nl           = the_nl;
    funcs            = ref [main];
    build_in_table   = build_in_table;
    the_writeInteger = the_writeInteger;
    the_writeString  = the_writeString;
  } in
  List.iter (main_codegen_localdef info) main_func.local_defs;
  Llvm.position_at_end bb builder;
  main_codegen_block info main_func.body;
  ignore (Llvm.build_ret (c32 0) builder);
  close_scope ();
  (* Verify *)
  (*Llvm_analysis.assert_valid_module the_module;*)
  (* Optimize *)
  ignore (Llvm.PassManager.run_module the_module pm);
  (* Print out the IR *)
  Llvm.print_module "a.ll" the_module
