(************************************************************************)
(*         *   The Coq Proof Assistant / The Coq Development Team       *)
(*  v      *   INRIA, CNRS and contributors - Copyright 1999-2018       *)
(* <O___,, *       (see CREDITS file for the list of authors)           *)
(*   \VV/  **************************************************************)
(*    //   *    This file is distributed under the terms of the         *)
(*         *     GNU Lesser General Public License Version 2.1          *)
(*         *     (see LICENSE file for the text of the license)         *)
(************************************************************************)

open Pp
open Util
open Names
open Libnames
open Globnames
open Constrexpr
open Constrexpr_ops
open Constr

(** * Numeral notation *)

(** Reduction

    The constr [c] below isn't necessarily well-typed, since we
    built it via an [mkApp] of a conversion function on a term
    that starts with the right constructor but might be partially
    applied.

    At least [c] is known to be evar-free, since it comes from
    our own ad-hoc [constr_of_glob] or from conversions such
    as [coqint_of_rawnum].
*)

let eval_constr env sigma (c : Constr.t) =
  let c = EConstr.of_constr c in
  let sigma,t = Typing.type_of env sigma c in
  let c' = Vnorm.cbv_vm env sigma c t in
  EConstr.Unsafe.to_constr c'

(* For testing with "compute" instead of "vm_compute" :
let eval_constr env sigma (c : Constr.t) =
  let c = EConstr.of_constr c in
  let c' = Tacred.compute env sigma c in
  EConstr.Unsafe.to_constr c'
*)

let eval_constr_app env sigma c1 c2 =
  eval_constr env sigma (mkApp (c1,[| c2 |]))

exception NotANumber

let warn_large_num =
  CWarnings.create ~name:"large-number" ~category:"numbers"
    (fun ty ->
      strbrk "Stack overflow or segmentation fault happens when " ++
      strbrk "working with large numbers in " ++ pr_qualid ty ++
      strbrk " (threshold may vary depending" ++
      strbrk " on your system limits and on the command executed).")

let warn_abstract_large_num =
  CWarnings.create ~name:"abstract-large-number" ~category:"numbers"
    (fun (ty,f) ->
      strbrk "To avoid stack overflow, large numbers in " ++
      pr_qualid ty ++ strbrk " are interpreted as applications of " ++
      Printer.pr_global_env (Termops.vars_of_env (Global.env ())) f ++ strbrk ".")

let warn_abstract_large_num_no_op =
  CWarnings.create ~name:"abstract-large-number-no-op" ~category:"numbers"
    (fun f ->
      strbrk "The 'abstract after' directive has no effect when " ++
      strbrk "the parsing function (" ++
      Printer.pr_global_env (Termops.vars_of_env (Global.env ())) f ++ strbrk ") targets an " ++
      strbrk "option type.")

(** Comparing two raw numbers (base 10, big-endian, non-negative).
    A bit nasty, but not critical: only used to decide when a
    number is considered as large (see warnings above). *)

exception Comp of int

let rec rawnum_compare s s' =
 let l = String.length s and l' = String.length s' in
 if l < l' then - rawnum_compare s' s
 else
   let d = l-l' in
   try
     for i = 0 to d-1 do if s.[i] != '0' then raise (Comp 1) done;
     for i = d to l-1 do
       let c = Pervasives.compare s.[i] s'.[i-d] in
       if c != 0 then raise (Comp c)
     done;
     0
   with Comp c -> c

(***********************************************************************)

(** ** Conversion between Coq [Decimal.int] and internal raw string *)

type int_ty =
  { uint : Names.inductive;
    int : Names.inductive }

(** Decimal.Nil has index 1, then Decimal.D0 has index 2 .. Decimal.D9 is 11 *)

let digit_of_char c =
  assert ('0' <= c && c <= '9');
  Char.code c - Char.code '0' + 2

let char_of_digit n =
  assert (2<=n && n<=11);
  Char.chr (n-2 + Char.code '0')

let coquint_of_rawnum uint str =
  let nil = mkConstruct (uint,1) in
  let rec do_chars s i acc =
    if i < 0 then acc
    else
      let dg = mkConstruct (uint, digit_of_char s.[i]) in
      do_chars s (i-1) (mkApp(dg,[|acc|]))
  in
  do_chars str (String.length str - 1) nil

let coqint_of_rawnum inds (str,sign) =
  let uint = coquint_of_rawnum inds.uint str in
  mkApp (mkConstruct (inds.int, if sign then 1 else 2), [|uint|])

let rawnum_of_coquint c =
  let rec of_uint_loop c buf =
    match Constr.kind c with
    | Construct ((_,1), _) (* Nil *) -> ()
    | App (c, [|a|]) ->
       (match Constr.kind c with
        | Construct ((_,n), _) (* D0 to D9 *) ->
           let () = Buffer.add_char buf (char_of_digit n) in
           of_uint_loop a buf
        | _ -> raise NotANumber)
    | _ -> raise NotANumber
  in
  let buf = Buffer.create 64 in
  let () = of_uint_loop c buf in
  if Int.equal (Buffer.length buf) 0 then
    (* To avoid ambiguities between Nil and (D0 Nil), we choose
       to not display Nil alone as "0" *)
    raise NotANumber
  else Buffer.contents buf

let rawnum_of_coqint c =
  match Constr.kind c with
  | App (c,[|c'|]) ->
     (match Constr.kind c with
      | Construct ((_,1), _) (* Pos *) -> (rawnum_of_coquint c', true)
      | Construct ((_,2), _) (* Neg *) -> (rawnum_of_coquint c', false)
      | _ -> raise NotANumber)
  | _ -> raise NotANumber


(***********************************************************************)

(** ** Conversion between Coq [Z] and internal bigint *)

type z_pos_ty =
  { z_ty : Names.inductive;
    pos_ty : Names.inductive }

(** First, [positive] from/to bigint *)

let rec pos_of_bigint posty n =
  match Bigint.div2_with_rest n with
  | (q, false) ->
      let c = mkConstruct (posty, 2) in (* xO *)
      mkApp (c, [| pos_of_bigint posty q |])
  | (q, true) when not (Bigint.equal q Bigint.zero) ->
      let c = mkConstruct (posty, 1) in (* xI *)
      mkApp (c, [| pos_of_bigint posty q |])
  | (q, true) ->
      mkConstruct (posty, 3) (* xH *)

let rec bigint_of_pos c = match Constr.kind c with
  | Construct ((_, 3), _) -> (* xH *) Bigint.one
  | App (c, [| d |]) ->
      begin match Constr.kind c with
      | Construct ((_, n), _) ->
          begin match n with
          | 1 -> (* xI *) Bigint.add_1 (Bigint.mult_2 (bigint_of_pos d))
          | 2 -> (* xO *) Bigint.mult_2 (bigint_of_pos d)
          | n -> assert false (* no other constructor of type positive *)
          end
      | x -> raise NotANumber
      end
  | x -> raise NotANumber

(** Now, [Z] from/to bigint *)

let z_of_bigint { z_ty; pos_ty } n =
  if Bigint.equal n Bigint.zero then
    mkConstruct (z_ty, 1) (* Z0 *)
  else
    let (s, n) =
      if Bigint.is_pos_or_zero n then (2, n) (* Zpos *)
      else (3, Bigint.neg n) (* Zneg *)
    in
    let c = mkConstruct (z_ty, s) in
    mkApp (c, [| pos_of_bigint pos_ty n |])

let bigint_of_z z = match Constr.kind z with
  | Construct ((_, 1), _) -> (* Z0 *) Bigint.zero
  | App (c, [| d |]) ->
      begin match Constr.kind c with
      | Construct ((_, n), _) ->
          begin match n with
          | 2 -> (* Zpos *) bigint_of_pos d
          | 3 -> (* Zneg *) Bigint.neg (bigint_of_pos d)
          | n -> assert false (* no other constructor of type Z *)
          end
      | _ -> raise NotANumber
      end
  | _ -> raise NotANumber

(** The uninterp function below work at the level of [glob_constr]
    which is too low for us here. So here's a crude conversion back
    to [constr] for the subset that concerns us. *)

let rec constr_of_glob env sigma g = match DAst.get g with
  | Glob_term.GRef (ConstructRef c, _) ->
      let sigma,c = Evd.fresh_constructor_instance env sigma c in
      sigma,mkConstructU c
  | Glob_term.GApp (gc, gcl) ->
      let sigma,c = constr_of_glob env sigma gc in
      let sigma,cl = List.fold_left_map (constr_of_glob env) sigma gcl in
      sigma,mkApp (c, Array.of_list cl)
  | _ ->
      raise NotANumber

let rec glob_of_constr ?loc c = match Constr.kind c with
  | App (c, ca) ->
      let c = glob_of_constr ?loc c in
      let cel = List.map (glob_of_constr ?loc) (Array.to_list ca) in
      DAst.make ?loc (Glob_term.GApp (c, cel))
  | Construct (c, _) -> DAst.make ?loc (Glob_term.GRef (ConstructRef c, None))
  | Const (c, _) -> DAst.make ?loc (Glob_term.GRef (ConstRef c, None))
  | Ind (ind, _) -> DAst.make ?loc (Glob_term.GRef (IndRef ind, None))
  | Var id -> DAst.make ?loc (Glob_term.GRef (VarRef id, None))
  | _ -> let (sigma, env) = Pfedit.get_current_context () in
         CErrors.user_err ?loc
           (strbrk "Unexpected term " ++
              Printer.pr_constr_env env sigma c ++
              strbrk " while parsing a numeral notation.")

let no_such_number ?loc ty =
  CErrors.user_err ?loc
   (str "Cannot interpret this number as a value of type " ++
    pr_qualid ty)

let interp_option ty ?loc c =
  match Constr.kind c with
  | App (_Some, [| _; c |]) -> glob_of_constr ?loc c
  | App (_None, [| _ |]) -> no_such_number ?loc ty
  | x -> let (sigma, env) = Pfedit.get_current_context () in
         CErrors.user_err ?loc
          (strbrk "Unexpected non-option term " ++
             Printer.pr_constr_env env sigma c ++
             strbrk " while parsing a numeral notation.")

let uninterp_option c =
  match Constr.kind c with
  | App (_Some, [| _; x |]) -> x
  | _ -> raise NotANumber

let big2raw n =
  if Bigint.is_pos_or_zero n then (Bigint.to_string n, true)
  else (Bigint.to_string (Bigint.neg n), false)

let raw2big (n,s) =
  if s then Bigint.of_string n else Bigint.neg (Bigint.of_string n)

type target_kind =
  | Int of int_ty (* Coq.Init.Decimal.int + uint *)
  | UInt of Names.inductive (* Coq.Init.Decimal.uint *)
  | Z of z_pos_ty (* Coq.Numbers.BinNums.Z and positive *)

type option_kind = Option | Direct
type conversion_kind = target_kind * option_kind

type numnot_option =
  | Nop
  | Warning of raw_natural_number
  | Abstract of raw_natural_number

type numeral_notation_obj =
  { to_kind : conversion_kind;
    to_ty : GlobRef.t;
    of_kind : conversion_kind;
    of_ty : GlobRef.t;
    num_ty : Libnames.qualid; (* for warnings / error messages *)
    warning : numnot_option }

let interp o ?loc n =
  begin match o.warning with
  | Warning threshold when snd n && rawnum_compare (fst n) threshold >= 0 ->
     warn_large_num o.num_ty
  | _ -> ()
  end;
  let c = match fst o.to_kind with
    | Int int_ty -> coqint_of_rawnum int_ty n
    | UInt uint_ty when snd n -> coquint_of_rawnum uint_ty (fst n)
    | UInt _ (* n <= 0 *) -> no_such_number ?loc o.num_ty
    | Z z_pos_ty -> z_of_bigint z_pos_ty (raw2big n)
  in
  let env = Global.env () in
  let sigma = Evd.from_env env in
  let sigma,to_ty = Evd.fresh_global env sigma o.to_ty in
  let to_ty = EConstr.Unsafe.to_constr to_ty in
  match o.warning, snd o.to_kind with
  | Abstract threshold, Direct when rawnum_compare (fst n) threshold >= 0 ->
     warn_abstract_large_num (o.num_ty,o.to_ty);
     glob_of_constr ?loc (mkApp (to_ty,[|c|]))
  | _ ->
     let res = eval_constr_app env sigma to_ty c in
     match snd o.to_kind with
     | Direct -> glob_of_constr ?loc res
     | Option -> interp_option o.num_ty ?loc res

let uninterp o (Glob_term.AnyGlobConstr n) =
  let env = Global.env () in
  let sigma = Evd.from_env env in
  let sigma,of_ty = Evd.fresh_global env sigma o.of_ty in
  let of_ty = EConstr.Unsafe.to_constr of_ty in
  try
    let sigma,n = constr_of_glob env sigma n in
    let c = eval_constr_app env sigma of_ty n in
    let c = if snd o.of_kind == Direct then c else uninterp_option c in
    match fst o.of_kind with
    | Int _ -> Some (rawnum_of_coqint c)
    | UInt _ -> Some (rawnum_of_coquint c, true)
    | Z _ -> Some (big2raw (bigint_of_z c))
  with
  | Type_errors.TypeError _ | Pretype_errors.PretypeError _ -> None (* cf. eval_constr_app *)
  | NotANumber -> None (* all other functions except big2raw *)

(* Here we only register the interp and uninterp functions
   for a particular Numeral Notation (determined by a unique
   string). The actual activation of the notation will be done
   later (cf. Notation.enable_prim_token_interpretation).
   This registration of interp/uninterp must be added in the
   libstack, otherwise this won't work through a Require. *)

let load_numeral_notation _ (_, (uid,opts)) =
  Notation.register_rawnumeral_interpretation
    ~allow_overwrite:true uid (interp opts, uninterp opts)

let cache_numeral_notation x = load_numeral_notation 1 x

(* TODO: substitution ?
   TODO: uid pas stable par substitution dans opts
 *)

let inNumeralNotation : string * numeral_notation_obj -> Libobject.obj =
  Libobject.declare_object {
    (Libobject.default_object "NUMERAL NOTATION") with
    Libobject.cache_function = cache_numeral_notation;
    Libobject.load_function = load_numeral_notation }

let get_constructors ind =
  let mib,oib = Global.lookup_inductive ind in
  let mc = oib.Declarations.mind_consnames in
  Array.to_list
    (Array.mapi (fun j c -> ConstructRef (ind, j + 1)) mc)

let q_z = qualid_of_string "Coq.Numbers.BinNums.Z"
let q_positive = qualid_of_string "Coq.Numbers.BinNums.positive"
let q_int = qualid_of_string "Coq.Init.Decimal.int"
let q_uint = qualid_of_string "Coq.Init.Decimal.uint"
let q_option = qualid_of_string "Coq.Init.Datatypes.option"

let unsafe_locate_ind q =
  match Nametab.locate q with
  | IndRef i -> i
  | _ -> raise Not_found

let locate_ind q =
  try unsafe_locate_ind q
  with Not_found -> Nametab.error_global_not_found q

let locate_z () =
  try
    Some { z_ty = unsafe_locate_ind q_z;
           pos_ty = unsafe_locate_ind q_positive }
  with Not_found -> None

let locate_int () =
  { uint = locate_ind q_uint;
    int = locate_ind q_int }

let has_type f ty =
  let (sigma, env) = Pfedit.get_current_context () in
  let c = mkCastC (mkRefC f, Glob_term.CastConv ty) in
  try let _ = Constrintern.interp_constr env sigma c in true
  with Pretype_errors.PretypeError _ -> false

let type_error_to f ty loadZ =
  CErrors.user_err
    (pr_qualid f ++ str " should go from Decimal.int to " ++
     pr_qualid ty ++ str " or (option " ++ pr_qualid ty ++ str ")." ++
     fnl () ++ str "Instead of Decimal.int, the types Decimal.uint or Z could be used" ++
     (if loadZ then str " (require BinNums first)." else str "."))

let type_error_of g ty loadZ =
  CErrors.user_err
    (pr_qualid g ++ str " should go from " ++ pr_qualid ty ++
     str " to Decimal.int or (option Decimal.int)." ++ fnl () ++
     str "Instead of Decimal.int, the types Decimal.uint or Z could be used" ++
     (if loadZ then str " (require BinNums first)." else str "."))

let vernac_numeral_notation local ty f g scope opts =
  let int_ty = locate_int () in
  let z_pos_ty = locate_z () in
  let tyc = Smartlocate.global_inductive_with_alias ty in
  let to_ty = Smartlocate.global_with_alias f in
  let of_ty = Smartlocate.global_with_alias g in
  let cty = mkRefC ty in
  let app x y = mkAppC (x,[y]) in
  let cref q = mkRefC q in
  let arrow x y =
    mkProdC ([CAst.make Anonymous],Default Decl_kinds.Explicit, x, y)
  in
  let cZ = cref q_z in
  let cint = cref q_int in
  let cuint = cref q_uint in
  let coption = cref q_option in
  let opt r = app coption r in
  let constructors = get_constructors tyc in
  (* Check the type of f *)
  let to_kind =
    if has_type f (arrow cint cty) then Int int_ty, Direct
    else if has_type f (arrow cint (opt cty)) then Int int_ty, Option
    else if has_type f (arrow cuint cty) then UInt int_ty.uint, Direct
    else if has_type f (arrow cuint (opt cty)) then UInt int_ty.uint, Option
    else
      match z_pos_ty with
      | Some z_pos_ty ->
         if has_type f (arrow cZ cty) then Z z_pos_ty, Direct
         else if has_type f (arrow cZ (opt cty)) then Z z_pos_ty, Option
         else type_error_to f ty false
      | None -> type_error_to f ty true
  in
  (* Check the type of g *)
  let of_kind =
    if has_type g (arrow cty cint) then Int int_ty, Direct
    else if has_type g (arrow cty (opt cint)) then Int int_ty, Option
    else if has_type g (arrow cty cuint) then UInt int_ty.uint, Direct
    else if has_type g (arrow cty (opt cuint)) then UInt int_ty.uint, Option
    else
      match z_pos_ty with
      | Some z_pos_ty ->
         if has_type g (arrow cty cZ) then Z z_pos_ty, Direct
         else if has_type g (arrow cty (opt cZ)) then Z z_pos_ty, Option
         else type_error_of g ty false
      | None -> type_error_of g ty true
  in
  let o = { to_kind; to_ty; of_kind; of_ty;
            num_ty = ty;
            warning = opts }
  in
  (match opts, to_kind with
   | Abstract _, (_, Option) -> warn_abstract_large_num_no_op o.to_ty
   | _ -> ());
  (* TODO: un hash suffit-il ? *)
  let uid = Marshal.to_string o [] in
  let i = Notation.(
       { pt_local = local;
         pt_scope = scope;
         pt_uid = uid;
         pt_required = Nametab.path_of_global (IndRef tyc),[];
         pt_refs = constructors;
         pt_in_match = true })
  in
  Lib.add_anonymous_leaf (inNumeralNotation (uid,o));
  Notation.enable_prim_token_interpretation i
