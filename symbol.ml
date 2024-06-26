open Printf
open Error
open Read
open Ast


(* ------------------------------------------------- *)


type entry =
  (*                        used           *)
  | Efundecl of func_decl * bool ref
  | Efuncdef of func_decl * bool ref
  (*              used       initialized *)
  | Evar of var * bool ref * bool ref


(* ------------------------------------------------- *)


let built_in_table =
  let table =
    Hashtbl.create 10
  in List.iter (fun (def:func_decl) -> Hashtbl.add table def.id (Efuncdef(def, ref false)) ) built_in_defs; table


let symbol_table : (string, entry) Hashtbl.t list ref = ref []


(* ------------------------------------------------- *)


let open_scope () =
  symbol_table :=  (Hashtbl.create 10) :: !symbol_table

let close_scope () = symbol_table := 
  List.tl !symbol_table

let current_scope () =
  List.hd !symbol_table

let lookup_head id =
  try
    Some (Hashtbl.find (current_scope ()) id)
  with Not_found -> 
    try Some(Hashtbl.find built_in_table id)
  with Not_found -> None
    

let lookup id =
  let rec walk id st n =
    match st with
    | [] -> raise Not_found
    | cs :: []     -> (try
                        Some (Hashtbl.find cs id, -1)
                      with Not_found -> raise Not_found)
    | cs :: scopes -> (try
                        Some (Hashtbl.find cs id, n)
                      with Not_found -> walk id scopes (n+1))
  in 
    try walk id !symbol_table 0
    with Not_found -> try Some(Hashtbl.find built_in_table id, -1) with Not_found -> None


(* REMEMBER: check that ids dont confict with fix fun ids eg print *)
let insert id info =
  if Hashtbl.mem (current_scope ()) id then
    failwith "insert"
  else
    Hashtbl.add (current_scope ()) id info

let remove_head id =
  Hashtbl.remove (current_scope ()) id
