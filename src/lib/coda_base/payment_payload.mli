open Core
open Snark_params.Tick

module Poly : sig
  type ('pk, 'amount) t = {receiver: 'pk; amount: 'amount}
  [@@deriving eq, sexp, hash, yojson]

  module Stable :
    sig
      module V1 : sig
        type nonrec ('pk, 'amount) t
        [@@deriving bin_io, eq, sexp, hash, yojson, version]
      end

      module Latest = V1
    end
    with type ('pk, 'amount) V1.t = ('pk, 'amount) t
end

[%%versioned:
module Stable : sig
  module V1 : sig
    type t =
      (Account_id.Stable.V1.t, Currency.Amount.Stable.V1.t) Poly.Stable.V1.t
    [@@deriving compare, eq, sexp, hash, compare, yojson]
  end
end]

type t = Stable.Latest.t [@@deriving eq, sexp, hash, yojson]

val dummy : t

val token : t -> Token_id.t

val gen : max_amount:Currency.Amount.t -> t Quickcheck.Generator.t

type var = (Account_id.var, Currency.Amount.var) Poly.t

val typ : (var, t) Typ.t

val to_input : t -> (Field.t, bool) Random_oracle.Input.t

val var_to_input : var -> (Field.Var.t, Boolean.var) Random_oracle.Input.t

val var_of_t : t -> var
