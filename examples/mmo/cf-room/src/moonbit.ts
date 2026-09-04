/**
 * Loader for the MoonBit PRDT bridge (`examples/mmo/src/worker`, package
 * `mizchi/prdt_mmo/worker`, compiled with `moon build --target js --release`
 * into the workspace `_build`). Every bridge function is a pure
 * transformation over JSON strings; this module only adds types.
 */
type BridgeModule = typeof import("../../../../_build/js/release/build/mizchi/prdt_mmo/worker/worker.js");

let bridgeModule: BridgeModule | undefined;

export async function loadBridge(): Promise<BridgeModule> {
  if (bridgeModule === undefined) {
    bridgeModule = await import("../../../../_build/js/release/build/mizchi/prdt_mmo/worker/worker.js");
  }
  return bridgeModule;
}

export type JsonValue = null | boolean | number | string | JsonValue[] | { [key: string]: JsonValue };

export interface BridgeFailure {
  readonly ok: false;
  readonly error: string;
  readonly message: string;
}

export interface BridgeSuccess {
  readonly ok: true;
  readonly snapshot: JsonValue;
  readonly next_tick: number;
  readonly [key: string]: JsonValue;
}

export type BridgeResponse = BridgeSuccess | BridgeFailure;

export function parseResponse(text: string): BridgeResponse {
  return JSON.parse(text) as BridgeResponse;
}

/** A replica identity: the snapshot it persists plus the shared authority secret. */
export interface ReplicaHandle {
  readonly replicaId: string;
  readonly secret: string;
  snapshot: string;
}

async function call(
  handle: ReplicaHandle,
  invoke: (bridge: BridgeModule, snapshot: string) => string,
): Promise<BridgeResponse> {
  const bridge = await loadBridge();
  const response = parseResponse(invoke(bridge, handle.snapshot));
  if (response.ok) handle.snapshot = JSON.stringify(response.snapshot);
  return response;
}

export const replica = {
  propose: (handle: ReplicaHandle, tick: number, command: JsonValue) =>
    call(handle, (bridge, snapshot) =>
      bridge.prdt_mmo_propose(snapshot, handle.secret, handle.replicaId, tick, JSON.stringify(command)),
    ),
  merge: (handle: ReplicaHandle, delta: JsonValue) =>
    call(handle, (bridge, snapshot) => bridge.prdt_mmo_merge(snapshot, handle.secret, handle.replicaId, JSON.stringify(delta))),
  close: (handle: ReplicaHandle) =>
    call(handle, (bridge, snapshot) => bridge.prdt_mmo_close(snapshot, handle.secret, handle.replicaId)),
  decision: (handle: ReplicaHandle) =>
    call(handle, (bridge, snapshot) => bridge.prdt_mmo_decision(snapshot, handle.secret, handle.replicaId)),
  delta: (handle: ReplicaHandle) =>
    call(handle, (bridge, snapshot) => bridge.prdt_mmo_delta(snapshot, handle.secret, handle.replicaId)),
  world: (handle: ReplicaHandle) =>
    call(handle, (bridge, snapshot) => bridge.prdt_mmo_world(snapshot, handle.secret, handle.replicaId)),
  digest: (handle: ReplicaHandle) =>
    call(handle, (bridge, snapshot) => bridge.prdt_mmo_digest(snapshot, handle.secret, handle.replicaId)),
  catchup: (handle: ReplicaHandle, digest: JsonValue) =>
    call(handle, (bridge, snapshot) => bridge.prdt_mmo_catchup(snapshot, handle.secret, handle.replicaId, JSON.stringify(digest))),
  applyCatchup: (handle: ReplicaHandle, catchup: JsonValue) =>
    call(handle, (bridge, snapshot) =>
      bridge.prdt_mmo_apply_catchup(snapshot, handle.secret, handle.replicaId, JSON.stringify(catchup)),
    ),
  compact: (handle: ReplicaHandle, retainTicks: number) =>
    call(handle, (bridge, snapshot) => bridge.prdt_mmo_compact(snapshot, handle.secret, handle.replicaId, retainTicks)),
};
