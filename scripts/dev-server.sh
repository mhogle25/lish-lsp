#!/bin/sh
# Rebuild lish-lsp (picks up lish source edits too), then exec it, so an LSP
# restart always runs a fresh binary. Build log keeps stdout clean for JSON-RPC;
# on build failure the last good binary runs.
set -e
dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$dir"
zig build > "${TMPDIR:-/tmp}/lish-lsp-build.log" 2>&1 || true
exec "$dir/zig-out/bin/lish-lsp"
