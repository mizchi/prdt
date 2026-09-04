///|
/// Finalization layer: resolves one tick's command set into verdicts.
///
/// `resolve_batch` is deterministic in the *set* of commands: the input is
/// copied and sorted by the canonical order before validation, so any
/// permutation of the same commands produces the same result.
pub(all) struct ResolvedBatch[S, C, E, R] {
  tick : Int
  previous_state_hash : String
  ordered_command_hash : String
  results : Array[ResolvedCommand[C, E, R]]
  resulting_state : S
  resulting_state_hash : String
} derive(Eq, Debug, ToJson, FromJson)

///|
pub(all) suberror BatchError {
  BatchTickMismatch(Int, Int, String)
  DuplicateCommandId(String)
} derive(Eq, Debug)

///|
pub fn hash_command_ids(hasher : &Hasher, ids : Array[String]) -> String {
  hash_json(hasher, Json::array(ids.map(fn(id) { id.to_json() })))
}

///|
pub fn[S : ToJson, C, E, R] resolve_batch(
  tick : Int,
  previous_state : S,
  commands : Array[Envelope[C]],
  domain : Domain[S, C, E, R],
  order : CommandOrder[C],
  hasher : &Hasher,
) -> ResolvedBatch[S, C, E, R] raise BatchError {
  for envelope in commands {
    if envelope.tick != tick {
      raise BatchTickMismatch(tick, envelope.tick, envelope.id)
    }
  }
  let ordered = sort_commands(commands, order)
  let seen : Map[String, Unit] = Map([])
  for envelope in ordered {
    if seen.contains(envelope.id) {
      raise DuplicateCommandId(envelope.id)
    }
    seen[envelope.id] = ()
  }
  let mut state = previous_state
  let results : Array[ResolvedCommand[C, E, R]] = []
  for envelope in ordered {
    match (domain.validate)(state, envelope.command) {
      Accept(event) => {
        state = (domain.apply)(state, event)
        results.push({ envelope, verdict: Accepted(event~) })
      }
      Reject(reason) => results.push({ envelope, verdict: Rejected(reason~) })
    }
  }
  {
    tick,
    previous_state_hash: hash_value(hasher, previous_state),
    ordered_command_hash: hash_command_ids(hasher, ordered.map(fn(e) { e.id })),
    results,
    resulting_state: state,
    resulting_state_hash: hash_value(hasher, state),
  }
}
