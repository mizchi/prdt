# mizchi/prdt

Replicated domain objects built from a **pure domain state machine** and a
**replicated finalization protocol**, following
[PRDTs: Composable Design and Verification of Consensus Protocols using Replicated Data Types](https://arxiv.org/html/2504.05173v3).

```text
Pure Domain State Machine
        +
Replicated Finalization Protocol
        =
Replicated Domain Object
```

The core has no clock, randomness, network, or platform crypto. Hashing and
signing go through the `Hasher`, `Signer`, and `Verifier` traits (the same
shape as `mizchi/converge_audit`, where this package was first developed), so
real hashers and signers can be plugged in. `examples/cf-room` hosts the MMO
sample in a Cloudflare Durable Object.

## Packages

| Package | Responsibility |
| --- | --- |
| `prdt` | Envelope, canonical JSON + SHA-256 hashing, canonical order, `Domain`, `resolve_batch`, proposal / closure / committed lattices, `Protocol`, `ReplicatedDomain`, finalizers, laws |
| `mizchi/prdt/mmo` | MMO sample: world, commands, events, rejections, reducer, phase order, reference scenario |
| `mizchi/prdt/runtime` | Seeded PRNG, adversarial in-memory network, checkpoint store, replica with outbox, quorum agent, randomized simulator (single-authority or quorum mode, compaction, digest anti-entropy with state transfer) |
| `mizchi/prdt/contracts` | Dependency-free pure functions with Why3/Z3-discharged contracts: quorum threshold, compaction arithmetic, decision order, vote-slot join |
| `mizchi/prdt/mmo/simulation` | MMO wiring for the simulator, scenario generator, property-style and negative tests |
| `mizchi/prdt/worker` | JSON-string bridge exported to JS / wasm-gc for hosts such as Durable Objects |

Dependencies point one way: `worker -> mmo -> prdt -> contracts`,
`runtime -> prdt`, `mmo/simulation -> {mmo, runtime, prdt}`, where `prdt` is
the root package. The domain never
imports the protocol.

## Layers

```text
Runtime  ->  PRDT Protocol  ->  Finalization  ->  Domain
runtime/     replicated_domain  resolve_batch     domain.mbt, mmo/
             proposal_state
             closure, committed_log, finalizer, single_authority, quorum
```

### Domain

```moonbit
pub(all) struct Domain[S, C, E, R] {
  initial_state : () -> S
  validate : (S, C) -> Validation[E, R]   // pure
  apply : (S, E) -> S                      // pure, non-mutating
}
```

`resolve_batch(tick, previous_state, commands, domain, order, hasher)` copies
the commands, sorts them by the canonical `CommandOrder`, validates each one
against the state immediately before it, applies accepted events, and
returns verdicts plus state hashes. `alive` (`hp > 0`) is evaluated here and
never as a proposal-time precondition.

### PRDT

| Type | Lattice | Refusal |
| --- | --- | --- |
| `ProposalState[C]` | tick → command id → envelope, grow-only | `ConflictingProposal(id)` when one id carries two payloads |
| `ClosureDecision` / `ClosureMap` | `ClosurePending <= Closed(c)`; `Closed(a) <= Closed(b)` iff `a == b` | `ConflictingClosure(tick)` |
| `CommittedLog[R]` | prefix order | `PrefixConflict(index)` |
| `State` | product of the three, then `advance` | see `Protocol::apply_delta` |

`Protocol::apply_delta` verifies every certificate with the configured
`Finalizer`, checks `ordered_commands_hash`, joins, and then materializes as
many consecutive ticks as are both closed and fully known. A certificate whose
`parent_decision_hash` or id order disagrees with the local recomputation is a
`ChainMismatch` / `OrderMismatch` and the whole delta is refused. Commands that
arrive after their tick closed become `DecisionLate(tick)` and never touch a
committed batch. The committed prefix is derived from knowledge and is never
transported; `Protocol::restore` re-derives it and refuses a snapshot whose
persisted prefix disagrees.

### Compaction, digests, and state transfer

`State` carries a `Base[S]`: the decision hash and domain state at
`next_tick - 1` (genesis by default). `Protocol::compact(state, retain_ticks~)`
folds the oldest materialized batches into the base and forgets proposals and
closures below it. Compaction is administrative, not a join: it never changes
a verdict, but `decision` stops reporting commands of compacted ticks, and
proposals for compacted ticks are dropped on ingest.

`Protocol::join` adopts the later base and refuses (`PrefixConflict`) a peer
whose committed prefix contradicts it. `Protocol::digest` summarizes what a
replica knows (`base_next_tick`, `next_tick`, retained ids, closed ticks,
certified ticks) and `delta_since` / `catchup_since` return only what a peer
with that digest is missing; a `Catchup` also carries the sender's base and
its certificate so a peer that fell behind a compacted history can resume.

**Authenticated bases.** A base cannot be re-derived once its history is
forgotten, so it is only ever adopted with a `BaseCertificate`: the closure
authority signs the head after every closure (`ClosureAuthority::certify_base`),
or a majority of the quorum signs `BaseVote`s that `assemble_base_certificate`
turns into one. `Finalizer::verify_base` checks it. `apply_delta` records
certificates (`ConflictingBase` when one contradicts local history), `compact`
only moves to a certified boundary, and `apply_catchup` refuses an uncertified
or mismatching base with `UnauthenticatedBase`.

### Finalizers

```moonbit
pub(open) trait Finalizer {
  verify_closure(Self, ClosureCertificate) -> Bool
}
```

- `SingleAuthorityFinalizer` / `ClosureAuthority`: one key signs the closure
  payload digest with the root `Signer`; every replica verifies it.
- `QuorumFinalizer` / `Voter` / `VoteState`: a tick closes when at least
  `threshold` distinct roster members sign the same payload. `QuorumRoster::new`
  enforces `2 * threshold > roster.length()`, so at most one payload per tick
  can qualify; an equivocating voter is excluded from every tally. Certificate
  identity is the payload, so certificates assembled from different vote
  subsets are the same decision.
- `runtime/QuorumAgent`: any replica may propose to close its next tick; a
  voter signs the first proposal that targets its next tick, chains from its
  head, and lists only known commands in canonical order (one vote per tick).
  Whoever collects a majority assembles the certificate and gossips it. Every
  agent also signs a base vote for each new head, so bases get certified by
  the same majority. Safety comes from the vote lattices; liveness is best
  effort (no leader election or view change).

### Late-command policy (runtime)

`Replica` takes a `LateCommandPolicy`. `RejectAsLate` keeps the protocol
verdict. `MoveToNextTick(max_moves~)` re-issues an own command that became
`DecisionLate` at the earliest tick the replica does not know to be closed,
with a fresh envelope id, at most `max_moves` times per lineage; the move
ledger is checkpointed so a restart never re-issues twice. The original
command stays `DecisionLate` forever; re-issuing is a runtime decision layered
on top of the protocol.

### Proved contracts (`prdt/contracts`)

`moon prove src/contracts` discharges 19 goals with Why3/Z3:

- `quorum_threshold_valid`: two quorums intersect, and disjoint quorums cannot
  both exist (`majority_is_unique`).
- `compaction_drop`: bounded, keeps exactly the retention window, no-op inside
  it, and never moves the finalized frontier.
- `decision_kind_less_or_equal`: reflexive, antisymmetric, transitive, Pending
  is the bottom, and a final decision never changes (Accepted never becomes
  Rejected or Late).
- `merge_vote_slot_kind`: idempotent, commutative, equivocation absorbing,
  conflicting votes never count.

The executable code calls these functions (`QuorumRoster::new`,
`Protocol::compact`, `decision_less_or_equal`), so the proved facts are the
ones the protocol runs on. The lattice laws over the full generic state are
still checked by seeded property tests, not proofs.

`SharedSecretAuthenticator` is an HMAC-SHA256 MAC for tests and development,
not a signature.

## Verified properties

| Property | Where |
| --- | --- |
| Domain rules, batch order independence, conflicts, closure uniqueness, prefix conflicts, late commands, forged / malformed / wrong-parent / non-canonical certificates, snapshot restore and tamper detection, quorum assembly and equivocation, compaction to certified boundaries, digest deltas, catchup, unauthenticated / forged / mismatching bases, join across bases | `*_test.mbt` in the root package and `mmo` |
| Quorum threshold, compaction arithmetic, decision order, vote-slot join | `contracts` (`moon prove`) |
| `MoveToNextTick` re-issue, `max_moves`, move ledger across restart | `mmo/simulation/late_policy_test.mbt` |
| Lattice laws for proposal / closure / log / vote / whole state; delivery order, duplication, and merge-tree invariance; snapshot round trip; decision monotonicity under `apply_delta` and `join`; closure uniqueness; prefix safety; late-command finality; domain validity (`Accepted(SkillActivated) => hp > 0 && mp >= cost` immediately before, `hp >= 0`) | `mmo/simulation/property_test.mbt` (seeded generators) |
| Convergence under reorder, duplication, partition, restart from checkpoint, compaction with certified state transfer, single-authority and quorum closure (3 and 5 replicas, with an equivocating voter), `MoveToNextTick`; reproducibility by seed | `mmo/simulation/simulation_test.mbt`, `late_policy_test.mbt` |
| Unstable `alive` guard; premature acceptance breaks monotonicity | `prdt/mmo/simulation/negative_test.mbt` |
| JSON bridge round trip, error reporting, digest sync with certified base transfer | `worker/bridge_test.mbt` |

PRDT agreement alone does **not** imply domain validity: every replica could
consistently accept a dead player's skill. Domain validity is checked
separately against the state immediately before each accepted command.

## Commands

```sh
just check          # moon check --target all
just test           # moon test
just prove          # Why3/Z3 proofs for src/contracts (needs why3 + z3, or `nix develop`)
just test-cf-room   # Cloudflare Durable Object host (workerd)
```

Reference: [PRDTs: Composable Design and Verification of Consensus Protocols
using Replicated Data Types](https://arxiv.org/html/2504.05173v3). Design
notes in Japanese: [docs/design-ja.md](docs/design-ja.md).

## Not implemented

- Byzantine fault tolerance beyond excluding equivocating quorum voters.
- Quorum liveness: leader election, view change, vote retry.
- Entity/zone sharding and cross-scope transactions.
- Proofs over the full generic lattices (only the abstract kinds are proved).
