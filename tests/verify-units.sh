#!/usr/bin/env bash
# Validate unit files with systemd-analyze. Rewrites the image install paths to
# the in-repo source paths (and ensures scripts are executable) so the ExecStart/
# ExecStop existence check passes off-device. Verifies all units together so
# cross-references (After=cec-follower.service) resolve.
set -u
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
chmod +x "$repo"/files/system/usr/libexec/plasma-machine/* 2>/dev/null
chmod +x "$repo"/files/system/usr/lib/systemd/system-sleep/* 2>/dev/null
for u in "$repo"/files/system/usr/lib/systemd/system/*.service; do
    [ -e "$u" ] || continue
    sed -e "s#/usr/libexec/plasma-machine#$repo/files/system/usr/libexec/plasma-machine#g" \
        "$u" > "$tmp/$(basename "$u")"
done
echo "verifying: $(ls "$tmp")"
systemd-analyze verify "$tmp"/*.service
rc=$?
rm -rf "$tmp"
exit "$rc"
