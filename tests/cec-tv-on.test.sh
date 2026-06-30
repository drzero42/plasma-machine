#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"
. "$here/lib/assert.sh"

work="$(mktemp -d)"; mkdir -p "$work/dev"; : > "$work/dev/cec0"
export CEC_CTL="$here/stubs/cec-ctl"
export CEC_FIXTURE_DIR="$here/fixtures"
export CEC_DEV_GLOB="$work/dev/cec*"
export CEC_CALLS="$work/cec.calls"

bash "$repo/files/system/usr/libexec/plasma-machine/cec-tv-on"
calls="$(cat "$work/cec.calls" 2>/dev/null || echo MISSING)"
assert_contains "$calls" "--image-view-on"            "tv-on wakes the TV"
assert_contains "$calls" "--active-source"            "tv-on sets active source"
assert_contains "$calls" "phys-addr=4.0.0.0"          "tv-on uses resolved PA"

rm -rf "$work"
finish
