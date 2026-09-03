# cf-room (Cloudflare host)

Cloudflare Workers host for the MoonBit package
[`mizchi/prdt`](../../README.md): one Durable Object
per room runs the single-authority replica of the MMO sample.

All protocol logic (domain reducer, proposal/closure/committed lattices,
finalizers, snapshots) is MoonBit. This directory only:

- loads the bridge compiled by `moon build --target js --release`
  (`src/moonbit.ts`),
- persists the replica snapshot in Durable Object storage and maps HTTP to
  the bridge (`src/worker.ts`),
- tests the room end to end inside `workerd` with a client replica that runs
  the same MoonBit bridge (`test/worker/room.test.ts`).

## Routes

All under `/rooms/:room`:

| Route | Body | Result |
| --- | --- | --- |
| `POST /propose` | `{ tick, command }` | envelope, delta to gossip, decision |
| `POST /delta` | `Delta` JSON | decision after merge (409 on a protocol conflict) |
| `GET /delta` | | full knowledge, for anti-entropy |
| `POST /sync` | `KnowledgeDigest` | only what the caller is missing, plus the room's certified base |
| `POST /close` | | closure certificate for the next tick and a base certificate for the new head |
| `POST /compact` | `{ retain_ticks }` | fold history into a certified base |
| `GET /decision` | | `Pending / Accepted / Rejected / RejectedLate` per command |
| `GET /world` | | domain state and replicated state hash |

The dev authority is a shared-secret MAC (`AUTHORITY_SECRET` in
`wrangler.jsonc`). Replace it with a real signer behind the MoonBit `Signer` /
`Verifier` traits before deploying anything that matters.

## Commands

```sh
pnpm install
pnpm typecheck     # builds the MoonBit JS bundle first
pnpm test          # workerd Durable Object test
pnpm dev
pnpm deploy:dry
```
