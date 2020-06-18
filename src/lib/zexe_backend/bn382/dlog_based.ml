open Common
open Basic
module Field = Fq

module Bigint = struct
  module R = struct
    include Field.Bigint

    let to_field = Field.of_bigint

    let of_field = Field.to_bigint
  end
end

let field_size : Bigint.R.t = Field.size

module R1CS_constraint_system =
  R1cs_constraint_system.Make (Field) (Snarky_bn382.Fq.Constraint_matrix)
module Var = Var

module Verification_key = struct
  type t

  let to_string _ = failwith "TODO"

  let of_string _ = failwith "TODO"
end

module Proof = Dlog_based_proof.Make (struct
  module Scalar_field = Field
  module Backend = Snarky_bn382.Fq_proof
  module Verifier_index = Snarky_bn382.Fq_verifier_index
  module Index = Snarky_bn382.Fq_index
  module Evaluations_backend = Snarky_bn382.Fq_proof.Evaluations
  module Opening_proof_backend = Snarky_bn382.Fq_opening_proof
  module Poly_comm = Fq_poly_comm
  module Curve = G
end)

open Core_kernel

module Proving_key = struct
  type t = Snarky_bn382.Fq_index.t

  include Binable.Of_binable
            (Unit)
            (struct
              type nonrec t = t

              let to_binable _ = ()

              let of_binable () = failwith "TODO"
            end)

  let is_initialized _ = `Yes

  let set_constraint_system _ _ = ()

  let to_string _ = failwith "TODO"

  let of_string _ = failwith "TODO"
end

module Rounds = Pickles_types.Nat.N17

module Keypair = Dlog_based_keypair.Make (struct
  module Rounds = Rounds
  module Urs = Snarky_bn382.Fq_urs
  module Index = Snarky_bn382.Fq_index
  module Curve = G
  module Poly_comm = Fq_poly_comm
  module Verifier_index = Snarky_bn382.Fq_verifier_index
  module Constraint_matrix = Snarky_bn382.Fq.Constraint_matrix
end)