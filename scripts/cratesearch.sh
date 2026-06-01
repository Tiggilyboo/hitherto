#!/usr/bin/env bash
# Search Rust crate sources with line numbers.
# Usage: cratesearch.sh [-n LIMIT] <crate-name> <search-pattern>

set -euo pipefail

LIMIT=50
while getopts "n:" opt; do
  case "$opt" in
    n) LIMIT="$OPTARG" ;;
    *) echo "Usage: cratesearch.sh [-n LIMIT] <crate-name> <search-pattern>" >&2; exit 1 ;;
  esac
done
shift $((OPTIND - 1))

CRATE="${1:?Usage: cratesearch.sh [-n LIMIT] <crate-name> <search-pattern>}"
PATTERN="${2:?Usage: cratesearch.sh [-n LIMIT] <crate-name> <search-pattern>}"

shopt -s nullglob
DIRS=(~/.cargo/registry/src/index.crates.io-*/${CRATE}-*/)
shopt -u nullglob

if [ ${#DIRS[@]} -eq 0 ]; then
  echo "Error: crate '$CRATE' not found in registry" >&2
  exit 1
fi

DIR="${DIRS[0]}"

OUTPUT=$(rg -n --no-heading "$PATTERN" "$DIR/src" | sed "s|^$DIR/||" || true)

if [ -z "$OUTPUT" ]; then
  exit 0
fi

TOTAL=$(printf '%s\n' "$OUTPUT" | wc -l)
printf '%s\n' "$OUTPUT" | head -n "$LIMIT" || true

if [ "$TOTAL" -gt "$LIMIT" ]; then
  echo "... and $((TOTAL - LIMIT)) more results (use -n to increase limit)"
fi
