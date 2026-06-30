#!/usr/bin/env bash
# Shared CEC resolution/parsing helpers for the Plasma Machine CEC services.
# Sourced by the cec-* scripts. Nothing is hardcoded: the device node and the
# physical address are read at runtime from cec-ctl, so a GPU-port change is
# picked up on the next boot.
#
# Dependency injection for offline tests:
#   CEC_CTL      - cec-ctl binary (default: cec-ctl)
#   CEC_DEV_GLOB - glob for CEC device nodes (default: /dev/cec*)

CEC_CTL="${CEC_CTL:-cec-ctl}"
CEC_DEV_GLOB="${CEC_DEV_GLOB:-/dev/cec*}"

log() { echo "cec: $*" >&2; }

# Adapter info block for a device; never fails (so callers with set -e/pipefail
# can use it in command substitutions).
_cec_info() { "$CEC_CTL" -d "$1" 2>/dev/null || true; }

_cec_field() {
    # _cec_field <dev> <Field Label>
    _cec_info "$1" | sed -n "s/.*$2[[:space:]]*:[[:space:]]*//p" | head -1 | tr -d '[:space:]'
}

cec_device_driver() { _cec_field "$1" "Driver Name" | tr '[:upper:]' '[:lower:]'; }
cec_device_pa()      { _cec_field "$1" "Physical Address"; }
cec_device_la_mask() { _cec_field "$1" "Logical Address Mask"; }

_pa_valid() { [ -n "$1" ] && [ "$1" != "f.f.f.f" ] && [ "$1" != "0xffff" ]; }

# Print the amdgpu CEC device the TV is on. Prefer one with a valid PA (the TV's
# powered port); else a sole amdgpu device; else fail.
resolve_cec_device() {
    local dev with_pa="" amdgpu_devs=()
    for dev in $CEC_DEV_GLOB; do
        [ -e "$dev" ] || continue
        [ "$(cec_device_driver "$dev")" = "amdgpu" ] || continue
        amdgpu_devs+=("$dev")
        if [ -z "$with_pa" ] && _pa_valid "$(cec_device_pa "$dev")"; then
            with_pa="$dev"
        fi
    done
    if [ -n "$with_pa" ]; then printf '%s\n' "$with_pa"; return 0; fi
    if [ "${#amdgpu_devs[@]}" -eq 1 ]; then printf '%s\n' "${amdgpu_devs[0]}"; return 0; fi
    return 1
}

# Resolve, retrying until a device reports a valid PA (TV may be off at boot).
# After the timeout, fall back to whatever resolve_cec_device returns (sole dev).
resolve_cec_device_wait() {
    local timeout="${1:-60}" interval="${2:-2}" elapsed=0 dev
    while :; do
        if dev="$(resolve_cec_device)" && _pa_valid "$(cec_device_pa "$dev")"; then
            printf '%s\n' "$dev"; return 0
        fi
        if [ "$elapsed" -ge "$timeout" ]; then
            [ -n "${dev:-}" ] && { printf '%s\n' "$dev"; return 0; }
            return 1
        fi
        sleep "$interval"; elapsed=$((elapsed + interval))
    done
}

# Block until the device has claimed a logical address (follower registered).
wait_for_registration() {
    local dev="$1" timeout="${2:-30}" interval="${3:-1}" elapsed=0 mask
    while :; do
        mask="$(cec_device_la_mask "$dev")"
        [ -n "$mask" ] && [ "$mask" != "0x0000" ] && return 0
        [ "$elapsed" -ge "$timeout" ] && return 1
        sleep "$interval"; elapsed=$((elapsed + interval))
    done
}
