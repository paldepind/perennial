From RecordUpdate Require Import RecordSet.

From Perennial.Helpers Require Import CountableTactics Transitions.
From Perennial.goose_lang Require Import lang lifting slice typing.
From Perennial.goose_lang Require ffi.disk.

(* TODO: move this out, it's completely general *)
Inductive RecoverableState {Σ: Type} :=
| UnInit
| Closed (s:Σ)
| Opened (s:Σ)
.
Arguments RecoverableState Σ : clear implicits.

Definition recoverable_model (Σ: Type) : ffi_model :=
  mkFfiModel (RecoverableState Σ) (populate UnInit).

Definition openΣ {ext:ext_op} {Σ: Type} : transition (@state ext (recoverable_model Σ)) Σ :=
  bind (reads id) (λ (rs: @state _ (recoverable_model Σ)), match rs.(world) with
                         | Opened s => ret s
                         | _ => undefined
                         end).

Definition modifyΣ {ext:ext_op} {Σ: Type} (f:Σ -> Σ) : transition (@state ext (recoverable_model Σ)) unit :=
  bind (reads id) (λ (rs: @state _ (recoverable_model Σ)), match rs.(world) with
                         | Opened s => modify (set world (fun (_:@ffi_state (recoverable_model Σ)) => Opened (f s)))
                         | _ => undefined
                         end).

(* TODO: generalize to a transition to construct the initial value, using a zoom *)
Definition initTo {ext:ext_op} {Σ: Type} (init:Σ) : transition (@state ext (recoverable_model Σ)) unit :=
  bind (reads id) (λ (rs: @state _ (recoverable_model Σ)), match rs.(world) with
                         | UnInit => modify (set world (fun (_:@ffi_state (recoverable_model Σ)) => Opened init))
                         | _ => undefined
                         end).

Definition open {ext:ext_op} {Σ: Type} : transition (@state ext (recoverable_model Σ)) Σ :=
  bind (reads id) (λ (rs: @state _ (recoverable_model Σ)), match rs.(world) with
                         | Closed s => bind (modify (set world (fun (_:@ffi_state (recoverable_model Σ)) => Opened s)))
                                      (fun _ => ret s)
                         | _ => undefined
                         end).

Definition close {ext:ext_op} {Σ: Type} : transition (RecoverableState Σ) unit :=
  bind (reads id) (fun s => match s with
                         | Opened s => modify (fun _ => Closed s)
                         | _ => undefined
                         end).

Instance Recoverable_inhabited state : Inhabited (RecoverableState state) := populate UnInit.

Definition ty_ := forall (val_ty:val_types), @ty val_ty.
(* TODO: slice should not require an entire ext_ty *)
Definition sliceT_ (t: ty_) : ty_ := λ val_ty, prodT (arrayT (t _)) uint64T.
Definition blockT_: ty_ := sliceT_ (λ val_ty, byteT).


Inductive LogOp :=
  | AppendOp (* log, slice of blocks *)
  | GetOp (* log, index *)
  | ResetOp (* log *)
  | InitOp (* disk size *)
  | OpenOp (* (no arguments) *)
.

Instance eq_LogOp : EqDecision LogOp.
Proof.
  solve_decision.
Defined.

Instance LogOp_fin : Countable LogOp.
Proof.
  solve_countable LogOp_rec 5%nat.
Qed.

Inductive Log_val := Log (vs:list disk.Block).
Instance eq_Log_val : EqDecision Log_val.
Proof.
  solve_decision.
Defined.

Instance eq_Log_fin : Countable Log_val.
Proof.
  apply (inj_countable' (λ v, match v with
                               | Log vs => vs
                               end) Log);
    by intros [].
Qed.

Definition log_op : ext_op.
Proof.
  refine (mkExtOp LogOp _ _ Log_val _ _).
Defined.

Inductive Log_ty := LogT.

Instance log_val_ty: val_types :=
  {| ext_tys := Log_ty; |}.

Section log.
  Existing Instances log_op log_val_ty.
  Instance log_ty: ext_types log_op :=
    {| val_tys := log_val_ty;
       val_ty_def t := match t with
                       | LogT => Log []
                       end;
       get_ext_tys (op: @external log_op) :=
         match op with
         | AppendOp => (extT LogT, sliceT_ blockT_ _)
         | GetOp => (prodT (extT LogT) uint64T, prodT (blockT_ _) boolT)
         | ResetOp => (extT LogT, unitT)
         | InitOp => (uint64T, extT LogT)
         | OpenOp => (unitT, extT LogT)
         end; |}.

  Definition log_state := RecoverableState (list disk.Block).

  Instance log_model : ffi_model := recoverable_model (list disk.Block).

  Existing Instances r_mbind r_fmap.

  Definition read_slice (t:ty) (v:val): transition state (list val) :=
    match v with
    | PairV (#(LitLoc l)) (PairV #(LitInt sz) #(LitInt cap)) =>
      (* TODO: implement *)
      ret []
    | _ => undefined
    end.

  Fixpoint tmapM {Σ A B} (f: A -> transition Σ B) (l: list A) : transition Σ (list B) :=
    match l with
    | [] => ret []
    | x::xs => f x;; tmapM f xs
    end.

  (* TODO: implement *)
  Definition to_block (l: list val): option disk.Block := None.

  Definition log_step (op:LogOp) (v:val) : transition state val :=
    match op, v with
    | GetOp, LitV (LitInt a) =>
      log ← openΣ;
      b ← unwrap (log !! int.nat a);
      l ← allocateN 4096;
      modify (state_insert_list l (disk.Block_to_vals b));;
      ret $ #(LitLoc l)
    | ResetOp, LitV LitUnit =>
      modifyΣ (fun _ => []);;
      ret $ #()
    | InitOp, LitV LitUnit =>
      initTo [];;
      ret $ ExtV (Log [])
    | OpenOp, LitV LitUnit =>
      s ← open;
      ret $ ExtV (Log s)
    | AppendOp, v =>
      (* FIXME: append should be non-atomic in the spec because it needs to read
         an input slice (and the slices the input points to). *)
      (* this is absolutely horrendous to reason about *)
      block_slices ← read_slice (slice.T (slice.T byteT)) v;
      block_vals ← tmapM (read_slice (@slice.T _ log_ty byteT)) block_slices;
      new_blocks ← tmapM (unwrap ∘ to_block) block_vals;
      modifyΣ (λ s, s ++ new_blocks);;
      ret $ #()
    | _, _ => undefined
    end.

  Instance log_semantics : ext_semantics log_op log_model :=
    {| ext_step := log_step;
       ext_crash := fun s s' => relation.denote close s s' tt; |}.
End log.
