# Project Agents Guide

ユーザーには日本語で答える。

TDD（探索 → Red → Green → Refactoring）で開発し、関心の分離、状態とロジックの分離、
公開contractの厳密さを優先する。

このリポジトリは `moon.work` ワークスペースで、2 つの MoonBit module を持つ。

- ルート module `mizchi/prdt`（コアのみ。ここに MMO 固有のものを置かない）
  - root package `mizchi/prdt`: PRDT コア（Envelope、canonical hash、lattice、Protocol、snapshot、finalizer）
  - `mizchi/prdt/contracts`: 依存ゼロの純粋関数と Why3/Z3 契約（`moon prove`）
  - `mizchi/prdt/runtime`: PRNG、network、checkpoint store、replica、quorum agent、simulator
- `examples/mmo` の module `mizchi/prdt_mmo`（サンプル。`"mizchi/prdt@0.1.0"` を import し、ワークスペース内ではローカル解決される）
  - root package `mizchi/prdt_mmo`（alias `@mmo`）: MMO サンプルドメイン
  - `mizchi/prdt_mmo/simulation`: simulator の MMO 配線、property / negative / late policy テスト
  - `mizchi/prdt_mmo/worker`: JS / wasm-gc 向け JSON ブリッジ
  - `examples/mmo/cf-room`: Cloudflare Durable Object host（TypeScript）

依存方向は `worker -> mmo -> prdt -> contracts`、`runtime -> prdt`、`simulation -> {mmo, runtime, prdt}` のみ。
`Domain` は protocol を参照してはならない。`alive` のような非単調条件を proposal 時の precondition にしない。

JSON codec は `derive(ToJson, FromJson)` で得る（enum は `style="legacy"` の `$tag` 形式）。
手書きの `impl ToJson` / `impl FromJson` を増やさない。例外は `Digest` / `Signature` / `PublicKey` の newtype だけ。

最終確認ではルートで `moon info && moon fmt`、`moon check --target all`、`moon test` を実行する（両 module を対象にする）。
`src/contracts` を変更した場合は `just prove`（または `just prove-local`）も実行する。
`examples/mmo/src/worker` を変更した場合は `just check-cf-room` と `just test-cf-room` も実行する。
