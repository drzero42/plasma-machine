#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"
. "$here/lib/assert.sh"

export CEC_TEST_SOURCE=1
export CEC_CTL="$here/stubs/cec-ctl"
. "$repo/files/system/usr/libexec/plasma-machine/cec-suspend-on-tv-off"

# --- handle_line: only TV-sourced STANDBY matches ---
assert_ok   handle_line "    TV to all (0 to 15): STANDBY (0x36)"
assert_fail handle_line "    Audio System to all (5 to 15): STANDBY (0x36)"
assert_fail handle_line "    TV to all (0 to 15): DEVICE_VENDOR_ID (0x87)"
assert_fail handle_line "    Playback Device 1 to all (4 to 15): DEVICE_VENDOR_ID"

# --- monitor_once: TV standby in the stream -> systemctl suspend ---
work="$(mktemp -d)"
cat > "$work/systemctl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$work/sysctl.calls"
EOF
chmod +x "$work/systemctl"
export SYSTEMCTL="$work/systemctl"

export CEC_MONITOR_FIXTURE="$here/fixtures/monitor-standby.txt"
monitor_once /dev/cec0
assert_contains "$(cat "$work/sysctl.calls" 2>/dev/null || echo MISSING)" "suspend" "suspends on TV standby"

: > "$work/sysctl.calls"
export CEC_MONITOR_FIXTURE="$here/fixtures/monitor-nostandby.txt"
monitor_once /dev/cec0
assert_eq "$(cat "$work/sysctl.calls" 2>/dev/null || true)" "" "no suspend without TV standby"

rm -rf "$work"
finish
