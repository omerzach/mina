[%%import
"/src/config.mlh"]

open Core_kernel

[%%ifdef
consensus_mechanism]

open Snark_params.Tick
open Signature_lib
module Coda_numbers = Coda_numbers

[%%else]

open Signature_lib_nonconsensus
module Coda_numbers = Coda_numbers_nonconsensus.Coda_numbers
module Currency = Currency_nonconsensus.Currency
module Random_oracle = Random_oracle_nonconsensus.Random_oracle

[%%endif]

module Impl = Pickles.Impls.Step
open Coda_numbers
open Currency
open Pickles_types
module Digest = Random_oracle.Digest
module Predicate = Snapp_predicate

let typ_optional typ ~default =
  Typ.transport typ
    ~there:(fun x -> Option.value x ~default:(Lazy.force default))
    ~back:Option.return

(* TODO: One invariant that needs to be checked is

   If the fee payer is `Other { pk; _ }, this account should in fact
   be distinct from the other accounts.  *)

(*
module Per_account = struct
  module Poly = struct
    [%%versioned
    module Stable = struct
      module V1 = struct
        type ('field, 'pk) t =
          {state: 'field Snapp_state.Stable.V1.t; delegate: 'pk}
        [@@deriving compare, eq, sexp, hash, yojson, hlist]
      end
    end]
  end

  type ('field, 'pk) t_ = {state: 'field Snapp_state.t; delegate: 'pk}

  [%%versioned
  module Stable = struct
    module V1 = struct
      type t =
        ( F.Stable.V1.t Set_or_keep.Stable.V1.t
        , Public_key.Compressed.Stable.V1.t Set_or_keep.Stable.V1.t )
        Poly.Stable.V1.t
      [@@deriving compare, eq, sexp, hash, yojson]

      let to_latest = Fn.id
    end
  end]

  let to_input ({state; delegate} : t) =
    let open Random_oracle_input in
    List.reduce_exn ~f:append
      ( List.map (Vector.to_list state)
          ~f:(Set_or_keep.to_input ~dummy:F.zero ~f:field)
      @ [ Set_or_keep.to_input
            ~dummy:(Lazy.force invalid_public_key)
            ~f:Public_key.Compressed.to_input delegate ] )

  module Checked = struct
    type t =
      ( Field.Var.t Set_or_keep.Checked.t
      , Public_key.Compressed.var Set_or_keep.Checked.t )
      Poly.Stable.Latest.t

    let to_input ({state; delegate} : t) =
      let open Random_oracle_input in
      List.reduce_exn ~f:append
        ( List.map (Vector.to_list state)
            ~f:(Set_or_keep.Checked.to_input ~f:field)
        @ [ Set_or_keep.Checked.to_input
              ~f:Public_key.Compressed.Checked.to_input delegate ] )
  end

  let dummy : t  =
    { state= Vector.init Snapp_state.Max_state_size.n
          ~f:(fun _ -> Set_or_keep.Keep)
    ; delegate= Keep
    }

  let typ () : (Checked.t, t) Typ.t =
    let open Poly.Stable.Latest in
    Typ.of_hlistable
      [ Snapp_state.typ (Set_or_keep.Checked.typ ~dummy:Field.zero Field.typ)
      ; Set_or_keep.typ
          ~dummy:(Lazy.force invalid_public_key)
          Public_key.Compressed.typ ]
      ~var_to_hlist:to_hlist ~var_of_hlist:of_hlist ~value_to_hlist:to_hlist
      ~value_of_hlist:of_hlist
end

*)

(*
module Fee_payment = struct
  [%%versioned
  module Stable = struct
    module V1 = struct
      type 'a t = {fee: Fee.Stable.V1.t; payer: 'a}
      [@@deriving sexp, eq, yojson, hash, compare]
    end
  end]
end *)

module Party = struct
  module Update = struct
    module Poly = struct
      [%%versioned
      module Stable = struct
        module V1 = struct
          type ('state_element, 'pk, 'vk, 'perms) t =
            { app_state: 'state_element Snapp_state.Stable.V1.t
            ; delegate: 'pk
            ; verification_key: 'vk
            ; permissions: 'perms }
          [@@deriving compare, eq, sexp, hash, yojson, hlist]
        end
      end]
    end

    open Snapp_basic

    [%%versioned
    module Stable = struct
      module V1 = struct
        type t =
          ( F.Stable.V1.t Set_or_keep.Stable.V1.t
          , Public_key.Compressed.Stable.V1.t Set_or_keep.Stable.V1.t
          , ( Pickles.Side_loaded.Verification_key.Stable.V1.t
            , F.Stable.V1.t )
            With_hash.Stable.V1.t
            Set_or_keep.Stable.V1.t
          , Permissions.Stable.V1.t Set_or_keep.Stable.V1.t )
          Poly.Stable.V1.t
        [@@deriving compare, eq, sexp, hash, yojson]

        let to_latest = Fn.id
      end
    end]

    module Checked = struct
      open Pickles.Impls.Step

      type t =
        ( Field.t Set_or_keep.Checked.t
        , Public_key.Compressed.var Set_or_keep.Checked.t
        , Field.t Set_or_keep.Checked.t
        , Permissions.Checked.t Set_or_keep.Checked.t )
        Poly.t

      let to_input ({app_state; delegate; verification_key; permissions} : t) =
        let open Random_oracle_input in
        List.reduce_exn ~f:append
          [ Snapp_state.to_input app_state
              ~f:(Set_or_keep.Checked.to_input ~f:field)
          ; Set_or_keep.Checked.to_input delegate
              ~f:Public_key.Compressed.Checked.to_input
          ; Set_or_keep.Checked.to_input
              verification_key
              ~f:field
          ; Set_or_keep.Checked.to_input 
              permissions 
              ~f:Permissions.Checked.to_input ]
    end

    let dummy : t =
      { app_state=
          Vector.init Snapp_state.Max_state_size.n ~f:(fun _ ->
              Set_or_keep.Keep )
      ; delegate= Keep
      ; verification_key= Keep
      ; permissions= Keep }

    let to_input ({app_state; delegate; verification_key; permissions} : t) =
      let open Random_oracle_input in
      List.reduce_exn ~f:append
        [ Snapp_state.to_input app_state
            ~f:(Set_or_keep.to_input ~dummy:Field.zero ~f:field)
        ; Set_or_keep.to_input delegate
            ~dummy:(Predicate.Eq_data.Tc.public_key ()).default
            ~f:Public_key.Compressed.to_input
        ; Set_or_keep.to_input
            (Set_or_keep.map verification_key ~f:With_hash.hash)
            ~dummy:Field.zero ~f:field
        ; Set_or_keep.to_input permissions ~dummy:Permissions.user_default
            ~f:Permissions.to_input ]

    let typ () : (Checked.t, t) Typ.t =
      let open Poly in
      let open Pickles.Impls.Step in
      Typ.of_hlistable
        [ Snapp_state.typ (Set_or_keep.typ ~dummy:Field.Constant.zero Field.typ)
        ; Set_or_keep.typ ~dummy:Public_key.Compressed.empty
            Public_key.Compressed.typ
        ; Set_or_keep.typ ~dummy:Field.Constant.zero Field.typ
          |> Typ.transport
               ~there:(Set_or_keep.map ~f:With_hash.hash)
               ~back:(Set_or_keep.map ~f:(fun _ -> failwith "vk typ"))
        ; Set_or_keep.typ ~dummy:Permissions.user_default Permissions.typ ]
        ~var_to_hlist:to_hlist ~var_of_hlist:of_hlist ~value_to_hlist:to_hlist
        ~value_of_hlist:of_hlist
  end

  module Body = struct
    module Poly = struct
      [%%versioned
      module Stable = struct
        module V1 = struct
          type ('pk, 'update, 'signed_amount) t =
            {pk: 'pk; update: 'update; delta: 'signed_amount}
          [@@deriving hlist, sexp, eq, yojson, hash, compare]
        end
      end]
    end

    [%%versioned
    module Stable = struct
      module V1 = struct
        type t =
          ( Public_key.Compressed.Stable.V1.t
          , Update.Stable.V1.t
          , (Amount.Stable.V1.t, Sgn.Stable.V1.t) Signed_poly.Stable.V1.t )
          Poly.Stable.V1.t
        [@@deriving sexp, eq, yojson, hash, compare]

        let to_latest = Fn.id
      end
    end]

    module Checked = struct
      type t =
        (Public_key.Compressed.var, Update.Checked.t, Amount.Signed.var) Poly.t

      let to_input ({pk; update; delta} : t) =
        List.reduce_exn ~f:Random_oracle_input.append
          [ Public_key.Compressed.Checked.to_input pk
          ; Update.Checked.to_input update
          ; Amount.Signed.Checked.to_input delta ]

      let digest (t : t) =
        Random_oracle.Checked.(
          hash ~init:Hash_prefix.snapp_body (pack_input (to_input t)))
    end

    let typ () : (Checked.t, t) Typ.t =
      let open Poly in
      Typ.of_hlistable
        [Public_key.Compressed.typ; Update.typ (); Amount.Signed.typ]
        ~var_to_hlist:to_hlist ~var_of_hlist:of_hlist ~value_to_hlist:to_hlist
        ~value_of_hlist:of_hlist

    let dummy : t =
      { pk= Public_key.Compressed.empty
      ; update= Update.dummy
      ; delta= Amount.Signed.zero }

    let to_input ({pk; update; delta} : t) =
      List.reduce_exn ~f:Random_oracle_input.append
        [ Public_key.Compressed.to_input pk
        ; Update.to_input update
        ; Amount.Signed.to_input delta ]

    let digest (t : t) =
      Random_oracle.(
        hash ~init:Hash_prefix.snapp_body (pack_input (to_input t)))

    module Digested = struct
      type t = Random_oracle.Digest.t
      module Checked = struct
        type t = Random_oracle.Checked.Digest.t
      end 
    end
  end

  module Predicated = struct
    module Poly = struct
      [%%versioned
      module Stable = struct
        module V1 = struct
          type ('body, 'predicate) t = {body: 'body; predicate: 'predicate}
          [@@deriving hlist, sexp, eq, yojson, hash, compare]
        end
      end]
    end

    module Proved = struct
      [%%versioned
      module Stable = struct
        module V1 = struct
          type t =
            (Body.Stable.V1.t, Snapp_predicate.Stable.V1.t) Poly.Stable.V1.t
          [@@deriving sexp, eq, yojson, hash, compare]

          let to_latest = Fn.id
        end
      end]

      module Digested = struct
        type t = (Body.Digested.t, Snapp_predicate.Digested.t) Poly.t

        module Checked = struct
          type t = (Body.Digested.Checked.t, Field.Var.t) Poly.t
        end 
      end
    end

    module Signed = struct
      [%%versioned
      module Stable = struct
        module V1 = struct
          type t =
            ( Body.Stable.V1.t
              (* It's really more natural for this to be a predicate. Consider doing this
   if predicates are not too expensive. *)
            , Account_nonce.Stable.V1.t )
            Poly.Stable.V1.t
          [@@deriving sexp, eq, yojson, hash, compare]

          let to_latest = Fn.id
        end
      end]

      module Digested = struct
        type t = (Body.Digested.t, Account_nonce.t) Poly.t

        module Checked = struct
          type t = (Body.Digested.Checked.t, Account_nonce.Checked.t) Poly.t
        end 
      end

      let dummy : t = {body= Body.dummy; predicate= Account_nonce.zero}
    end

    module Empty = struct
      [%%versioned
      module Stable = struct
        module V1 = struct
          type t = (Body.Stable.V1.t, unit) Poly.Stable.V1.t
          [@@deriving sexp, eq, yojson, hash, compare]

          let to_latest = Fn.id
        end
      end]

      let dummy : t = {body= Body.dummy; predicate= ()}
    end
  end

  module Authorized = struct
    module Poly = struct
      [%%versioned
      module Stable = struct
        module V1 = struct
          type ('data, 'auth) t = {data: 'data; authorization: 'auth}
          [@@deriving hlist, sexp, eq, yojson, hash, compare]
        end
      end]
    end

    module Proved = struct
      [%%versioned
      module Stable = struct
        module V1 = struct
          type t =
            ( Predicated.Proved.Stable.V1.t
            , Control.Stable.V1.t )
            Poly.Stable.V1.t
          [@@deriving sexp, eq, yojson, hash, compare]

          let to_latest = Fn.id
        end
      end]
    end

    module Signed = struct
      [%%versioned
      module Stable = struct
        module V1 = struct
          type t =
            ( Predicated.Signed.Stable.V1.t
            , Signature.Stable.V1.t )
            Poly.Stable.V1.t
          [@@deriving sexp, eq, yojson, hash, compare]

          let to_latest = Fn.id
        end
      end]
    end

    module Empty = struct
      [%%versioned
      module Stable = struct
        module V1 = struct
          type t = (Predicated.Empty.Stable.V1.t, unit) Poly.Stable.V1.t
          [@@deriving sexp, eq, yojson, hash, compare]

          let to_latest = Fn.id
        end
      end]
    end
  end
end

module Inner = struct
  [%%versioned
  module Stable = struct
    module V1 = struct
      type ('one, 'two) t =
        { token_id: Token_id.Stable.V1.t
        ; fee_payment: Other_fee_payer.Stable.V1.t option
        ; one: 'one
        ; two: 'two }
      [@@deriving sexp, eq, yojson, hash, compare, fields]
    end
  end]
end

[%%versioned
module Stable = struct
  module V1 = struct
    type t =
      | Proved_empty of
          ( Party.Authorized.Proved.Stable.V1.t
          , Party.Authorized.Empty.Stable.V1.t option )
          Inner.Stable.V1.t
      | Proved_signed of
          ( Party.Authorized.Proved.Stable.V1.t
          , Party.Authorized.Signed.Stable.V1.t )
          Inner.Stable.V1.t
      | Proved_proved of
          ( Party.Authorized.Proved.Stable.V1.t
          , Party.Authorized.Proved.Stable.V1.t )
          Inner.Stable.V1.t
      | Signed_signed of
          ( Party.Authorized.Signed.Stable.V1.t
          , Party.Authorized.Signed.Stable.V1.t )
          Inner.Stable.V1.t
      | Signed_empty of
          ( Party.Authorized.Signed.Stable.V1.t
          , Party.Authorized.Empty.Stable.V1.t option )
          Inner.Stable.V1.t
    [@@deriving sexp, eq, yojson, hash, compare]

    let to_latest = Fn.id
  end
end]

let token_id (t : t) : Token_id.t =
  match t with
  | Proved_empty {token_id; _}
  | Proved_signed {token_id; _}
  | Proved_proved {token_id; _}
  | Signed_signed {token_id; _}
  | Signed_empty {token_id; _} ->
      token_id

let assert_ b lab = if b then Ok () else Or_error.error_string lab

let is_non_neg (x : Amount.Signed.t) : bool =
  Amount.(equal zero) x.magnitude || x.sgn = Pos

let is_non_pos (x : Amount.Signed.t) : bool =
  Amount.(equal zero) x.magnitude || x.sgn = Neg

let is_neg x = not (is_non_neg x)

let check_neg x = assert_ (is_neg x) "expected negative"

let fee_token (t : t) : Token_id.t =
  let f (x : _ Inner.t) =
    match x.fee_payment with
    | Some x ->
        x.payload.token_id
    | None ->
        x.token_id
  in
  match t with
  | Proved_empty r ->
      f r
  | Proved_signed r ->
      f r
  | Proved_proved r ->
      f r
  | Signed_signed r ->
      f r
  | Signed_empty r ->
      f r

let native_excess_exn (t : t) =
  let open Party in
  let f1
      { Inner.one: ((Body.t, _) Predicated.Poly.t, _) Authorized.Poly.t
      ; two: ((Body.t, _) Predicated.Poly.t, _) Authorized.Poly.t option
      ; token_id
      ; _ } =
    match two with
    | None ->
        assert (is_neg one.data.body.delta) ;
        ( Account_id.create one.data.body.pk token_id
        , one.data.body.delta.magnitude )
    | Some two ->
        let x =
          Option.value_exn
            (Amount.Signed.add one.data.body.delta two.data.body.delta)
        in
        assert (is_neg x) ;
        let pk =
          if is_neg one.data.body.delta then one.data.body.pk
          else two.data.body.pk
        in
        (Account_id.create pk token_id, x.magnitude)
  in
  let f2 r = f1 {r with two= Some r.Inner.two} in
  match t with
  | Proved_empty r ->
      f1 r
  | Proved_signed r ->
      f2 r
  | Proved_proved r ->
      f2 r
  | Signed_signed r ->
      f2 r
  | Signed_empty r ->
      f1 r

let native_excess t = Option.try_with (fun () -> native_excess_exn t)

let fee_excess (t : t) : Fee_excess.t Or_error.t =
  let opt =
    Option.value_map ~f:Or_error.return ~default:(Or_error.error_string "None")
  in
  let open Or_error.Let_syntax in
  let finish r token_id fee_payment =
    let%bind () = check_neg r in
    let r = r.magnitude in
    let one = (token_id, Fee.Signed.of_unsigned (Amount.to_fee r)) in
    Fee_excess.of_one_or_two
      ( match fee_payment with
      | None ->
          `One one
      | Some (p : Other_fee_payer.t) ->
          `Two (one, (p.payload.token_id, Fee.Signed.of_unsigned p.payload.fee))
      )
  in
  let open Party in
  let f1
      { Inner.token_id
      ; fee_payment
      ; one: ((Body.t, _) Predicated.Poly.t, _) Authorized.Poly.t
      ; two: ((Body.t, _) Predicated.Poly.t, _) Authorized.Poly.t option } =
    let%bind r =
      match two with
      | None ->
          return one.data.body.delta
      | Some two ->
          Amount.Signed.add one.data.body.delta two.data.body.delta |> opt
    in
    finish r token_id fee_payment
  in
  let f2
      { Inner.token_id
      ; fee_payment
      ; one: ((Body.t, _) Predicated.Poly.t, _) Authorized.Poly.t
      ; two: ((Body.t, _) Predicated.Poly.t, _) Authorized.Poly.t } =
    let%bind r =
      Amount.Signed.add one.data.body.delta two.data.body.delta |> opt
    in
    finish r token_id fee_payment
  in
  match t with
  | Proved_empty r ->
      f1 r
  | Proved_signed r ->
      f2 r
  | Proved_proved r ->
      f2 r
  | Signed_signed r ->
      f2 r
  | Signed_empty r ->
      f1 r

let accounts_accessed (t : t) : Account_id.t list =
  let open Party in
  let f
      { Inner.token_id
      ; fee_payment
      ; one: ((Body.t, _) Predicated.Poly.t, _) Authorized.Poly.t
      ; two: ((Body.t, _) Predicated.Poly.t, _) Authorized.Poly.t option } =
    let a k = Account_id.create k token_id in
    a one.data.body.pk
    :: Option.(to_list (map two ~f:(fun x -> a x.data.body.pk)))
    @ Option.(
        to_list
          (map fee_payment ~f:(fun x ->
               Account_id.create x.payload.pk x.payload.token_id )))
  in
  let f2 r = f {r with two= Some r.Inner.two} in
  match t with
  | Proved_empty r ->
      f r
  | Signed_empty r ->
      f r
  | Proved_signed r ->
      f2 r
  | Proved_proved r ->
      f2 r
  | Signed_signed r ->
      f2 r

let next_available_token (_ : t) (next_available : Token_id.t) =
  (* TODO: Update when snapp account creation is implemented. *)
  next_available

module Valid = struct
  [%%versioned
  module Stable = struct
    module V1 = struct
      type t = Stable.V1.t [@@deriving sexp, eq, yojson, hash, compare]

      let to_latest = Fn.id
    end
  end]
end

module Payload = struct
  module Inner = struct
    [%%versioned
    module Stable = struct
      module V1 = struct
        type ('bool, 'token_id, 'fee_payer_opt, 'one, 'two) t =
          { second_starts_empty: 'bool
          ; second_ends_empty: 'bool
          ; token_id: 'token_id
          ; other_fee_payer_opt: 'fee_payer_opt
                (* It would be more optimal if it was
   - one: Body-minus-update
   - two: Body-minus-update
   - updates: { one: Update.t; two: Update.t }

   since both statements contain both updates.
*)
          ; one: 'one
          ; two: 'two }
        [@@deriving hlist, sexp, eq, yojson, hash, compare]
      end
    end]
  end

        open Snapp_basic
  module Zero_proved = struct
    [%%versioned
    module Stable = struct
      module V1 = struct
        type t =
          ( bool
          , Token_id.Stable.V1.t
          , Other_fee_payer.Payload.Stable.V1.t option
          , Party.Predicated.Signed.Stable.V1.t
          , Party.Predicated.Signed.Stable.V1.t )
          Inner.Stable.V1.t
        [@@deriving sexp, eq, yojson, hash, compare]

        let to_latest = Fn.id
      end
    end]

    module Digested = struct
      type t =
        ( bool
        , Token_id.t
        , Other_fee_payer.Payload.t option
        , Party.Predicated.Signed.Digested.t
        , Party.Predicated.Signed.Digested.t )
        Inner.t

      module Checked = struct
        type t =
          ( Boolean.var
          , Token_id.Checked.t
          , (Boolean.var, Other_fee_payer.Payload.Checked.t) Flagged_option.t
          , Party.Predicated.Signed.Digested.Checked.t
          , Party.Predicated.Signed.Digested.Checked.t )
          Inner.t
      end
    end
  end

  module One_proved = struct
    [%%versioned
    module Stable = struct
      module V1 = struct
        type t =
          ( bool
          , Token_id.Stable.V1.t
          , Other_fee_payer.Payload.Stable.V1.t option
          , Party.Predicated.Proved.Stable.V1.t
          , Party.Predicated.Signed.Stable.V1.t )
          Inner.Stable.V1.t
        [@@deriving sexp, eq, yojson, hash, compare]

        let to_latest = Fn.id
      end
    end]

    module Digested = struct
      type t =
        ( bool
        , Token_id.t
        , Other_fee_payer.Payload.t option
        , Party.Predicated.Proved.Digested.t
        , Party.Predicated.Signed.Digested.t )
        Inner.t
      module Checked = struct
        type t =
          ( Boolean.var
          , Token_id.Checked.t
          , (Boolean.var, Other_fee_payer.Payload.Checked.t) Flagged_option.t
          , Party.Predicated.Proved.Digested.Checked.t
          , Party.Predicated.Signed.Digested.Checked.t )
          Inner.t
      end 
    end
  end

  module Two_proved = struct
    [%%versioned
    module Stable = struct
      module V1 = struct
        type t =
          ( bool
          , Token_id.Stable.V1.t
          , Other_fee_payer.Payload.Stable.V1.t option
          , Party.Predicated.Proved.Stable.V1.t
          , Party.Predicated.Proved.Stable.V1.t )
          Inner.Stable.V1.t
        [@@deriving sexp, eq, yojson, hash, compare]

        let to_latest = Fn.id
      end
    end]

    module Digested = struct
      type t =
        ( bool
        , Token_id.t
        , Other_fee_payer.Payload.t option
        , Party.Predicated.Proved.Digested.t
        , Party.Predicated.Proved.Digested.t )
        Inner.t

        module Checked = struct
          type t =
            ( Boolean.var
            , Token_id.Checked.t
            , (Boolean.var, Other_fee_payer.Payload.Checked.t) Flagged_option.t
            , Party.Predicated.Proved.Digested.Checked.t
            , Party.Predicated.Proved.Digested.Checked.t )
            Inner.t
        end 
    end
  end

  module Poly = struct
    [%%versioned
    module Stable = struct
      module V1 = struct
        (* For consistency it would really make sense to have zero snapp as well. *)
        type ('zero, 'one, 'two) t =
          | Zero_proved of 'zero
          | One_proved of 'one
          | Two_proved of 'two
        [@@deriving sexp, eq, yojson, hash, compare]

        let to_latest = Fn.id
      end
    end]
  end

  [%%versioned
  module Stable = struct
    module V1 = struct
      type t =
        ( Zero_proved.Stable.V1.t
        , One_proved.Stable.V1.t
        , Two_proved.Stable.V1.t )
        Poly.Stable.V1.t
      [@@deriving sexp, eq, yojson, hash, compare]

      let to_latest = Fn.id
    end
  end]

  module Digested = struct
    type t =
      ( Zero_proved.Digested.t
      , One_proved.Digested.t
      , Two_proved.Digested.t )
      Poly.t

    module Checked = struct
      type t =
        ( Zero_proved.Digested.Checked.t
        , One_proved.Digested.Checked.t
        , Two_proved.Digested.Checked.t )
        Poly.t

    let to_input (t : t) =
      let open Random_oracle_input in
      let b = field in
        let (!) = Impl.run_checked in
      let inner
          ({ second_starts_empty
           ; second_ends_empty
           ; token_id
           ; other_fee_payer_opt
           ; one
           ; two } :
            _ Inner.t) ~f1 ~f2 =
        let p f {Party.Predicated.Poly.body; predicate} =
          List.reduce_exn ~f:append [b body; f predicate]
        in
        List.reduce_exn ~f:append
          [ bitstring [second_starts_empty; second_ends_empty]
          ; !(Token_id.Checked.to_input token_id)
          ; 
              Snapp_basic.Flagged_option.(
                to_input' 
                  ~f:Other_fee_payer.Payload.Checked.to_input
                   other_fee_payer_opt)
          ; p f1 one
          ; p f2 two ]
      in
      let nonce x =  !(Account_nonce.Checked.to_input x) in
      match t with
      | Zero_proved r ->
        inner r 
          ~f1:nonce
          ~f2:nonce
      | One_proved r ->
        inner r ~f1:field  ~f2:nonce
      | Two_proved r ->
          inner r ~f1:field ~f2:field

    let digest (t : t) =
      Random_oracle.Checked.(
        hash ~init:Hash_prefix.snapp_payload (pack_input (to_input t)))
    end

    let to_input (t : t) =
      let open Random_oracle_input in
      let b = field in
      let inner
          ({ second_starts_empty
           ; second_ends_empty
           ; token_id
           ; other_fee_payer_opt
           ; one
           ; two } :
            _ Inner.t) ~f1 ~f2 =
        let p f {Party.Predicated.Poly.body; predicate} =
          List.reduce_exn ~f:append [b body; f predicate]
        in
        List.reduce_exn ~f:append
          [ bitstring [second_starts_empty; second_ends_empty]
          ; Token_id.to_input token_id
          ; 
              Snapp_basic.Flagged_option.(
                to_input' ~f:Other_fee_payer.Payload.to_input
                (of_option 
                    ~default:Other_fee_payer.Payload.dummy
                   other_fee_payer_opt))
          ; p f1 one
          ; p f2 two ]
      in
      match t with
      | Zero_proved r ->
          inner r ~f1:Account_nonce.to_input ~f2:Account_nonce.to_input
      | One_proved r ->
          inner r ~f1:field ~f2:Account_nonce.to_input
      | Two_proved r ->
          inner r ~f1:field ~f2:field

    let digest (t : t) =
      Random_oracle.(
        hash ~init:Hash_prefix.snapp_payload (pack_input (to_input t)))
  end

  let digested (t : t) : Digested.t =
    let b (x : _ Party.Predicated.Poly.t) =
      {x with body= Party.Body.digest x.body}
    in
    let s x =
      let t = b x in
      {t with predicate= Snapp_predicate.digest t.predicate}
    in
    match t with
    | Zero_proved r ->
        Zero_proved {r with one= b r.one; two= b r.two}
    | One_proved r ->
        One_proved {r with one= s r.one; two= b r.two}
    | Two_proved r ->
        Two_proved {r with one= s r.one; two= s r.two}
end

(* Check that the deltas are consistent with each other. *)
(* TODO: Check that predicates are consistent. *)
(* TODO: Check the predicates that can be checked (e.g., on fee_payment) *)
let check (t : t) : unit Or_error.t =
  let opt lab = function
    | None ->
        Or_error.error_string lab
    | Some x ->
        Ok x
  in
  let open Or_error.Let_syntax in
  let open Party in
  let fee_checks ~excess ~token_id ~(fee_payment : Other_fee_payer.t option) =
    match fee_payment with
    | None ->
        let%bind () =
          assert_
            (Token_id.equal Token_id.default token_id)
            "token id must be default if no external fee payment is provided"
        in
        let%bind () =
          assert_ (is_non_pos excess)
            "delta excess must be non-positive if no external fee payment is \
             provided"
        in
        return ()
    | Some p ->
        let%bind () =
          assert_
            (Token_id.equal Token_id.default p.payload.token_id)
            "non-default token IDs not supported for fees"
        in
        let%bind () =
          assert_
            (Amount.Signed.(equal zero) excess)
            "delta excess must be zero if an external fee payment is provided"
        in
        return ()
  in
  let check_both
      ({token_id; fee_payment; one; two} :
        ( ((_ Body.Poly.t, _) Predicated.Poly.t, _) Authorized.Poly.t
        , ((_ Body.Poly.t, _) Predicated.Poly.t, _) Authorized.Poly.t )
        Inner.t) =
    let%bind excess =
      opt "overflow"
        (Amount.Signed.add one.data.body.delta two.data.body.delta)
    in
    let%bind () =
      assert_
        (not (is_neg one.data.body.delta && is_neg two.data.body.delta))
        "both accounts negative"
    in
    fee_checks ~excess ~token_id ~fee_payment
  in
  let check_opt
      ({token_id; fee_payment; one; two} :
        ( ((_ Body.Poly.t, _) Predicated.Poly.t, _) Authorized.Poly.t
        , ((_ Body.Poly.t, _) Predicated.Poly.t, _) Authorized.Poly.t option
        )
        Inner.t) =
    let%bind excess =
      opt "overflow"
        ( match two with
        | None ->
            Some one.data.body.delta
        | Some two ->
            Amount.Signed.add one.data.body.delta two.data.body.delta )
    in
    let%bind () =
      let two_is_neg =
        match two with None -> false | Some two -> is_neg two.data.body.delta
      in
      assert_
        (not (is_neg one.data.body.delta && two_is_neg))
        "both accounts negative"
    in
    fee_checks ~excess ~token_id ~fee_payment
  in
  match t with
  | Proved_empty r ->
      check_opt r
  | Signed_empty r ->
      check_opt r
  | Signed_signed r ->
      check_both r
  | Proved_signed r ->
      check_both r
  | Proved_proved r ->
      check_both r

(* This function is evidently injective (ignoring authorization) *)
let to_payload (t : t) : Payload.t =
  let opt x =
    Option.value_map x ~default:Party.Predicated.Signed.dummy
      ~f:(fun {Party.Authorized.Poly.data; authorization= _} ->
        {data with predicate= Party.Predicated.Signed.dummy.predicate} )
  in
  match t with
  | Proved_empty
      {one= {data= one; authorization= _}; two; token_id; fee_payment} ->
      One_proved
        { second_starts_empty= true
        ; second_ends_empty= Option.is_none two
        ; one
        ; two= opt two
        ; token_id
        ; other_fee_payer_opt=
            Option.map fee_payment ~f:(fun {payload; signature= _} -> payload)
        }
  | Signed_empty
      {one= {data= one; authorization= _}; two; token_id; fee_payment} ->
      Zero_proved
        { second_starts_empty= true
        ; second_ends_empty= Option.is_none two
        ; one
        ; two= opt two
        ; token_id
        ; other_fee_payer_opt=
            Option.map fee_payment ~f:(fun {payload; signature= _} -> payload)
        }
  | Signed_signed
      { one= {data= one; authorization= _}
      ; two= {data= two; authorization= _}
      ; token_id
      ; fee_payment } ->
      Zero_proved
        { second_starts_empty= false
        ; second_ends_empty= false
        ; one
        ; two
        ; token_id
        ; other_fee_payer_opt=
            Option.map fee_payment ~f:(fun {payload; signature= _} -> payload)
        }
  | Proved_signed
      { one= {data= one; authorization= _}
      ; two= {data= two; authorization= _}
      ; token_id
      ; fee_payment } ->
      One_proved
        { second_starts_empty= false
        ; second_ends_empty= false
        ; one
        ; two
        ; token_id
        ; other_fee_payer_opt=
            Option.map fee_payment ~f:(fun {payload; signature= _} -> payload)
        }
  | Proved_proved
      { one= {data= one; authorization= _}
      ; two= {data= two; authorization= _}
      ; token_id
      ; fee_payment } ->
      Two_proved
        { second_starts_empty= false
        ; second_ends_empty= false
        ; one
        ; two
        ; token_id
        ; other_fee_payer_opt=
            Option.map fee_payment ~f:(fun {payload; signature= _} -> payload)
        }
