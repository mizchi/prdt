# Project Agents Guide

ユーザーには日本語で答える。

TDD（探索 → Red → Green → Refactoring）で開発し、関心の分離、状態とロジックの分離、
公開contractの厳密さを優先する。

このリポジトリはMoonBit module `mizchi/prdt` である。

- root package `mizchi/prdt`: PRDT コア（Envelope、canonical hash、lattice、Protocol、finalizer）
- `mizchi/prdt/contracts`: 依存ゼロの純粋関数と Why3/Z3 契約（`moon prove`）
- `mizchi/prdt/mmo`: MMO サンプルドメイン
- `mizchi/prdt/runtime`: PRNG、network、replica、quorum agent、simulator
- `mizchi/prdt/mmo/simulation`: simulator の MMO 配線、property / negative / late policy テスト
- `mizchi/prdt/worker`: JS / wasm-gc 向け JSON ブリッジ
- `examples/cf-room`: Cloudflare Durable Object host（TypeScript）

依存方向は `worker -> mmo -> prdt -> contracts`、`runtime -> prdt`、`mmo/simulation -> {mmo, runtime, prdt}` のみ。
`Domain` は protocol を参照してはならない。`alive` のような非単調条件を proposal 時の precondition にしない。

最終確認では `moon info && moon fmt`、`moon check --target all`、`moon test` を実行する。
`src/contracts` を変更した場合は `just prove`（または `just prove-local`）も実行する。
`src/worker` を変更した場合は `just check-cf-room` と `just test-cf-room` も実行する。
