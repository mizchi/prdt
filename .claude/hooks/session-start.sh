#!/bin/bash
# SessionStart hook for Claude Code on the web.
# Installs the MoonBit toolchain pinned by CI, resolves MoonBit dependencies,
# and installs the pnpm workspaces of the TypeScript examples so that
# `moon check`, `moon test`, and the example test suites run in a fresh session.
set -euo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

cd "$CLAUDE_PROJECT_DIR"

# Keep the toolchain in lockstep with .github/workflows/ci.yml.
MOONBIT_VERSION="$(grep -m1 -oE 'core-version: *[^ ]+' .github/workflows/ci.yml | awk '{print $2}')"
if [ -z "$MOONBIT_VERSION" ]; then
  echo "session-start: could not read the MoonBit version from ci.yml" >&2
  exit 1
fi

export PATH="$HOME/.moon/bin:$PATH"
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  echo 'export PATH="$HOME/.moon/bin:$PATH"' >> "$CLAUDE_ENV_FILE"
fi

installed_version="$(moonc -v 2>/dev/null | awk '{print $1}' | sed 's/^v//' || true)"
if [ "$installed_version" != "$MOONBIT_VERSION" ]; then
  echo "session-start: installing MoonBit $MOONBIT_VERSION (found: ${installed_version:-none})"
  curl -fsSL https://cli.moonbitlang.com/install/unix.sh | bash -s -- "$MOONBIT_VERSION"
else
  echo "session-start: MoonBit $MOONBIT_VERSION already installed"
fi
moon version --all

# MoonBit registry dependencies (mizchi/experimental_crypto).
moon update
moon install

# Proof toolchain for `moon prove` (Why3 + Z3). Best effort: the MoonBit
# contracts still check and test without it.
if ! command -v why3 >/dev/null 2>&1 || ! command -v z3 >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    echo "session-start: installing why3 and z3"
    (apt-get install -y why3 z3 >/dev/null 2>&1 || (apt-get update >/dev/null 2>&1 && apt-get install -y why3 z3 >/dev/null 2>&1)) || \
      echo "session-start: could not install why3/z3; moon prove will be unavailable" >&2
  fi
fi
if command -v why3 >/dev/null 2>&1 && [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  why3_lib="$(dirname "$(find / -type d -name why3 -path '*lib*' -not -path '*share*' 2>/dev/null | head -1)")/why3"
  {
    echo 'export WHY3DATA="/usr/share/why3"'
    echo "export WHY3LIB=\"$why3_lib\""
    echo 'export Z3PATH="/usr/bin/z3"'
  } >> "$CLAUDE_ENV_FILE"
fi

# TypeScript example workspaces with lockfiles.
for dir in examples/cf-room; do
  if [ -f "$dir/pnpm-lock.yaml" ]; then
    echo "session-start: pnpm install in $dir"
    pnpm --dir "$dir" install --frozen-lockfile
  fi
done

echo "session-start: done"
