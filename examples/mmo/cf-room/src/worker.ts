/**
 * Cloudflare Workers adapter: one Durable Object per room hosts the
 * single-authority replica of the MMO sample. All protocol logic lives in
 * the MoonBit packages `mizchi/prdt` (core) and `mizchi/prdt_mmo` (domain
 * and bridge); this file only persists the snapshot and maps HTTP to the
 * bridge. Enums cross the wire as `{"$tag": "<Constructor>", ...fields}`.
 *
 * Routes (all under /rooms/:room):
 *   POST /propose   { tick, command }  -> { envelope, delta, decision, next_tick }
 *   POST /delta     Delta JSON         -> { decision, next_tick }
 *   GET  /delta                        -> { delta }  (full knowledge, for anti-entropy)
 *   POST /sync      KnowledgeDigest    -> { catchup }  (only what the caller is missing, plus a certified base)
 *   POST /close                        -> { certificate, base_certificate, delta, decision }
 *   POST /compact   { retain_ticks }   -> { base_next_tick }
 *   GET  /decision                     -> { decision }
 *   GET  /world                        -> { world, state_hash, next_tick }
 */
import { DurableObject } from "cloudflare:workers";
import { replica, type BridgeResponse, type JsonValue, type ReplicaHandle } from "./moonbit.ts";

export interface Env {
  readonly PRDT_ROOM: DurableObjectNamespace<PrdtRoom>;
  /** Shared-secret MAC key for the dev authority. Replace with a real signer for deployments. */
  readonly AUTHORITY_SECRET?: string;
}

const SNAPSHOT_KEY = "prdt/snapshot";

export class PrdtRoom extends DurableObject<Env> {
  #handle: Promise<ReplicaHandle> | undefined;

  #open(): Promise<ReplicaHandle> {
    if (this.#handle === undefined) {
      this.#handle = (async () => ({
        replicaId: "authority",
        secret: this.env.AUTHORITY_SECRET ?? "dev-only-secret",
        snapshot: (await this.ctx.storage.get<string>(SNAPSHOT_KEY)) ?? "",
      }))();
    }
    return this.#handle;
  }

  async #respond(handle: ReplicaHandle, response: BridgeResponse, persist: boolean): Promise<Response> {
    if (!response.ok) {
      const status = response.error === "SnapshotMismatch" || response.error === "InvalidTick" ? 400 : 409;
      return json({ error: response.error, message: response.message }, status);
    }
    if (persist) await this.ctx.storage.put(SNAPSHOT_KEY, handle.snapshot);
    const { ok: _ok, snapshot: _snapshot, ...rest } = response;
    return json(rest);
  }

  override async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const handle = await this.#open();
    switch (`${request.method} ${url.pathname}`) {
      case "POST /propose": {
        const body = (await request.json()) as { tick?: unknown; command?: JsonValue };
        if (typeof body.tick !== "number" || body.command === undefined) {
          return json({ error: "bad request", message: "expected { tick, command }" }, 400);
        }
        return this.#respond(handle, await replica.propose(handle, body.tick, body.command), true);
      }
      case "POST /delta":
        return this.#respond(handle, await replica.merge(handle, (await request.json()) as JsonValue), true);
      case "GET /delta":
        return this.#respond(handle, await replica.delta(handle), false);
      case "POST /sync":
        return this.#respond(handle, await replica.catchup(handle, (await request.json()) as JsonValue), false);
      case "POST /compact": {
        const body = (await request.json()) as { retain_ticks?: unknown };
        if (typeof body.retain_ticks !== "number") {
          return json({ error: "bad request", message: "expected { retain_ticks }" }, 400);
        }
        return this.#respond(handle, await replica.compact(handle, body.retain_ticks), true);
      }
      case "POST /close":
        return this.#respond(handle, await replica.close(handle), true);
      case "GET /decision":
        return this.#respond(handle, await replica.decision(handle), false);
      case "GET /world":
        return this.#respond(handle, await replica.world(handle), false);
      default:
        return json({ error: "not found" }, 404);
    }
  }
}

function json(value: unknown, status = 200): Response {
  return new Response(JSON.stringify(value), { status, headers: { "content-type": "application/json" } });
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const match = /^\/rooms\/([^/]+)(\/.*)$/.exec(url.pathname);
    if (match === null) return json({ error: "expected /rooms/:room/<route>" }, 404);
    const [, room, rest] = match;
    const stub = env.PRDT_ROOM.get(env.PRDT_ROOM.idFromName(room!));
    const forwarded = new URL(request.url);
    forwarded.pathname = rest!;
    // Buffer the body so the object never has to read a stream after the outer response was sent.
    const body = request.method === "GET" || request.method === "HEAD" ? null : await request.arrayBuffer();
    return stub.fetch(new Request(forwarded, { method: request.method, headers: request.headers, body }));
  },
} satisfies ExportedHandler<Env>;
