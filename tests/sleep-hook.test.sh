#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"
. "$here/lib/assert.sh"
hook="$repo/files/system/usr/lib/systemd/system-sleep/50-cec-tv-on"

work="$(mktemp -d)"
# A systemctl stub that records its args.
cat > "$work/systemctl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$work/sysctl.calls"
EOF
chmod +x "$work/systemctl"
export SYSTEMCTL="$work/systemctl"

bash "$hook" post suspend
bash "$hook" pre suspend
calls="$(cat "$work/sysctl.calls" 2>/dev/null || echo MISSING)"
assert_contains "$calls" "restart cec-tv-on.service" "resume triggers tv-on"
# 'pre' must not trigger it: exactly one restart line.
assert_eq "$(grep -c restart "$work/sysctl.calls")" "1" "only post triggers tv-on"

rm -rf "$work"
finish
