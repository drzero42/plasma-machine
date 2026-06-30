#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"
. "$here/lib/assert.sh"

export CEC_CTL="$here/stubs/cec-ctl"
export CEC_FIXTURE_DIR="$here/fixtures"
. "$repo/files/system/usr/libexec/plasma-machine/cec-lib.sh"

# --- parsers ---
assert_eq "$(cec_device_driver /dev/cec0)" "amdgpu" "driver parse"
assert_eq "$(cec_device_pa /dev/cec0)" "4.0.0.0" "pa parse"
assert_eq "$(cec_device_la_mask /dev/cec0)" "0x0800" "la mask parse"
assert_eq "$(cec_device_pa /dev/cec1)" "f.f.f.f" "invalid pa parse"

# --- _pa_valid ---
assert_ok   _pa_valid "4.0.0.0"
assert_fail _pa_valid "f.f.f.f"
assert_fail _pa_valid ""

# --- resolve: prefer amdgpu device with a valid PA ---
work="$(mktemp -d)"; mkdir -p "$work/dev"
: > "$work/dev/cec0"; : > "$work/dev/cec1"; : > "$work/dev/cec2"
export CEC_DEV_GLOB="$work/dev/cec*"
assert_eq "$(resolve_cec_device)" "$work/dev/cec0" "resolve prefers valid PA"
# Note: fixtures are keyed by basename, so cec0/1/2 map to cec0/1/2.info.

# --- resolve: sole amdgpu device even without PA (TV off at boot) ---
rm "$work/dev/cec0"   # leaves cec1 (amdgpu invalid) + cec2 (vc4, ignored)
assert_eq "$(resolve_cec_device)" "$work/dev/cec1" "resolve falls back to sole amdgpu"

# --- resolve: nothing amdgpu -> failure ---
rm "$work/dev/cec1"   # leaves only cec2 (vc4)
assert_fail resolve_cec_device

rm -rf "$work"
finish
