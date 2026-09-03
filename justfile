# mizchi/prdt task runner

# Type-check every target
check:
  moon check --target all

# Run all MoonBit tests of both workspace members (unit, seeded properties, simulations, bridge)
test:
  moon test

# Run only the MMO sample tests (examples/mmo)
test-mmo:
  cd examples/mmo && moon test

# Run tests with verbose output
test-v:
  moon test -v

# Format code
fmt:
  moon fmt

# Regenerate public interfaces
info:
  moon info

# Build the wasm-gc target
build:
  moon build --target wasm-gc

# Build the JS bridge consumed by examples/mmo/cf-room (output: _build/js/release/build/mizchi/prdt_mmo/worker/worker.js)
build-js:
  cd examples/mmo && moon build --target js --release

# Discharge the Why3/Z3 contracts of src/contracts (uses the nix dev shell)
prove:
  nix develop path:. --command moon prove src/contracts

# Same as `prove` with an already installed why3 + z3 (Debian/Ubuntu layout)
prove-local:
  WHY3DATA=/usr/share/why3 WHY3LIB=/usr/lib/ocaml/why3 Z3PATH=/usr/bin/z3 moon prove src/contracts

# Run a seeded three-replica simulation report (moon test prints on failure only)
simulate seed="1":
  cd examples/mmo && moon test src/simulation -v

# Install the Cloudflare host
install-cf-room:
  pnpm --dir examples/mmo/cf-room install --frozen-lockfile

# Type-check the Cloudflare host (builds the JS bridge first)
check-cf-room:
  pnpm --dir examples/mmo/cf-room typecheck

# Run the workerd Durable Object tests
test-cf-room:
  pnpm --dir examples/mmo/cf-room test

# Validate the Worker deploy bundle without mutating Cloudflare
build-cf-room:
  pnpm --dir examples/mmo/cf-room deploy:dry

# Start the Worker locally
dev-cf-room:
  pnpm --dir examples/mmo/cf-room dev

# Everything CI runs
ci: fmt info check test build prove check-cf-room test-cf-room build-cf-room
