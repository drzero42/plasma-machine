#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"
. "$here/lib/assert.sh"

work="$(mktemp -d)"; mkdir -p "$work/dev"; : > "$work/dev/cec0"
export CEC_CTL="$here/stubs/cec-ctl"
export CEC_FIXTURE_DIR="$here/fixtures"
export CEC_DEV_GLOB="$work/dev/cec*"
export CEC_FOLLOWER="$here/stubs/cec-follower"
export FOLLOWER_CALLS="$work/follower.calls"

bash "$repo/files/system/usr/libexec/plasma-machine/cec-follower-start"
calls="$(cat "$work/follower.calls" 2>/dev/null || echo MISSING)"
assert_contains "$calls" "-d $work/dev/cec0" "follower started on resolved device"

rm -rf "$work"
finish
