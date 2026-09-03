# PRDT による Replicated Domain Object

[`mizchi/prdt`](../README.md) は
[PRDTs: Composable Design and Verification of Consensus Protocols using Replicated Data Types](https://arxiv.org/html/2504.05173v3)
の考え方で、ドメイン固有の状態遷移と分散環境での入力収集・順序確定・複製・合意を分離する
MoonBit 実装である。もともと `mizchi/converge_audit` の中で開発し、独立 module として切り出した。
`Hasher` / `Signer` / `Verifier` trait は converge_audit と同じ形なので adapter は自明である。
コアは実行環境非依存で、[`examples/mmo/cf-room`](../examples/mmo/cf-room/README.md) が
Cloudflare Durable Object 上で JS ブリッジ経由に動かす。

リポジトリは `moon.work` のワークスペースで、ルートの module `mizchi/prdt` にはコア
（protocol・lattice・finalizer・snapshot・runtime・contracts）だけを置き、MMO サンプル・
シミュレーション・JSON ブリッジ・Cloudflare host は `examples/mmo`（module `mizchi/prdt_mmo`）にある。

```text
Pure Domain State Machine
        +
Replicated Finalization Protocol
        =
Replicated Domain Object
```

## 設計判断

### 状態・予測・決定の分離

```text
Knowledge state  ->  Speculative view  ->  Final decision
追記・join可能        rollback可能          後戻り不可
```

確定 decision の半順序は `DecisionPending <= DecisionAccepted`、
`DecisionPending <= DecisionRejected(reason)`、`DecisionPending <= DecisionLate` のみ。
`Accepted -> Rejected` や `Rejected(a) -> Rejected(b)` は存在しない。
`decision_less_or_equal` (`src/laws.mbt`) がこの順序を実行可能に定義し、
property test が `decision(state) <= decision(apply_delta(state, delta))` と
`decision(a) <= decision(join(a, b))` を検証する。

### `alive` を proposal 時の precondition にしない

`hp > 0` は別 replica の並行 Damage で false に変わるため join に対して安定でない。
proposal はそのまま受理し、tick の入力集合と順序が閉じた後に純粋な reducer が
直前状態に対して validate する。`negative_test.mbt` が「pre(s) が成り立つのに
pre(join(s, damage)) が破れる」例と、2 replica が逆の局所判定に至る例を固定している。

### consensus safety と domain validity の分離

PRDT が保証するのは decision の両立可能性・単調性・knowledge の収束・確定ログの prefix safety。
「全 replica が一貫して死亡済み player の skill を Accepted にした」状態は agreement を満たすが
ゲーム規則上は無効なので、`property_test.mbt` が確定ログを走査して
`Accepted(SkillActivated) => HP > 0 かつ MP >= cost (直前状態)` と `HP >= 0` を別途検証する。

## パッケージと責務

```text
Runtime -> PRDT Protocol -> Finalization -> Domain
```

| 性質 | 担当 |
| --- | --- |
| `hp <= 0` なら dead、dead なら skill を reject、event 適用 | `mmo`（`Domain` の実装） |
| batch 内 canonical order、一度だけ Accepted/Rejected に解決 | root package の `resolve_batch` |
| tick の入力集合確定、異なる確定結果への分岐禁止、prefix safety | root package の `ProposalState` / `ClosureMap` / `CommittedLog` / `Protocol` |
| 証明書の真正性（single authority / quorum） | root package の `Finalizer` 実装 |
| gossip、再送、partition、checkpoint、simulation | `runtime`、`mmo/simulation` |
| Durable Object などのホスト向け JSON ブリッジ | `worker` |

## コア型

- `Envelope[C] = { id, tick, submitted_by, local_sequence, command }`、`id = "<replica>:<local_sequence>"`
- `Domain[S, C, E, R] = { initial_state, validate, apply }`（純粋関数のフィールド）
- `CommandOrder[C]`：`canonical_order(phase)` が `(tick, phase, submitted_by, local_sequence, id)` を作る
- `ResolvedBatch`：`previous_state_hash`、`ordered_command_hash`、verdict 列、`resulting_state(_hash)`
- `ProposalState[C]`：tick ごとの `id -> Envelope` grow-only map。同じ id に異なる payload は `ConflictingProposal`
- `ClosureCertificate = { tick, parent_decision_hash, ordered_command_ids, ordered_commands_hash, attestations }`
- `ClosureDecision`：`ClosurePending <= Closed(c)`、`Closed(a) <= Closed(b) iff a == b`
- `CommittedLog[R]`：prefix order。分岐は `PrefixConflict`
- `State = { base, proposals, closures, committed }`。`committed` は `base` 以降の knowledge から決定的に導出され、通信には乗せない
- `Base[S]`：compaction 済み履歴の境界（`next_tick`、decision hash、その時点の domain state）。初期値は genesis
- `KnowledgeDigest` / `Catchup`：digest ベースの差分配信と、compaction で履歴を忘れた peer への base 転送
- hash は `canonicalize(json)`（キーをソートした JSON）の SHA-256。`hash_value` は任意の `ToJson` 値に使える

## 確定の流れ

1. replica が `ReplicatedDomain::propose` で Envelope を作り、`Delta { proposals, closures }` として gossip する
2. finalizer（`ClosureAuthority` または quorum の `Voter` 群）が tick の `ordered_command_ids` を固定した証明書を作る。
   `parent_decision_hash` は直前 tick の確定結果 hash（初回は genesis hash）
3. 各 replica の `Protocol::apply_delta` は証明書を検証し、join し、closed かつ全 command 既知の tick を
   先頭から順に `resolve_batch` で materialize する
4. 証明書の id 順が canonical order と一致しなければ `OrderMismatch`、親 hash が違えば
   `ChainMismatch` として delta ごと拒否する
5. closure 後に届いた command は `DecisionLate(tick)`（`RejectAsLate` policy）。既存 batch は変化しない
6. `Protocol::restore` は snapshot の knowledge から確定 prefix を再計算し、永続化された prefix と
   一致しなければ `SnapshotMismatch` にする
7. `Protocol::compact(retain_ticks~)` は古い batch を base に畳み込み、base 未満の proposal / closure を忘れる。
   verdict は変えないが、compaction 済み tick の command は `decision` に現れなくなる
8. `join` は新しい方の base を採用し、相手の確定 prefix が base と矛盾すれば `PrefixConflict` にする
9. base は `BaseCertificate` 付きでしか採用しない。single authority は closure のたびに head を署名し
   （`certify_base`）、quorum は各 replica が `BaseVote` を署名して過半数で証明書を組み立てる。
   `compact` は証明済み境界にしか進まず、`apply_catchup` は証明書が無い・検証できない・base と一致しない
   場合に `UnauthenticatedBase` で拒否する

### Late command policy（runtime）

`Replica` の `LateCommandPolicy` が `MoveToNextTick(max_moves~)` のとき、自分の command が `DecisionLate` に
なったら、閉じていると知らない最も早い tick に新しい envelope id で再提案する（系譜ごとに最大 `max_moves` 回）。
移動台帳は checkpoint に含まれ、restart しても二重に再提案しない。元の command は永久に `DecisionLate` のまま。

### 証明（`prdt/contracts`）

依存ゼロの `contracts` に純粋関数と `.mbtp` 契約を置き、`moon prove src/contracts` が Why3/Z3 で
19 ゴールを discharge する。quorum の交差性と一意性、compaction の算術（retention window の保持・確定 frontier
の不変）、decision order（反射・反対称・推移・Pending が底・確定は不変）、vote slot join（冪等・可換・
equivocation 吸収）。実行コードはこれらの関数を呼ぶ（`QuorumRoster::new`、`Protocol::compact`、
`decision_less_or_equal`）。generic な lattice 全体の法則は seed 付き property test で確認する

### Quorum runtime

`runtime/QuorumAgent` は任意の replica が次の tick の closure を提案し、投票者は
「自分の next tick を対象とし、自分の head から連鎖し、既知の command のみを canonical order で並べた」
最初の提案に 1 tick 1 票で署名する。過半数を集めた replica が証明書を組み立てて delta として gossip する。
証明書の同一性は payload（tick・親 hash・id 列）で定義し、attestation の組み合わせが違っても同じ決定とみなす。
安全性は投票 lattice と過半数 threshold から従う。liveness は best effort（leader election や view change は無い）

### JSON エンコーディング

転送・永続化される型（`Envelope`・`Delta`・各証明書・投票・`KnowledgeDigest`・`Catchup`・
`Snapshot`・`ReplicatedSnapshot`、MMO の command / event / world）はすべて
`derive(ToJson, FromJson)` で codec を得る。手書きの codec は `Digest` / `Signature` / `PublicKey` の
3 つの newtype だけで、これらは素の文字列として流れる。enum は `style="legacy"` で
`{"$tag": "<Constructor>", ...ラベル付きフィールド}`、`Option` フィールドは `None` のとき省略
（`null` は不正）、`Map[String, _]` はオブジェクトになる。hash は必ず `canonical_json`
（キーを再帰的にソート）を通すので、エンコード時のキー順に依存しない。decode 失敗は
`SnapshotMismatch` に JSON path 付きで報告される。

## 検証

| 種別 | 内容 | 場所 |
| --- | --- | --- |
| Unit | canonical JSON / SHA-256 / MAC、lattice 各種、closure 重複、prefix、resolve_batch、MMO ドメイン規則、致死 race の両到着順、late command、証明書偽造・不正形・親不一致・非 canonical 順、snapshot 復元と改竄検出、quorum と equivocation | `src/*_test.mbt`、`examples/mmo/src/*_test.mbt` |
| Property（seed 生成） | lattice laws、配送順・重複・merge-tree 不変、snapshot 往復、decision monotonicity、closure uniqueness、prefix safety、late の最終性、domain validity | `examples/mmo/src/simulation/property_test.mbt` |
| Simulation | reorder / duplicate / partition / heal / restart / 証明付き compaction + 状態転送 / digest 同期、single authority と quorum（3・5 replica、equivocating voter あり）、`MoveToNextTick`、seed ごとの収束と再現性 | `examples/mmo/src/simulation/simulation_test.mbt`、`late_policy_test.mbt` |
| Proof | quorum 閾値、compaction 算術、decision order、vote slot join | `src/contracts`（`just prove`） |
| Negative | unstable alive guard、premature acceptance | `examples/mmo/src/simulation/negative_test.mbt` |
| Bridge / Worker | JSON 文字列ブリッジ、digest 同期と証明付き base 転送、workerd 上の Durable Object 経由で client replica が収束 | `examples/mmo/src/worker/bridge_test.mbt`、`examples/mmo/cf-room/test` |

```sh
just check
just test
just prove
just test-cf-room
```

## 未実装・非目標

- Byzantine 耐性（quorum の equivocation 除外以外）
- quorum の liveness（leader election、view change、再投票）
- generic な lattice 全体の証明（抽象化した kind のみ証明済み）
- entity/zone sharding、cross-scope transaction
- 本物の署名（同梱の `SharedSecretAuthenticator` は HMAC。root の `Signer` / `Verifier` trait で差し替える）
