///|
/// Randomized distributed simulation.
///
/// N replicas exchange gossip over an adversarial in-memory network with
/// delays, reordering, duplication, partitions, crash/restart from
/// checkpoint, compaction, and digest-driven anti-entropy with state
/// transfer. Ticks are closed either by a single authority (replica 0) or by
/// quorum votes among all replicas. At the end the partition is healed,
/// every message is delivered, and anti-entropy runs until quiescence; the
/// report then states whether every replica converged.
pub(all) struct SimulationCounters {
  mut proposals : Int
  mut deliveries : Int
  mut duplicates : Int
  mut partitions : Int
  mut heals : Int
  mut closures : Int
  mut closure_proposals : Int
  mut restarts : Int
  mut checkpoints : Int
  mut compactions : Int
  mut anti_entropy : Int
  mut late_commands : Int
  mut reissues : Int
} derive(Eq, Debug)

///|
pub(all) struct SimulationReport {
  seed : Int
  counters : SimulationCounters
  replica_ids : Array[String]
  state_hashes : Array[String]
  next_ticks : Array[Int]
  head_decision_hashes : Array[String]
  domain_state_hashes : Array[String]
  converged : Bool
  protocol_errors : Array[String]
} derive(Eq, Debug)

///|
pub impl ToJson for SimulationReport with fn to_json(self) {
  {
    "seed": self.seed.to_json(),
    "counters": {
      "proposals": self.counters.proposals.to_json(),
      "deliveries": self.counters.deliveries.to_json(),
      "duplicates": self.counters.duplicates.to_json(),
      "partitions": self.counters.partitions.to_json(),
      "heals": self.counters.heals.to_json(),
      "closures": self.counters.closures.to_json(),
      "closure_proposals": self.counters.closure_proposals.to_json(),
      "restarts": self.counters.restarts.to_json(),
      "checkpoints": self.counters.checkpoints.to_json(),
      "compactions": self.counters.compactions.to_json(),
      "anti_entropy": self.counters.anti_entropy.to_json(),
      "late_commands": self.counters.late_commands.to_json(),
      "reissues": self.counters.reissues.to_json(),
    },
    "replica_ids": self.replica_ids.to_json(),
    "state_hashes": self.state_hashes.to_json(),
    "next_ticks": self.next_ticks.to_json(),
    "head_decision_hashes": self.head_decision_hashes.to_json(),
    "domain_state_hashes": self.domain_state_hashes.to_json(),
    "converged": self.converged.to_json(),
    "protocol_errors": self.protocol_errors.to_json(),
  }
}

///|
/// How ticks get closed.
pub(all) enum ClosureMode[C] {
  /// Replica 0 signs certificates.
  SingleAuthority(@prdt.ClosureAuthority[C])
  /// Every replica votes; `voters[i]` signs for replica i. Replicas listed in
  /// `equivocators` also sign a conflicting empty set whenever they propose.
  Quorum(@prdt.QuorumFinalizer, Array[@prdt.Voter[C]], Array[Int])
}

///|
pub(all) struct SimulationOptions {
  seed : Int
  steps : Int
  replica_count : Int
  /// How far ahead of the leading replica's next tick a proposal may target.
  tick_horizon : Int
  /// Materialized batches to keep when compacting; `None` disables compaction.
  compaction_retain : Int?
  /// What replicas do with their own late commands.
  late_policy : LateCommandPolicy
}

///|
pub fn SimulationOptions::new(
  seed~ : Int,
  steps? : Int = 400,
  replica_count? : Int = 3,
  tick_horizon? : Int = 2,
  compaction_retain? : Int,
  late_policy? : LateCommandPolicy = RejectAsLate,
) -> SimulationOptions {
  { seed, steps, replica_count, tick_horizon, compaction_retain, late_policy }
}

///|
priv enum Action {
  Propose
  Deliver
  Duplicate
  Partition
  Heal
  Close
  Restart
  Checkpoint
  Compact
  AntiEntropy
}

///|
let action_weights : Array[(Action, Int)] = [
  (Propose, 30),
  (Deliver, 40),
  (Duplicate, 6),
  (Partition, 3),
  (Heal, 4),
  (Close, 10),
  (Restart, 2),
  (Checkpoint, 3),
  (Compact, 3),
  (AntiEntropy, 6),
]

///|
fn pick_action(rng : Rng) -> Action {
  let mut total = 0
  for entry in action_weights {
    total += entry.1
  }
  let mut roll = rng.int(total)
  for entry in action_weights {
    if roll < entry.1 {
      return entry.0
    }
    roll -= entry.1
  }
  Deliver
}

///|
pub fn[
  S : ToJson + @json.FromJson,
  C : Eq + ToJson + @json.FromJson,
  E : ToJson + @json.FromJson,
  R : ToJson + @json.FromJson,
] run_simulation(
  protocol : @prdt.Protocol[S, C, E, R],
  mode : ClosureMode[C],
  generate_command : (Rng, Int) -> C,
  options : SimulationOptions,
) -> SimulationReport raise @prdt.ProtocolError {
  let rng = Rng::new(options.seed)
  let replica_count = options.replica_count
  let network : InMemoryNetwork[Gossip[S, C]] = InMemoryNetwork::new()
  let ids : Array[String] = []
  for index in 0..<replica_count {
    ids.push("r" + index.to_string())
  }
  let replicas : Array[Replica[S, C, E, R]] = []
  let agents : Map[String, QuorumAgent[S, C, E, R]] = Map([])
  for index, id in ids {
    let store = InMemoryCheckpointStore::new()
    match mode {
      SingleAuthority(authority) =>
        if index == 0 {
          replicas.push(
            Replica::new(
              protocol,
              id,
              store,
              authority~,
              late_policy=options.late_policy,
            ),
          )
        } else {
          replicas.push(
            Replica::new(protocol, id, store, late_policy=options.late_policy),
          )
        }
      Quorum(finalizer, voters, equivocators) => {
        let replica = Replica::new(
          protocol,
          id,
          store,
          late_policy=options.late_policy,
        )
        replicas.push(replica)
        agents[id] = QuorumAgent::new(
          replica,
          voters[index],
          finalizer,
          equivocate=equivocators.contains(index),
        )
      }
    }
  }
  let by_id : Map[String, Replica[S, C, E, R]] = Map([])
  for replica in replicas {
    by_id[replica.id()] = replica
  }
  let counters : SimulationCounters = {
    proposals: 0,
    deliveries: 0,
    duplicates: 0,
    partitions: 0,
    heals: 0,
    closures: 0,
    closure_proposals: 0,
    restarts: 0,
    checkpoints: 0,
    compactions: 0,
    anti_entropy: 0,
    late_commands: 0,
    reissues: 0,
  }
  let protocol_errors : Array[String] = []
  let broadcast_gossip = fn(sender : String, gossip : Gossip[S, C]) {
    for receiver in ids {
      if receiver != sender {
        network.send(sender, receiver, gossip)
      }
    }
  }
  let broadcast = fn(sender : Replica[S, C, E, R]) {
    for delta in sender.drain_outbox() {
      broadcast_gossip(sender.id(), DeltaGossip(delta))
    }
  }
  let leading_tick = fn() {
    let mut best = 0
    for replica in replicas {
      if replica.next_tick() > best {
        best = replica.next_tick()
      }
    }
    best
  }
  let deliver = fn() {
    match network.deliver_one(rng~) {
      None => ()
      Some(message) => {
        counters.deliveries += 1
        let receiver = by_id.get(message.receiver).unwrap()
        let moves_before = receiver.moves().length()
        try {
          match agents.get(message.receiver) {
            Some(agent) => {
              let closed_before = receiver.next_tick()
              for gossip in agent.receive(message.payload) {
                broadcast_gossip(message.receiver, gossip)
              }
              if receiver.next_tick() > closed_before {
                counters.closures += 1
              }
            }
            None =>
              match message.payload {
                DeltaGossip(delta) => receiver.receive(delta)
                CatchupGossip(catchup) => receiver.receive_catchup(catchup)
                ClosureProposalGossip(_) | VoteGossip(_) | BaseVoteGossip(_) =>
                  ()
              }
          }
        } catch {
          error =>
            protocol_errors.push(
              message.receiver + " <- " + message.sender + ": " + error.kind(),
            )
        }
        let moves_after = receiver.moves().length()
        if moves_after > moves_before {
          counters.reissues += moves_after - moves_before
          broadcast(receiver)
        }
      }
    }
  }
  let sync = fn(sender : Replica[S, C, E, R], receiver : Replica[S, C, E, R]) {
    network.send(
      sender.id(),
      receiver.id(),
      CatchupGossip(sender.catchup_since(receiver.digest())),
    )
  }
  for _step in 0..<options.steps {
    match pick_action(rng) {
      Propose => {
        let replica = rng.pick(replicas)
        let tick = leading_tick() + rng.int(options.tick_horizon + 1)
        let _ = replica.propose(tick, generate_command(rng, tick))
        counters.proposals += 1
        broadcast(replica)
      }
      Deliver => deliver()
      Duplicate => if network.duplicate_one(rng) { counters.duplicates += 1 }
      Partition =>
        if !network.partitioned() && replica_count >= 2 {
          let shuffled = rng.shuffle(ids)
          let cut = 1 + rng.int(replica_count - 1)
          network.partition([
            shuffled[0:cut].to_owned(),
            shuffled[cut:].to_owned(),
          ])
          counters.partitions += 1
        }
      Heal =>
        if network.partitioned() {
          network.heal()
          counters.heals += 1
        }
      Close =>
        match mode {
          SingleAuthority(_) => {
            let authority = replicas[0]
            let _ = authority.close_next_tick()
            counters.closures += 1
            broadcast(authority)
          }
          Quorum(_, _, _) => {
            let proposer = rng.pick(replicas)
            let agent = agents.get(proposer.id()).unwrap()
            let gossip = agent.propose_closure()
            if gossip.length() > 0 {
              counters.closure_proposals += 1
            }
            for item in gossip {
              broadcast_gossip(proposer.id(), item)
            }
            let closed_before = proposer.next_tick()
            for item in agent.try_close() {
              broadcast_gossip(proposer.id(), item)
            }
            if proposer.next_tick() > closed_before {
              counters.closures += 1
            }
            for item in agent.certify_head() {
              broadcast_gossip(proposer.id(), item)
            }
          }
        }
      Restart => {
        rng.pick(replicas).restart()
        counters.restarts += 1
      }
      Checkpoint => {
        let _ = rng.pick(replicas).checkpoint()
        counters.checkpoints += 1
      }
      Compact =>
        match options.compaction_retain {
          Some(retain) => {
            rng.pick(replicas).compact(retain_ticks=retain)
            counters.compactions += 1
          }
          None => ()
        }
      AntiEntropy => {
        let sender = rng.pick(replicas)
        let receiver = rng.pick(
          replicas.filter(fn(r) { r.id() != sender.id() }),
        )
        sync(sender, receiver)
        counters.anti_entropy += 1
      }
    }
  }

  // Quiescence: heal, drain, then anti-entropy rounds until nothing changes.
  network.heal()
  while network.pending() > 0 {
    deliver()
  }
  for _round in 0..<(replica_count + 1) {
    for sender in replicas {
      broadcast(sender)
      for receiver in replicas {
        if receiver.id() != sender.id() {
          sync(sender, receiver)
        }
      }
    }
    while network.pending() > 0 {
      deliver()
    }
  }
  // Align compaction so retained history is comparable.
  match options.compaction_retain {
    Some(retain) =>
      for replica in replicas {
        replica.compact(retain_ticks=retain)
      }
    None => ()
  }
  let mut late_total = 0
  for replica in replicas {
    for _, decision in replica.decision().commands {
      if decision is @prdt.DecisionLate(_) {
        late_total += 1
      }
    }
  }
  counters.late_commands = late_total / replica_count
  let state_hashes = replicas.map(fn(r) { r.state_hash() })
  let next_ticks = replicas.map(fn(r) { r.next_tick() })
  let head_decision_hashes = replicas.map(fn(r) {
    r.decision().head_decision_hash()
  })
  let domain_state_hashes = replicas.map(fn(r) {
    @prdt.hash_value(protocol.hasher(), r.domain_state())
  })
  let all_equal = fn(values : Array[String]) {
    values.iter().all(fn(v) { v == values[0] })
  }
  let converged = protocol_errors.length() == 0 &&
    all_equal(state_hashes) &&
    all_equal(head_decision_hashes) &&
    all_equal(domain_state_hashes)
  {
    seed: options.seed,
    counters,
    replica_ids: ids,
    state_hashes,
    next_ticks,
    head_decision_hashes,
    domain_state_hashes,
    converged,
    protocol_errors,
  }
}
