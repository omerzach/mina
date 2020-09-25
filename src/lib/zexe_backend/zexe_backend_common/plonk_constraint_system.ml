open Sponge
open Unsigned.Size_t
include Scale_round
include Endoscale_round

module Gate = struct
  type g =
    | Zero
    | Generic
    | Poseidon
    | EC_add1
    | EC_add2
    | EC_vbmul1
    | EC_vbmul2
    | EC_vbmul3
    | EC_emul1
    | EC_emul2
    | EC_emul3
    | EC_emul4
end

module type Gate_vector_intf = sig
  open Unsigned
  open Gate
  type field_vector
  type t

  val create : unit -> t
  val add_gate : 
    t ->
    int ->
    size_t ->
    size_t ->
    int ->
    size_t ->
    int ->
    size_t ->
    int ->
    field_vector ->
    unit
  val wrap_gate : 
    t ->
    size_t ->
    int ->
    size_t ->
    int ->
    unit
end

module Hash_state = struct
  open Core_kernel
  module H = Digestif.SHA256

  type t = H.ctx

  let digest t = Md5.digest_string H.(to_raw_string (get t))
end

module Plonk_constraint = struct
  open Core_kernel

  module T = struct
    type ('v, 'f) t =
      | Basic of { l : 'f * 'v; r : 'f * 'v; o : 'f * 'v; m: 'f; c: 'f }
      | Poseidon of { start: 'v array; state: ('v array) array }
      | EC_add of { p1 : 'v * 'v; p2 : 'v * 'v; p3 : 'v * 'v  }
      | EC_scale of { state: ('v Scale_round.t) array  }
      | EC_endoscale of { state: ('v Endoscale_round.t) array  }
    [@@deriving sexp]

    let map (type a b f) (t : (a, f) t) ~(f : a -> b) =
      let fp (x, y) = f x, f y in
      match t with
      | Basic { l ; r; o; m; c } ->
        let p (x, y) = (x, f y) in
        Basic { l= p l; r= p r; o= p o; m; c }

      | Poseidon { start; state } ->
        Poseidon { start=Array.map ~f start; state= Array.map ~f:(fun (x) -> Array.map ~f x) state }

      | EC_add { p1; p2; p3 } ->
        EC_add { p1= fp p1; p2= fp p2; p3= fp p3 }

      | EC_scale { state } ->
        EC_scale { state= Array.map ~f:(fun (x) -> Scale_round.map ~f x) state }

      | EC_endoscale { state } ->
        EC_endoscale { state= Array.map ~f:(fun (x) -> Endoscale_round.map ~f x) state }

    let eval (type v f)
        (module F : Snarky_backendless.Field_intf.S with type t = f)
        (eval_one : v -> f)
        (t : (v, f) t) =
      match t with
      (* cl * vl + cr * vr + co * vo + m * vl*vr + c = 0 *)
      | Basic { l=(cl, vl); r=(cr, vr) ; o = (co, vo); m; c } ->
        let vl = eval_one vl in
        let vr = eval_one vr in
        let vo = eval_one vo in
        F.(equal zero (List.reduce_exn ~f:add [ mul cl vl; mul cr vl; mul co vo; mul m (mul vl vr); c ]))
      | _ -> failwith "TODO"
  end
  include T
  include Snarky_backendless.Constraint.Add_kind(T)
end 

module Position = struct
  type t = { row: int; col: int }
end

module Internal_var = Core_kernel.Unique_id.Int()

module V = struct
  open Core_kernel

  module T = struct
    type t =
      | External of int
      | Internal of Internal_var.t
    [@@deriving compare, hash, sexp]
  end
  include T
  include Comparable.Make(T)
  include Hashable.Make(T)
  (*let create_internal () = Internal (Internal_var.create ())*)
end

type ('a, 'f) t =
  { equivalence_classes: Position.t list V.Table.t
  ; internal_vars : (('f * V.t) list * 'f option) Internal_var.Table.t
  ; mutable rows_rev : V.t option array list
  ; mutable gates: 'a
  ; mutable next_row: int
  ; mutable hash: Hash_state.t
  ; mutable constraints: int
  ; mutable public_input_size: int
  ; mutable auxiliary_input_size: int }

module Hash = Core.Md5
let digest (t : _ t) = Hash_state.digest t.hash

module Make (Fp : sig
    include Field_plonk.S
    val to_bigint_raw_noalloc : t -> Bigint.t
  end)
    (Gates : Gate_vector_intf with type field_vector := Fp.Vector.t)
    (Params : sig val params : Fp.t Params.t end)
    =
struct
  open Core
  open Pickles_types
  
  type nonrec t = (Gates.t, Fp.t) t

(*
   An external variable is one generated by snarky (via exists).
   An internal variable is one that we generate as an intermediate variable (e.g., in
   reducing linear combinations to single PLONK positions).
   Every internal variable is computable from a finite list of
   external variables and internal variables. 
   Currently, in fact, every internal variable is a linear combination of
   external variables and previously generated internal variables.
*)

  let compute_witness sys (external_values : int -> Fp.t) : Fp.t array array =
    let internal_values : Fp.t Internal_var.Table.t = Internal_var.Table.create () in
    let res = Array.init sys.next_row ~f:(fun _ -> Array.create ~len:3 Fp.zero) in
    let compute ((lc, c) : ((Fp.t * V.t) list * Fp.t option)) =
      List.fold lc ~init:(Option.value c ~default:Fp.zero)
        ~f:(fun acc (s, x) ->
            let x =
              match x with
              | External x -> external_values x
              | Internal x -> Hashtbl.find_exn internal_values x
            in
            Fp.(acc + s * x))
    in
    List.iteri (List.rev sys.rows_rev) ~f:(fun i row ->
        Array.iteri row ~f:(fun j v ->
          match v with
          | None -> ()
          | Some (External v) ->
            res.(i).(j) <- external_values v
          | Some (Internal v) ->
            let lc = Hashtbl.find_exn sys.internal_vars v in
            let value = compute lc in
            res.(i).(j) <- value ;
            Hashtbl.set internal_values ~key:v ~data:value ) ) ;
    res

  let create_internal ?constant sys lc : V.t =
    let v = Internal_var.create () in
    Hashtbl.add_exn sys.internal_vars ~key:v ~data:(lc, constant);
    V.Internal v

  let digest t = Hash_state.digest t.hash

  module Hash_state = struct
    include Hash_state

    let empty = H.feed_string H.empty "plonk_constraint_system"
end

let create () =
    { public_input_size= 0
    ; internal_vars= Internal_var.Table.create ()
    ; gates= Gates.create()
    ; rows_rev= []
    ; next_row= 0
    ; equivalence_classes= V.Table.create ()
    ; hash= Hash_state.empty
    ; constraints= 0
    ; auxiliary_input_size= 0 }

  (* TODO *)
  let to_json _ = `List []

  let get_auxiliary_input_size t = t.auxiliary_input_size

  let get_primary_input_size t = t.public_input_size

  let set_auxiliary_input_size t x = t.auxiliary_input_size <- x

  let set_primary_input_size t x = t.public_input_size <- x

  let digest = digest

  let finalize = ignore
  let canonicalize x =
    let c, terms =
      Fp.(
        Snarky_backendless.Cvar.to_constant_and_terms ~add ~mul ~zero:(of_int 0) ~equal
          ~one:(of_int 1))
        x
    in
    let terms =
      List.sort terms ~compare:(fun (_, i) (_, j) -> Int.compare i j)
    in
    let has_constant_term = Option.is_some c in
    let terms = match c with None -> terms | Some c -> (c, 0) :: terms in
    match terms with
    | [] ->
      Some ([], 0, false)
    | (c0, i0) :: terms ->
      let acc, i, ts, n =
        Sequence.of_list terms
        |> Sequence.fold ~init:(c0, i0, [], 0)
          ~f:(fun (acc, i, ts, n) (c, j) ->
              if Int.equal i j then (Fp.add acc c, i, ts, n)
              else (c, j, (acc, i) :: ts, n + 1) )
      in
      Some (List.rev ((acc, i) :: ts), n + 1, has_constant_term)

  open Position
  let add_row sys row t l r o c =
(*
    print_endline (Sexp.to_string ([%sexp_of: V.t option array] row));
    Printf.printf "row: %d\n" sys.next_row; 
    Printf.printf "l.row: %d, l.col: %d\n" l.row l.col; 
    Printf.printf "r.row: %d, r.col: %d\n" r.row r.col; 
    Printf.printf "o.row: %d, o.col: %d\n" o.row o.col; 
    Out_channel.flush stdout;
*)
    Gates.add_gate sys.gates t (of_int sys.next_row)
      (of_int l.row) l.col
      (of_int r.row) r.col
      (of_int o.row) o.col
    (*
      (of_int sys.next_row) 0
      (of_int sys.next_row) 1
      (of_int sys.next_row) 2
    *)
      (c);
    sys.next_row <- sys.next_row + 1 ;
    sys.rows_rev <- row :: sys.rows_rev

  let wire sys key row col =
    let prev = match V.Table.find sys.equivalence_classes key with
      | Some x -> List.hd_exn x
      | None -> {row= row; col}
    in
    V.Table.add_multi sys.equivalence_classes ~key ~data:{ row; col } ;
    prev

  let add_generic_constraint ?l ?r ?o c sys : unit =

    let lp = match l with
      | Some (_, lx) -> wire sys lx sys.next_row 0
      | None -> {row= sys.next_row; col= 0} in
    let rp = match r with
      | Some (_, rx) -> wire sys rx sys.next_row 1
      | None -> {row= sys.next_row; col= 1} in
    let op = match o with
      | Some (_, ox) -> wire sys ox sys.next_row 2
      | None -> {row= sys.next_row; col= 2} in
    add_row sys [| Option.map l ~f:snd; Option.map r ~f:snd; Option.map o ~f:snd |] 1 lp rp op c 

  let completely_reduce sys (terms : (Fp.t * int) list) = (* just adding constrained variables without values *)
    let rec go = function
      | [] -> assert false
      | [ (s, x) ] -> (s, V.External x)
      | (ls, lx) :: t ->
        let lx = V.External lx in
        let (rs, rx) = go t in
        let s1x1_plus_s2x2 = create_internal sys [ (ls, lx) ; (rs, rx) ] in
        add_generic_constraint ~l:(ls, lx) ~r:(rs, rx) ~o:(Fp.one, s1x1_plus_s2x2)
          (Fp.Vector.of_array [|ls; rs; Fp.(negate one); Fp.zero; Fp.zero|]) sys ;
        (Fp.one, s1x1_plus_s2x2)
    in
    go terms

  let reduce_lincom sys (x : Fp.t Snarky_backendless.Cvar.t)  =
    let constant, terms =
      Fp.(
        Snarky_backendless.Cvar.to_constant_and_terms ~add ~mul ~zero:(of_int 0) ~equal
          ~one:(of_int 1))
        x
    in
    let terms =
      List.sort terms ~compare:(fun (_, i) (_, j) -> Int.compare i j)
    in
    match constant, terms with
    | Some c, [] -> (c, `Constant)
    | None, [] -> (Fp.zero, `Constant)
    | _, (c0, i0) :: terms ->
      let terms =
        let acc, i, ts, _ =
          Sequence.of_list terms
          |> Sequence.fold ~init:(c0, i0, [], 0)
            ~f:(fun (acc, i, ts, n) (c, j) ->
                if Int.equal i j then (Fp.add acc c, i, ts, n)
                else (c, j, (acc, i) :: ts, n + 1) )
        in
        List.rev ((acc, i) :: ts)
      in
      match terms with
      | [] -> assert false


      | [(ls, lx)] -> 
        begin match constant with
          | None -> (ls, `Var (V.External lx))
          | Some c ->
            (* res = ls * lx + c *)
            let res = create_internal ~constant:c sys [ (ls, External lx) ] in
            add_generic_constraint ~l:(ls, External lx) ~o:(Fp.one, res)
              (Fp.Vector.of_array [|ls; Fp.zero; Fp.(negate one); Fp.zero; match constant with | Some x -> x | None -> Fp.zero |]) sys ;
            (Fp.one, `Var res)
        end 

      | (ls, lx) :: tl ->
        let (rs, rx) = completely_reduce sys tl in
        let res = create_internal sys [ (ls, External lx); (rs, rx) ] in
        (* res = ls * lx + rs * rx *)
        add_generic_constraint ~l:(ls, External lx) ~r:(rs, rx) ~o:(Fp.one, res)
          (Fp.Vector.of_array [|ls; rs; Fp.(negate one); Fp.zero; match constant with | Some x -> x | None -> Fp.zero |]) sys ;
        (Fp.one, `Var res)
  ;;

  let add_constraint ?label:_ sys (constr : (Fp.t Snarky_backendless.Cvar.t, Fp.t) Snarky_backendless.Constraint.basic) =

    (*print_endline (Sexp.to_string ([%sexp_of: (Fp.t Snarky_backendless.Cvar.t, Fp.t) Snarky_backendless.Constraint.basic] constr));*)

    let red = reduce_lincom sys in
    let reduce_to_v (x : Fp.t Snarky_backendless.Cvar.t) : V.t =
      let (s, x) = red x in
      match x with
      | `Var x ->
        if Fp.equal s Fp.one then x
        else let sx = create_internal sys [ (s, x) ] in
          add_generic_constraint ~l:(s, x) ~o:(Fp.one, sx)
            (Fp.Vector.of_array [|Fp.one; Fp.zero; Fp.(negate one); Fp.zero; Fp.zero|]) sys ;
          x
      | `Constant ->
        let x = create_internal sys ~constant:s [] in
        add_generic_constraint ~l:(Fp.one, x)
          (Fp.Vector.of_array [|Fp.one; Fp.zero; Fp.zero; Fp.zero; Fp.negate s|]) sys ;
        x
    in
    match constr with

    | Snarky_backendless.Constraint.Square (v1, v2) ->
      let (sl, xl), (so, xo) = red v1, red v2 in
      ( 
        match xl, xo with
        | `Var xl, `Var xo -> add_generic_constraint ~l:(sl, xl) ~r:(sl, xl) ~o:(so, xo)
            (Fp.Vector.of_array [|Fp.zero; Fp.zero; Fp.negate so; Fp.(sl * sl); Fp.zero|]) sys
        | `Var xl, `Constant -> add_generic_constraint ~l:(sl, xl) ~r:(sl, xl)
            (Fp.Vector.of_array [|Fp.zero; Fp.zero; Fp.zero; Fp.(sl * sl); Fp.negate so|]) sys
        | `Constant, `Var xl -> add_generic_constraint ~l:(sl, xl)
            (Fp.Vector.of_array [|sl; Fp.zero; Fp.zero; Fp.zero; Fp.negate (Fp.square so)|]) sys
        | `Constant, `Constant -> assert Fp.(equal (square sl) so)
      )

    | Snarky_backendless.Constraint.R1CS (v1, v2, v3) ->
      let (s1, x1), (s2, x2), (s3, x3) = red v1, red v2, red v3 in
      ( 
        match x1, x2, x3 with
        | `Var x1, `Var x2, `Var x3 -> add_generic_constraint ~l:(s1, x1) ~r:(s2, x2) ~o:(s3, x3)
          (Fp.Vector.of_array [|Fp.zero; Fp.zero; s3; Fp.(negate s1 * s2); Fp.zero|]) sys
        | `Var x1, `Var x2, `Constant -> add_generic_constraint ~l:(s1, x1) ~r:(s2, x2)
          (Fp.Vector.of_array [|Fp.zero; Fp.zero; Fp.zero; Fp.(s1 * s2); Fp.negate s3|]) sys
        | `Var x1, `Constant, `Var x3 -> add_generic_constraint ~l:(s1, x1) ~o:(s3, x3)
          (Fp.Vector.of_array [|Fp.(s1 * s2); Fp.zero; Fp.negate s3; Fp.zero; Fp.zero|]) sys
        | `Constant, `Var x2, `Var x3 -> add_generic_constraint ~r:(s2, x2) ~o:(s3, x3)
          (Fp.Vector.of_array [|Fp.zero; Fp.(s1 * s2); Fp.negate s3; Fp.zero; Fp.zero|]) sys          
        | `Var x1, `Constant, `Constant -> add_generic_constraint ~l:(s1, x1)
          (Fp.Vector.of_array [|Fp.(s1 * s2); Fp.zero; Fp.zero; Fp.zero; Fp.negate s3|]) sys
        | `Constant, `Var x2, `Constant -> add_generic_constraint ~r:(s2, x2)
          (Fp.Vector.of_array [|Fp.zero; Fp.(s1 * s2); Fp.zero; Fp.zero; Fp.negate s3|]) sys
        | `Constant, `Constant, `Var x3 -> add_generic_constraint ~o:(s3, x3)
          (Fp.Vector.of_array [|Fp.zero; Fp.zero; s3; Fp.zero; Fp.(negate s1 * s2)|]) sys
        | `Constant, `Constant, `Constant -> assert Fp.(equal s3 Fp.(s1 * s2))
      )

    | Snarky_backendless.Constraint.Boolean v ->
      let (s, x) = red v in
      ( 
        match x with
        | `Var x -> add_generic_constraint~l:(s, x) ~r:(s, x)
          (Fp.Vector.of_array [|Fp.(negate one); Fp.zero; Fp.zero; Fp.one; Fp.zero|]) sys
        | `Constant -> assert Fp.(equal s (s * s))
      )

    | Snarky_backendless.Constraint.Equal (v1, v2) ->
      let (s1, x1), (s2, x2) = red v1, red v2 in
      ( 
        match x1, x2 with
        | `Var x1, `Var x2 ->
          if s1 <> s2 then add_generic_constraint ~l:(s1, x1) ~r:(s2, x2)
            (Fp.Vector.of_array [|s1; Fp.(negate s2); Fp.zero; Fp.zero; Fp.zero|]) sys
          (* TODO: optimize by not adding generic costraint but rather permuting the vars *)
          else add_generic_constraint ~l:(s1, x1) ~r:(s2, x2)
            (Fp.Vector.of_array [|s1; Fp.(negate s2); Fp.zero; Fp.zero; Fp.zero|]) sys
        | `Var x1, `Constant -> add_generic_constraint ~l:(s1, x1)
          (Fp.Vector.of_array [|s1; Fp.zero; Fp.zero; Fp.zero; Fp.negate s2|]) sys
        | `Constant, `Var x2 -> add_generic_constraint ~r:(s2, x2)
          (Fp.Vector.of_array [|Fp.zero; s2; Fp.zero; Fp.zero; Fp.negate s1|]) sys
        | `Constant, `Constant -> assert Fp.(equal s1 s2)
      )

    | Plonk_constraint.T (Poseidon { start; state }) ->

      let reduce_state sys (s : Fp.t Snarky_backendless.Cvar.t array array) : V.t array array =
        Array.map ~f:(Array.map ~f:reduce_to_v) s
      in

      let start = (reduce_state sys [|start|]).(0) in
      let state = reduce_state sys state in

      let add_round_state array ind =
        let prev = Array.mapi array ~f:(fun i x -> (wire sys x sys.next_row i)) in
        add_row sys (Array.map array ~f:(fun x -> Some x))
          2 prev.(0) prev.(1) prev.(2) (Fp.Vector.of_array Params.params.round_constants.(ind));
      in
      add_round_state start 0;
      Array.iteri ~f:(fun i state ->  add_round_state state i) state;
      ()

    | Plonk_constraint.T (EC_add { p1; p2; p3 }) ->
      let red = Array.map [| p1; p2; p3 |] ~f:(fun (x, y) -> (reduce_to_v x, reduce_to_v y)) in
      let prev = Array.mapi ~f:(fun i (x, y) -> (wire sys x sys.next_row i, wire sys y sys.next_row i)) red
      in
      add_row sys (Array.map red ~f:(fun (_, y) -> Some y)) 3
        {row=(fst prev.(0)).row; col=(snd prev.(0)).col}
        {row=(fst prev.(1)).row; col=(snd prev.(1)).col}
        {row=(fst prev.(2)).row; col=(snd prev.(2)).col}
        (Fp.Vector.create());
      add_row sys (Array.map red ~f:(fun (x, _) -> Some x)) 4
        {row=(snd prev.(0)).row; col=(fst prev.(0)).col}
        {row=(snd prev.(1)).row; col=(fst prev.(1)).col}
        {row=(snd prev.(2)).row; col=(fst prev.(2)).col}
        (Fp.Vector.create());
      ()

    | Plonk_constraint.T (EC_scale { state }) ->
      let add_ecscale_round (round: V.t Scale_round.t) =
        let xt = wire sys round.xt sys.next_row 0 in
        let b = wire sys round.b sys.next_row 1 in
        let yt = wire sys round.yt sys.next_row 2 in
        let xp = wire sys round.xp (sys.next_row + 1) 0 in
        let l1 = wire sys round.l1 (sys.next_row + 1) 1 in
        let yp = wire sys round.yp (sys.next_row + 1) 2 in
        let xs = wire sys round.xs (sys.next_row + 2) 0 in
        let ys = wire sys round.ys (sys.next_row + 2) 2 in

        add_row sys [| Some round.xt; Some round.b; Some round.yt |]
          5 xt b yt (Fp.Vector.create());
        add_row sys [| Some round.xp; Some round.l1; Some round.yp |]
          6 xp l1 yp (Fp.Vector.create());
        add_row sys [| Some round.xs; Some round.xt; Some round.ys |]
          7 xs xt ys (Fp.Vector.create());
      in
      Array.iter ~f:(fun round -> add_ecscale_round round) (Array.map state ~f:(Scale_round.map ~f:reduce_to_v));
      ()

    | Plonk_constraint.T (EC_endoscale { state }) ->
      let add_endoscale_round (round: V.t Endoscale_round.t) =
        let b2i1 = wire sys round.b2i1 sys.next_row 0 in
        let xt = wire sys round.xt sys.next_row 1 in
        let b2i = wire sys round.b2i (sys.next_row + 1) 0 in
        let xq = wire sys round.xq (sys.next_row + 1) 1 in
        let yt = wire sys round.yt (sys.next_row + 1) 2 in
        let xp = wire sys round.xp (sys.next_row + 2) 0 in
        let l1 = wire sys round.l1 (sys.next_row + 2) 1 in
        let yp = wire sys round.yp (sys.next_row + 2) 2 in
        let xs = wire sys round.xs (sys.next_row + 3) 0 in
        let ys = wire sys round.xs (sys.next_row + 3) 1 in

        add_row sys [| Some round.b2i1; Some round.xt; None |]
          8 b2i1 xt {row=sys.next_row; col=3} (Fp.Vector.create());
        add_row sys [| Some round.b2i; Some round.xq; Some round.yt |]
          9 b2i xq yt (Fp.Vector.create());
        add_row sys [| Some round.xp; Some round.l1; Some round.yp |]
          10 xp l1 yp (Fp.Vector.create());
        add_row sys [| Some round.xs; Some round.xq; Some round.ys |]
          11 xs xq ys (Fp.Vector.create());
      in
      Array.iter ~f:(fun round -> add_endoscale_round round) (Array.map state ~f:(Endoscale_round.map ~f:reduce_to_v));
      ()

    | constr ->
      failwithf "Unhandled constraint %s"
        Obj.(extension_name (extension_constructor constr))
        ()
end