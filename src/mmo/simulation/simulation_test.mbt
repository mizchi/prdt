///|
fn assert_converged(report : @runtime.SimulationReport) -> Unit raise Error {
  assert_eq(report.protocol_errors, [])
  assert_true(report.converged)
  assert_true(
    report.state_hashes.iter().all(fn(h) { h == report.state_hashes[0] }),
  )
  assert_true(report.next_ticks.iter().all(fn(t) { t == report.next_ticks[0] }))
}

///|
test "single authority: three replicas converge after reorder, duplication, partition, and restart" {
  let mut partitions = 0
  let mut duplicates = 0
  let mut restarts = 0
  let mut closures = 0
  let mut late = 0
  for seed in 1..<=40 {
    let report = run_mmo_simulation(seed~)
    assert_converged(report)
    partitions += report.counters.partitions
    duplicates += report.counters.duplicates
    restarts += report.counters.restarts
    closures += report.counters.closures
    late += report.counters.late_commands
  }
  assert_true(partitions > 0)
  assert_true(duplicates > 0)
  assert_true(restarts > 0)
  assert_true(closures > 0)
  assert_true(late > 0)
}

///|
test "single authority with compaction and state transfer still converges" {
  let mut compactions = 0
  for seed in 1..<=30 {
    let report = run_mmo_simulation(seed~, compaction_retain=2)
    assert_converged(report)
    compactions += report.counters.compactions
  }
  assert_true(compactions > 0)
}

///|
test "quorum: replicas close ticks by majority vote and converge" {
  let mut closures = 0
  for seed in 1..<=30 {
    let report = run_mmo_quorum_simulation(seed~)
    assert_converged(report)
    closures += report.counters.closures
  }
  assert_true(closures > 0)
}

///|
test "quorum with an equivocating voter stays safe and still makes progress" {
  let mut closures = 0
  for seed in 1..<=30 {
    let report = run_mmo_quorum_simulation(
      seed~,
      equivocators=[1],
      compaction_retain=3,
    )
    assert_converged(report)
    closures += report.counters.closures
  }
  assert_true(closures > 0)
}

///|
test "quorum with five replicas and one equivocator converges" {
  for seed in 1..<=10 {
    let report = run_mmo_quorum_simulation(
      seed~,
      replica_count=5,
      equivocators=[2],
      steps=500,
    )
    assert_converged(report)
  }
}

///|
test "simulation is reproducible by seed" {
  assert_eq(run_mmo_simulation(seed=7), run_mmo_simulation(seed=7))
  assert_eq(
    run_mmo_quorum_simulation(seed=7),
    run_mmo_quorum_simulation(seed=7),
  )
}
