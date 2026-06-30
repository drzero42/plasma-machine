#!/usr/bin/env bash
# Run every *.test.sh in this directory; exit non-zero if any fail.
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rc=0
for t in "$here"/*.test.sh; do
    echo "== $(basename "$t")"
    bash "$t" || rc=1
done
exit "$rc"
