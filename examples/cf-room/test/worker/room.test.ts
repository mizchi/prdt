import { SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { replica, type JsonValue, type ReplicaHandle } from "../../src/moonbit.ts";

const BASE = "https://example.com/rooms/lethal-race";
const SECRET = "dev-only-secret";
const PLAYER_A = "player-a";
const FIREBALL = { type: "UseSkill", actor: PLAYER_A, skill: "fireball", mp_cost: 30 };
const LETHAL_HIT = { type: "Damage", source: "monster", target: PLAYER_A, amount: 20 };

async function call(path: string, init?: RequestInit): Promise<{ status: number; body: any }> {
  const response = await SELF.fetch(`${BASE}${path}`, init);
  return { status: response.status, body: await response.json() };
}

function post(path: string, body: JsonValue): Promise<{ status: number; body: any }> {
  return call(path, { method: "POST", body: JSON.stringify(body), headers: { "content-type": "application/json" } });
}

function expectOk<T extends { ok: boolean }>(response: T): T & { ok: true } {
  expect(response.ok, JSON.stringify(response)).toBe(true);
  return response as T & { ok: true };
}

describe("PrdtRoom Durable Object over the MoonBit bridge", () => {
  it("resolves the lethal-race scenario through HTTP and lets a client replica converge", async () => {
    // Client replica X runs the same MoonBit protocol locally.
    const x: ReplicaHandle = { replicaId: "X", secret: SECRET, snapshot: "" };
    const proposed = expectOk(await replica.propose(x, 0, FIREBALL));

    expect((await post("/delta", proposed.delta!)).status).toBe(200);
    const authorityProposal = await post("/propose", { tick: 0, command: LETHAL_HIT });
    expect(authorityProposal.status).toBe(200);
    expect(authorityProposal.body.decision.commands["X:0"]).toEqual({ status: "Pending" });

    const closed = await post("/close", {});
    expect(closed.status).toBe(200);
    expect(closed.body.certificate.ordered_command_ids).toEqual(["authority:0", "X:0"]);

    const decision = await call("/decision");
    expect(decision.body.decision).toMatchObject({
      committed_ticks: [0],
      commands: {
        "authority:0": { status: "Accepted", event: { type: "DamageApplied", target: PLAYER_A } },
        "X:0": { status: "Rejected", reason: { type: "ActorDead" } },
      },
    });
    const world = await call("/world");
    expect(world.body).toMatchObject({ next_tick: 1, world: { players: [[PLAYER_A, { hp: 0, mp: 100 }]] } });

    // Anti-entropy: X pulls the authority's full knowledge and reaches the same verdicts.
    const full = await call("/delta");
    expectOk(await replica.merge(x, full.body.delta as JsonValue));
    const xDecision = expectOk(await replica.decision(x));
    expect((xDecision.decision as any).commands["X:0"]).toEqual({ status: "Rejected", tick: 0, reason: { type: "ActorDead" } });
    const xWorld = expectOk(await replica.world(x));
    expect(xWorld.state_hash).toBe(world.body.state_hash);
  });

  it("syncs a fresh client by digest after the room compacted to a certified base", async () => {
    const base = "https://example.com/rooms/compacted";
    const postTo = (path: string, body: JsonValue) =>
      SELF.fetch(`${base}${path}`, { method: "POST", body: JSON.stringify(body), headers: { "content-type": "application/json" } });
    expect((await postTo("/propose", { tick: 0, command: LETHAL_HIT })).status).toBe(200);
    for (let i = 0; i < 3; i += 1) expect((await postTo("/close", {})).status).toBe(200);
    const compacted = (await (await postTo("/compact", { retain_ticks: 0 })).json()) as { base_next_tick: number };
    expect(compacted).toMatchObject({ base_next_tick: 3 });

    const client: ReplicaHandle = { replicaId: "C", secret: SECRET, snapshot: "" };
    const digest = expectOk(await replica.digest(client)).digest as JsonValue;
    const synced = (await (await postTo("/sync", digest)).json()) as { catchup: JsonValue };
    expectOk(await replica.applyCatchup(client, synced.catchup as JsonValue));
    const world = expectOk(await replica.world(client));
    expect(world.next_tick).toBe(3);
    const roomWorld = (await (await SELF.fetch(`${base}/world`)).json()) as { state_hash: string };
    expect(world.state_hash).toBe(roomWorld.state_hash);

    // Without the certificate the base is refused.
    const stripped = { ...(synced.catchup as { [key: string]: JsonValue }), certificate: null };
    const fresh: ReplicaHandle = { replicaId: "D", secret: SECRET, snapshot: "" };
    const refused = await replica.applyCatchup(fresh, stripped);
    expect(refused.ok).toBe(false);
    expect((refused as { error: string }).error).toBe("UnauthenticatedBase");
  });

  it("refuses a conflicting payload for a known command id", async () => {
    const y: ReplicaHandle = { replicaId: "Y", secret: SECRET, snapshot: "" };
    const proposed = expectOk(await replica.propose(y, 5, FIREBALL));
    expect((await post("/delta", proposed.delta!)).status).toBe(200);
    const envelope = proposed.envelope as { [key: string]: JsonValue };
    const conflicting = { proposals: [{ ...envelope, command: LETHAL_HIT }], closures: [] };
    const response = await post("/delta", conflicting);
    expect(response.status).toBe(409);
    expect(response.body).toMatchObject({ error: "ConflictingProposal" });
  });
});
