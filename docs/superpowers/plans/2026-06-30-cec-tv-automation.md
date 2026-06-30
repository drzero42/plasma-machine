# HDMI-CEC TV Automation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bake root systemd services into the Plasma Machine image so the booted PC drives the TV over HDMI-CEC — wake + input-switch on startup/resume, standby on shutdown, stay registered on the bus, and optionally suspend the PC when the TV turns off.

**Architecture:** A single long-running `cec-follower` owns the CEC adapter's logical-address config; short `cec-ctl` transmits (tv-on/tv-standby) and a passive `cec-ctl --monitor` reader (suspend) coexist without reconfiguring it. All hardware specifics (device node, physical address) are resolved at runtime from `cec-ctl` output by a shared shell library — nothing is hardcoded, so a GPU-port change re-resolves on next boot. Files ship via the existing BlueBuild `files` module; a new `systemd` module enables them.

**Tech Stack:** Bash, systemd units + `systemd-sleep` hook, v4l-utils (`cec-ctl`, `cec-follower`), BlueBuild recipe modules. Offline tests are plain Bash with injected command stubs.

## Global Constraints

- **No AI attribution** in commits/PRs (user global rule): plain messages, no `Co-Authored-By` / "Generated with" trailers.
- **Atomic/immutable OS:** all OS changes go through the image. Never hand-edit `/usr` on the box as a persistent fix.
- **Shared pipeline:** `recipes/modules.yml` is included by both `recipe.yml` (stable) and `recipe-testing.yml` (testing) — every change lands on both channels.
- **All services run as root; no unit or script references a username.**
- **No hardcoded hardware values:** never bake in `/dev/cec0`, PA `4.0.0.0`, `DP-3`, card 1, connector 129, or LA `0x0800`. Resolve at runtime.
- **`v4l-utils` is already in the `bazzite-deck` base — do NOT add a `dnf` layer for it** (re-layering a base package can error under rpm-ostree). Document the dependency only.
- **Script install path:** `/usr/libexec/plasma-machine/` (source: `files/system/usr/libexec/plasma-machine/`). Commit scripts with the exec bit so `COPY` preserves it.
- **Unit install path:** `/usr/lib/systemd/system/` (source: `files/system/usr/lib/systemd/system/`). Sleep hook: `/usr/lib/systemd/system-sleep/` (source: `files/system/usr/lib/systemd/system-sleep/`).
- **Local tooling available:** `shellcheck`, `bash 5`, `systemd-analyze verify`. **Not** available: `yamllint`, `bb` (BlueBuild validates the recipe in CI).
- **No CEC hardware in CI/dev** — runtime CEC behavior is validated on-device by the maintainer per the spec's checklist. Offline tests cover only parsing/resolution/arg-construction via stubs.

Spec: `docs/superpowers/specs/2026-06-30-cec-tv-automation-design.md`.

## File Structure

Created:
- `files/system/usr/libexec/plasma-machine/cec-lib.sh` — sourced helpers: resolve device, parse PA / driver / LA mask, wait helpers. The only file with real branching logic.
- `files/system/usr/libexec/plasma-machine/cec-follower-start` — resolve device → `exec cec-follower`.
- `files/system/usr/libexec/plasma-machine/cec-tv-on` — wake TV + set active source.
- `files/system/usr/libexec/plasma-machine/cec-tv-standby` — send TV standby.
- `files/system/usr/libexec/plasma-machine/cec-suspend-on-tv-off` — monitor for TV standby → suspend.
- `files/system/usr/lib/systemd/system-sleep/50-cec-tv-on` — re-run tv-on on resume.
- `files/system/usr/lib/systemd/system/cec-follower.service`
- `files/system/usr/lib/systemd/system/cec-tv-on.service`
- `files/system/usr/lib/systemd/system/cec-tv-standby.service`
- `files/system/usr/lib/systemd/system/cec-suspend-on-tv-off.service`
- `tests/lib/assert.sh` — tiny assertion helpers.
- `tests/stubs/cec-ctl`, `tests/stubs/cec-follower` — recording stubs.
- `tests/fixtures/*.info`, `tests/fixtures/monitor-*.txt` — canned `cec-ctl` output (from real on-device log).
- `tests/cec-lib.test.sh`, `tests/cec-follower-start.test.sh`, `tests/cec-tv-on.test.sh`, `tests/cec-tv-standby.test.sh`, `tests/cec-suspend.test.sh`, `tests/sleep-hook.test.sh`
- `tests/run.sh` — runs every `*.test.sh`.
- `tests/verify-units.sh` — `systemd-analyze verify` with install-path rewrite.

Modified:
- `recipes/modules.yml` — add `systemd` module (enable 3, disable 1) + v4l-utils dependency comment.
- `README.md` — "HDMI-CEC TV automation" section + validation checklist.

---

### Task 1: Shared resolution library `cec-lib.sh` + test harness

**Files:**
- Create: `tests/lib/assert.sh`, `tests/stubs/cec-ctl`, `tests/fixtures/cec0.info`, `tests/fixtures/cec1.info`, `tests/fixtures/cec2.info`, `tests/run.sh`, `tests/cec-lib.test.sh`
- Create: `files/system/usr/libexec/plasma-machine/cec-lib.sh`

**Interfaces:**
- Produces (sourced API; all read `${CEC_CTL:-cec-ctl}`, iterate `${CEC_DEV_GLOB:-/dev/cec*}`):
  - `cec_device_driver <dev>` → lowercased driver name, e.g. `amdgpu`
  - `cec_device_pa <dev>` → physical address string, e.g. `4.0.0.0` or `f.f.f.f`
  - `cec_device_la_mask <dev>` → logical-address mask, e.g. `0x0800`
  - `_pa_valid <pa>` → exit 0 if PA is assigned (not empty/`f.f.f.f`/`0xffff`)
  - `resolve_cec_device` → prints chosen amdgpu device path, exit non-zero if none
  - `resolve_cec_device_wait [timeout=60] [interval=2]` → resolve, retrying until a valid-PA device appears
  - `wait_for_registration <dev> [timeout=30] [interval=1]` → exit 0 once LA mask ≠ `0x0000`
  - `log <msg>` → stderr, `cec: ` prefix

- [ ] **Step 1: Write the assertion helpers**

Create `tests/lib/assert.sh`:

```bash
#!/usr/bin/env bash
# Minimal assertion helpers for the CEC offline tests.
TESTS_RUN=0
TESTS_FAILED=0

assert_eq() {
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$1" != "$2" ]; then
        echo "FAIL: ${3:-assert_eq}: expected [$2] got [$1]"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}
assert_contains() {
    TESTS_RUN=$((TESTS_RUN + 1))
    case "$1" in
        *"$2"*) ;;
        *) echo "FAIL: ${3:-assert_contains}: [$1] missing [$2]"; TESTS_FAILED=$((TESTS_FAILED + 1)) ;;
    esac
}
assert_not_contains() {
    TESTS_RUN=$((TESTS_RUN + 1))
    case "$1" in
        *"$2"*) echo "FAIL: ${3:-assert_not_contains}: [$1] should not contain [$2]"; TESTS_FAILED=$((TESTS_FAILED + 1)) ;;
        *) ;;
    esac
}
assert_ok() {
    TESTS_RUN=$((TESTS_RUN + 1))
    if ! "$@"; then echo "FAIL: command should succeed: $*"; TESTS_FAILED=$((TESTS_FAILED + 1)); fi
}
assert_fail() {
    TESTS_RUN=$((TESTS_RUN + 1))
    if "$@"; then echo "FAIL: command should fail: $*"; TESTS_FAILED=$((TESTS_FAILED + 1)); fi
}
finish() {
    echo "Ran $TESTS_RUN assertions, $TESTS_FAILED failed"
    [ "$TESTS_FAILED" -eq 0 ]
}
```

- [ ] **Step 2: Write the `cec-ctl` stub and fixtures**

Create `tests/stubs/cec-ctl` (and `chmod +x` it in Step 7):

```bash
#!/usr/bin/env bash
# Recording stub for cec-ctl used by offline tests.
#   CEC_FIXTURE_DIR     - dir with <devbasename>.info for info queries
#   CEC_CALLS           - file to append transmit invocations to
#   CEC_MONITOR_FIXTURE - file streamed when --monitor/--monitor-all is passed
dev=""
prev=""
mode="info"
for a in "$@"; do
    case "$a" in
        -d) prev="-d" ;;
        --to|--image-view-on|--active-source|--standby) mode="transmit"; prev="" ;;
        --monitor|--monitor-all) mode="monitor"; prev="" ;;
        *) [ "$prev" = "-d" ] && { dev="$a"; prev=""; } ;;
    esac
done

case "$mode" in
    monitor)
        [ -n "${CEC_MONITOR_FIXTURE:-}" ] && cat "$CEC_MONITOR_FIXTURE"
        exit 0 ;;
    transmit)
        [ -n "${CEC_CALLS:-}" ] && printf '%s\n' "$*" >> "$CEC_CALLS"
        exit 0 ;;
    info)
        base="$(basename "${dev:-none}")"
        if [ -n "${CEC_FIXTURE_DIR:-}" ] && [ -f "$CEC_FIXTURE_DIR/$base.info" ]; then
            cat "$CEC_FIXTURE_DIR/$base.info"; exit 0
        fi
        exit 1 ;;
esac
```

Create `tests/fixtures/cec0.info` (amdgpu, TV connected — from the real log):

```
Driver Info:
        Driver Name                : amdgpu
        Adapter Name               : DP-3
        Capabilities               : 0x0000037e
        Physical Address           : 4.0.0.0
        Logical Address Mask       : 0x0800
        CEC Version                : 2.0
        OSD Name                   : 'Playback'
```

Create `tests/fixtures/cec1.info` (amdgpu, no TV / unregistered):

```
Driver Info:
        Driver Name                : amdgpu
        Adapter Name               : DP-1
        Physical Address           : f.f.f.f
        Logical Address Mask       : 0x0000
```

Create `tests/fixtures/cec2.info` (a non-amdgpu adapter, must be ignored):

```
Driver Info:
        Driver Name                : vc4
        Adapter Name               : HDMI
        Physical Address           : 1.0.0.0
        Logical Address Mask       : 0x1000
```

- [ ] **Step 3: Write the test runner**

Create `tests/run.sh`:

```bash
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
```

- [ ] **Step 4: Write the failing tests for `cec-lib.sh`**

Create `tests/cec-lib.test.sh`:

```bash
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
```

- [ ] **Step 5: Run the tests — verify they fail**

Run: `bash tests/cec-lib.test.sh`
Expected: FAIL — `cec-lib.sh` does not exist yet, so the source line errors / assertions fail.

- [ ] **Step 6: Implement `cec-lib.sh`**

Create `files/system/usr/libexec/plasma-machine/cec-lib.sh`:

```bash
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
```

- [ ] **Step 7: Make stubs/tests executable, run tests — verify they pass**

Run:
```bash
chmod +x tests/stubs/cec-ctl tests/run.sh tests/cec-lib.test.sh
bash tests/cec-lib.test.sh
```
Expected: `Ran 11 assertions, 0 failed` and exit 0.

- [ ] **Step 8: Lint the library**

Run: `shellcheck -x files/system/usr/libexec/plasma-machine/cec-lib.sh tests/stubs/cec-ctl`
Expected: no output (clean). Fix any findings.

- [ ] **Step 9: Commit**

```bash
git add tests files/system/usr/libexec/plasma-machine/cec-lib.sh
git commit -m "feat(cec): add runtime device-resolution library with tests"
```

---

### Task 2: Follower backbone — `cec-follower-start` + `cec-follower.service`

**Files:**
- Create: `tests/stubs/cec-follower`, `tests/cec-follower-start.test.sh`, `tests/verify-units.sh`
- Create: `files/system/usr/libexec/plasma-machine/cec-follower-start`
- Create: `files/system/usr/lib/systemd/system/cec-follower.service`

**Interfaces:**
- Consumes: `resolve_cec_device_wait`, `log` (Task 1).
- Produces: `cec-follower-start` execs `${CEC_FOLLOWER:-cec-follower} -d <dev>`. `cec-follower.service` is the `After=`/`Wants=` target for tv-on, tv-standby, suspend units.

- [ ] **Step 1: Write the `cec-follower` stub**

Create `tests/stubs/cec-follower` (chmod +x in Step 6):

```bash
#!/usr/bin/env bash
# Recording stub for cec-follower. FOLLOWER_CALLS=file captures invocation args.
[ -n "${FOLLOWER_CALLS:-}" ] && printf '%s\n' "$*" >> "$FOLLOWER_CALLS"
exit 0
```

- [ ] **Step 2: Write the failing test**

Create `tests/cec-follower-start.test.sh`:

```bash
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
```

- [ ] **Step 3: Run the test — verify it fails**

Run: `bash tests/cec-follower-start.test.sh`
Expected: FAIL — script does not exist.

- [ ] **Step 4: Implement `cec-follower-start`**

Create `files/system/usr/libexec/plasma-machine/cec-follower-start`:

```bash
#!/usr/bin/env bash
# Resolve the amdgpu CEC device the TV is on, then run cec-follower on it to keep
# the PC registered on the bus and answering polls. Exits non-zero if no device
# is found so systemd (Restart=always) keeps retrying until the TV appears.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$DIR/cec-lib.sh"

CEC_FOLLOWER="${CEC_FOLLOWER:-cec-follower}"

if ! dev="$(resolve_cec_device_wait)"; then
    log "follower: no amdgpu CEC device found after wait"
    exit 1
fi
log "follower: starting on $dev"
exec "$CEC_FOLLOWER" -d "$dev"
```

- [ ] **Step 5: Write the unit-verify helper**

Create `tests/verify-units.sh`:

```bash
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
```

- [ ] **Step 6: Write the unit, make things executable, run tests**

Create `files/system/usr/lib/systemd/system/cec-follower.service`:

```ini
[Unit]
Description=HDMI-CEC follower (keep this PC registered on the CEC bus)
Documentation=https://github.com/drzero42/plasma-machine

[Service]
Type=simple
ExecStart=/usr/libexec/plasma-machine/cec-follower-start
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

Run:
```bash
chmod +x tests/stubs/cec-follower tests/cec-follower-start.test.sh tests/verify-units.sh
bash tests/cec-follower-start.test.sh
```
Expected: `Ran 1 assertions, 0 failed`.

- [ ] **Step 7: Lint and verify the unit**

Run:
```bash
shellcheck -x files/system/usr/libexec/plasma-machine/cec-follower-start tests/stubs/cec-follower
bash tests/verify-units.sh
```
Expected: shellcheck clean; `systemd-analyze verify` prints nothing about `cec-follower.service` (warnings about standard targets are acceptable; there must be no error about a missing/non-executable ExecStart).

- [ ] **Step 8: Commit**

```bash
git add tests files/system/usr/libexec/plasma-machine/cec-follower-start files/system/usr/lib/systemd/system/cec-follower.service
git commit -m "feat(cec): add follower backbone service"
```

---

### Task 3: Startup + resume wake — `cec-tv-on` + unit + sleep hook

**Files:**
- Create: `tests/cec-tv-on.test.sh`, `tests/sleep-hook.test.sh`
- Create: `files/system/usr/libexec/plasma-machine/cec-tv-on`
- Create: `files/system/usr/lib/systemd/system/cec-tv-on.service`
- Create: `files/system/usr/lib/systemd/system-sleep/50-cec-tv-on`

**Interfaces:**
- Consumes: `resolve_cec_device_wait`, `wait_for_registration`, `cec_device_pa`, `_pa_valid`, `log`, `${CEC_CTL}` (Task 1); `cec-follower.service` (Task 2).
- Produces: `cec-tv-on.service` (oneshot) restarted by the sleep hook on resume.

- [ ] **Step 1: Write the failing tests**

Create `tests/cec-tv-on.test.sh`:

```bash
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
```

Create `tests/sleep-hook.test.sh`:

```bash
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
```

- [ ] **Step 2: Run the tests — verify they fail**

Run: `bash tests/cec-tv-on.test.sh; bash tests/sleep-hook.test.sh`
Expected: both FAIL — script and hook do not exist.

- [ ] **Step 3: Implement `cec-tv-on`**

Create `files/system/usr/libexec/plasma-machine/cec-tv-on`:

```bash
#!/usr/bin/env bash
# Wake the TV and switch it to this PC. Runs at startup (multi-user.target) and
# on resume (via the system-sleep hook). Soft-fails (exit 0) so a missing TV
# never marks the boot transaction failed.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$DIR/cec-lib.sh"

if ! dev="$(resolve_cec_device_wait)"; then
    log "tv-on: no amdgpu CEC device found; nothing to do"
    exit 0
fi
if ! wait_for_registration "$dev"; then
    log "tv-on: $dev has no logical address yet; transmitting anyway"
fi
pa="$(cec_device_pa "$dev")"
log "tv-on: using $dev (PA $pa)"

"$CEC_CTL" -d "$dev" --to 0 --image-view-on || log "tv-on: image-view-on failed"
if _pa_valid "$pa"; then
    "$CEC_CTL" -d "$dev" --active-source "phys-addr=$pa" || log "tv-on: active-source failed"
else
    log "tv-on: PA invalid ($pa); skipping active-source"
fi
```

- [ ] **Step 4: Implement the sleep hook**

Create `files/system/usr/lib/systemd/system-sleep/50-cec-tv-on`:

```bash
#!/usr/bin/env bash
# systemd-sleep hook. On resume (post) re-run the tv-on logic asynchronously so
# we never block the resume path. Args: $1=pre|post, $2=suspend|hibernate|...
SYSTEMCTL="${SYSTEMCTL:-systemctl}"
case "${1:-}" in
    post) "$SYSTEMCTL" --no-block restart cec-tv-on.service ;;
esac
```

- [ ] **Step 5: Implement the unit**

Create `files/system/usr/lib/systemd/system/cec-tv-on.service`:

```ini
[Unit]
Description=Wake the TV and switch it to this PC over HDMI-CEC
After=cec-follower.service
Wants=cec-follower.service

[Service]
Type=oneshot
ExecStart=/usr/libexec/plasma-machine/cec-tv-on

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 6: Run tests — verify they pass**

Run:
```bash
chmod +x tests/cec-tv-on.test.sh tests/sleep-hook.test.sh
bash tests/cec-tv-on.test.sh
bash tests/sleep-hook.test.sh
```
Expected: `Ran 3 assertions, 0 failed` and `Ran 2 assertions, 0 failed`.

- [ ] **Step 7: Lint and verify**

Run:
```bash
shellcheck -x files/system/usr/libexec/plasma-machine/cec-tv-on files/system/usr/lib/systemd/system-sleep/50-cec-tv-on
bash tests/verify-units.sh
```
Expected: shellcheck clean; verify reports no errors for `cec-tv-on.service` (cross-ref to `cec-follower.service` now resolves since both are in the temp dir).

- [ ] **Step 8: Commit**

```bash
git add tests files/system/usr/libexec/plasma-machine/cec-tv-on files/system/usr/lib/systemd/system/cec-tv-on.service files/system/usr/lib/systemd/system-sleep/50-cec-tv-on
git commit -m "feat(cec): wake TV and switch input on startup and resume"
```

---

### Task 4: Shutdown standby — `cec-tv-standby` + unit

**Files:**
- Create: `tests/cec-tv-standby.test.sh`
- Create: `files/system/usr/libexec/plasma-machine/cec-tv-standby`
- Create: `files/system/usr/lib/systemd/system/cec-tv-standby.service`

**Interfaces:**
- Consumes: `resolve_cec_device`, `log`, `${CEC_CTL}` (Task 1); `cec-follower.service` (Task 2).
- Produces: `cec-tv-standby.service` (oneshot, `ExecStop` sends standby on shutdown).

- [ ] **Step 1: Write the failing test**

Create `tests/cec-tv-standby.test.sh`:

```bash
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

bash "$repo/files/system/usr/libexec/plasma-machine/cec-tv-standby"
calls="$(cat "$work/cec.calls" 2>/dev/null || echo MISSING)"
assert_contains "$calls" "--to 0 --standby" "standby sent to the TV"

rm -rf "$work"
finish
```

- [ ] **Step 2: Run the test — verify it fails**

Run: `bash tests/cec-tv-standby.test.sh`
Expected: FAIL — script does not exist.

- [ ] **Step 3: Implement `cec-tv-standby`**

Create `files/system/usr/libexec/plasma-machine/cec-tv-standby`:

```bash
#!/usr/bin/env bash
# Send the TV to standby. Invoked as the ExecStop of cec-tv-standby.service on
# shutdown, while cec-follower is still up (so the adapter is still configured).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$DIR/cec-lib.sh"

if ! dev="$(resolve_cec_device)"; then
    log "tv-standby: no amdgpu CEC device found; nothing to do"
    exit 0
fi
log "tv-standby: sending standby via $dev"
"$CEC_CTL" -d "$dev" --to 0 --standby || log "tv-standby: standby failed"
```

- [ ] **Step 4: Implement the unit**

Create `files/system/usr/lib/systemd/system/cec-tv-standby.service`:

```ini
[Unit]
Description=Send the TV to standby over HDMI-CEC on shutdown
After=cec-follower.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/true
ExecStop=/usr/libexec/plasma-machine/cec-tv-standby

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 5: Run test — verify it passes**

Run: `chmod +x tests/cec-tv-standby.test.sh && bash tests/cec-tv-standby.test.sh`
Expected: `Ran 1 assertions, 0 failed`.

- [ ] **Step 6: Lint and verify**

Run:
```bash
shellcheck -x files/system/usr/libexec/plasma-machine/cec-tv-standby
bash tests/verify-units.sh
```
Expected: shellcheck clean; no errors for `cec-tv-standby.service`.

- [ ] **Step 7: Commit**

```bash
git add tests files/system/usr/libexec/plasma-machine/cec-tv-standby files/system/usr/lib/systemd/system/cec-tv-standby.service
git commit -m "feat(cec): send TV to standby on shutdown"
```

---

### Task 5: Optional suspend-on-TV-off — `cec-suspend-on-tv-off` + disabled unit

**Files:**
- Create: `tests/cec-suspend.test.sh`, `tests/fixtures/monitor-standby.txt`, `tests/fixtures/monitor-nostandby.txt`
- Create: `files/system/usr/libexec/plasma-machine/cec-suspend-on-tv-off`
- Create: `files/system/usr/lib/systemd/system/cec-suspend-on-tv-off.service`

**Interfaces:**
- Consumes: `resolve_cec_device_wait`, `log`, `${CEC_CTL}` (Task 1).
- Produces: `handle_line <line>` (exit 0 when the line is a TV-sourced STANDBY), `monitor_once <dev>` (reads `cec-ctl --monitor`, calls `${SYSTEMCTL} suspend` on a match). When sourced with `CEC_TEST_SOURCE=1`, `main` is not run. Unit shipped **disabled**.

- [ ] **Step 1: Write the monitor fixtures**

Create `tests/fixtures/monitor-standby.txt` (mirrors the real log):

```
    TV to all (0 to 15): DEVICE_VENDOR_ID (0x87):
    TV to all (0 to 15): STANDBY (0x36)
```

Create `tests/fixtures/monitor-nostandby.txt`:

```
    Audio System to all (5 to 15): STANDBY (0x36)
    TV to all (0 to 15): DEVICE_VENDOR_ID (0x87):
```

(The second file deliberately includes a non-TV STANDBY to prove it is ignored.)

- [ ] **Step 2: Write the failing test**

Create `tests/cec-suspend.test.sh`:

```bash
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
```

- [ ] **Step 3: Run the test — verify it fails**

Run: `bash tests/cec-suspend.test.sh`
Expected: FAIL — script does not exist.

- [ ] **Step 4: Implement `cec-suspend-on-tv-off`**

Create `files/system/usr/libexec/plasma-machine/cec-suspend-on-tv-off`:

```bash
#!/usr/bin/env bash
# Suspend the PC when the TV broadcasts CEC <Standby>. Opt-in: the unit ships
# disabled; enable with `systemctl enable --now cec-suspend-on-tv-off.service`.
# Source with CEC_TEST_SOURCE=1 to load the functions without running main.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$DIR/cec-lib.sh"

SYSTEMCTL="${SYSTEMCTL:-systemctl}"
CEC_SUSPEND_DEBOUNCE="${CEC_SUSPEND_DEBOUNCE:-5}"

# Match a STANDBY broadcast sourced from the TV (logical address 0). The TV
# broadcasts "TV to all (0 to 15): STANDBY (0x36)". Keyed on "TV to all" so a
# STANDBY from another device, or our own directed standby, never matches.
# NOTE: validate the exact `cec-ctl --monitor` wording on-device (checklist) and
# adjust this pattern if it differs from cec-follower's.
handle_line() {
    case "$1" in
        *"TV to all"*"STANDBY"*) return 0 ;;
    esac
    return 1
}

# Read one monitor session; suspend on the first TV standby, then return.
monitor_once() {
    "$CEC_CTL" -d "$1" --monitor 2>/dev/null | while IFS= read -r line; do
        if handle_line "$line"; then
            log "suspend-on-tv-off: TV standby detected; suspending"
            "$SYSTEMCTL" suspend || log "suspend-on-tv-off: suspend failed"
            return 0
        fi
    done
}

main() {
    local dev
    if ! dev="$(resolve_cec_device_wait)"; then
        log "suspend-on-tv-off: no amdgpu CEC device found"
        exit 1
    fi
    log "suspend-on-tv-off: monitoring $dev"
    while :; do
        monitor_once "$dev"
        # Debounce + restart monitor so a STANDBY buffered before suspend can't
        # immediately re-suspend on resume.
        sleep "$CEC_SUSPEND_DEBOUNCE"
    done
}

if [ "${CEC_TEST_SOURCE:-0}" != "1" ]; then
    main "$@"
fi
```

- [ ] **Step 5: Implement the (disabled) unit**

Create `files/system/usr/lib/systemd/system/cec-suspend-on-tv-off.service`:

```ini
[Unit]
Description=Suspend the PC when the TV broadcasts HDMI-CEC standby
Documentation=https://github.com/drzero42/plasma-machine
After=cec-follower.service
Wants=cec-follower.service

[Service]
Type=simple
ExecStart=/usr/libexec/plasma-machine/cec-suspend-on-tv-off
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 6: Run test — verify it passes**

Run: `chmod +x tests/cec-suspend.test.sh && bash tests/cec-suspend.test.sh`
Expected: `Ran 6 assertions, 0 failed`.

- [ ] **Step 7: Lint and verify**

Run:
```bash
shellcheck -x files/system/usr/libexec/plasma-machine/cec-suspend-on-tv-off
bash tests/verify-units.sh
```
Expected: shellcheck clean; no errors for `cec-suspend-on-tv-off.service`.

- [ ] **Step 8: Commit**

```bash
git add tests files/system/usr/libexec/plasma-machine/cec-suspend-on-tv-off files/system/usr/lib/systemd/system/cec-suspend-on-tv-off.service
git commit -m "feat(cec): add opt-in suspend-on-TV-off monitor"
```

---

### Task 6: Wire into the BlueBuild pipeline

**Files:**
- Modify: `recipes/modules.yml`

**Interfaces:**
- Consumes: all unit files from Tasks 2–5 (copied by the existing `files` module).
- Produces: enabled `cec-follower`/`cec-tv-on`/`cec-tv-standby`, disabled `cec-suspend-on-tv-off` in both channels.

- [ ] **Step 1: Add the systemd module + dependency note**

In `recipes/modules.yml`, the current final entry is the signing module:

```yaml
  # 5. Install the cosign signing policy so signed pulls verify against cosign.pub.
  - type: signing
```

Replace it with the CEC enablement block **followed by** signing (keep signing last):

```yaml
  # 5. HDMI-CEC TV automation. The follower/tv-on/tv-standby/suspend units and
  #    their /usr/libexec/plasma-machine scripts are copied by the files module
  #    above. v4l-utils (cec-ctl, cec-follower) already ships in the bazzite-deck
  #    base, so it is deliberately NOT layered here — re-layering a base package
  #    can error under rpm-ostree. If a future base ever drops it, uncomment:
  #  - type: dnf
  #    install:
  #      packages:
  #        - v4l-utils
  #
  #    Enable the always-on services; cec-suspend-on-tv-off is installed but left
  #    disabled (opt in on-device: systemctl enable --now cec-suspend-on-tv-off).
  - type: systemd
    system:
      enabled:
        - cec-follower.service
        - cec-tv-on.service
        - cec-tv-standby.service
      disabled:
        - cec-suspend-on-tv-off.service

  # 6. Install the cosign signing policy so signed pulls verify against cosign.pub.
  - type: signing
```

- [ ] **Step 2: Sanity-check the YAML is well-formed**

Run:
```bash
python3 -c "import sys; open('recipes/modules.yml').read(); print('read ok')"
grep -nE 'type: (systemd|signing)' recipes/modules.yml
```
Expected: prints `read ok`; the grep shows the `systemd` entry appears **before** `signing`. (Full schema validation happens in CI's BlueBuild build — `bb`/`yamllint` are not available locally.)

- [ ] **Step 3: Commit**

```bash
git add recipes/modules.yml
git commit -m "feat(cec): enable CEC services in the image pipeline"
```

---

### Task 7: Document in the README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add the CEC section**

Append to `README.md`, before the `## Signing` section, the following:

```markdown
## HDMI-CEC TV automation

Root systemd services let the booted PC drive the living-room TV over HDMI-CEC
(amdgpu CEC-tunneling-over-AUX through a DP→HDMI adapter):

- **`cec-follower.service`** — the backbone. Runs `cec-follower` so the PC stays
  registered on the CEC bus and answers TV polls (no `FEATURE_ABORT`). The only
  process that owns the adapter's logical-address config.
- **`cec-tv-on.service`** — oneshot at `multi-user.target` (and re-run on resume
  via `/usr/lib/systemd/system-sleep/50-cec-tv-on`): wakes the TV
  (`--image-view-on`) and switches it to this PC (`--active-source`).
- **`cec-tv-standby.service`** — sends the TV to standby on shutdown (its
  `ExecStop`, ordered before the follower stops so the adapter is still up).
- **`cec-suspend-on-tv-off.service`** — *optional, ships disabled*: monitors the
  bus and suspends the PC when the TV broadcasts `<Standby>`. Enable with
  `sudo systemctl enable --now cec-suspend-on-tv-off.service`.

### Runtime resolution (no hardcoded hardware)

`cec-ctl`/`cec-follower` are already in the Bazzite base, so nothing is layered.
The wrapper scripts in `/usr/libexec/plasma-machine/` (sharing `cec-lib.sh`)
resolve everything at runtime: they pick the `amdgpu` CEC device that currently
reports a valid physical address (the TV's powered port), and read that physical
address back for `--active-source`. Move the cable to a different GPU port and it
re-resolves on the next boot — no edits, nothing to change in the image.

### On-device validation checklist (after `rpm-ostree rebase` + reboot)

1. **Resolution:** `systemctl status cec-follower` logs the chosen `/dev/cecN`;
   confirm it is the `amdgpu` device on the TV's port.
2. **Registration:** with the TV on a few seconds, `cec-ctl -d /dev/cec0` shows a
   valid `Physical Address` and a non-zero `Logical Address Mask`. If it ever
   sticks at `0x0000`, `systemctl restart cec-follower`.
3. **No FEATURE_ABORT:** run `cec-follower -m` (or watch the running service) and
   confirm TV polls get replies, not `FEATURE_ABORT`.
4. **Startup:** reboot → the TV wakes and switches to the PC input.
5. **Shutdown:** reboot/poweroff → the TV goes to standby.
6. **Resume:** suspend then wake → the TV wakes and switches input again.
7. **Monitor format (for the optional unit):** run
   `cec-ctl -d /dev/cec0 --monitor`, turn the TV off, and confirm the received
   line matches the script's `*"TV to all"*"STANDBY"*` pattern. If `--monitor`
   formats it differently than `cec-follower`, adjust `handle_line` in
   `cec-suspend-on-tv-off`.
8. **Suspend-on-TV-off:** first confirm nothing already suspends the PC on
   TV-off (it doesn't by default). To enable it:
   `systemctl enable --now cec-suspend-on-tv-off.service`, turn the TV off → PC
   suspends; then verify there is **no** suspend loop on resume.

### Developing the CEC scripts

The parsing/resolution and standby-detection logic has offline tests (Bash with
injected `cec-ctl`/`cec-follower`/`systemctl` stubs — no hardware needed):

```bash
bash tests/run.sh            # all unit tests
bash tests/verify-units.sh   # systemd-analyze verify on the unit files
shellcheck -x files/system/usr/libexec/plasma-machine/*
```
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs(cec): document the CEC TV automation services"
```

---

## Final verification

- [ ] **Run the full offline suite:**

```bash
bash tests/run.sh
bash tests/verify-units.sh
shellcheck -x files/system/usr/libexec/plasma-machine/* files/system/usr/lib/systemd/system-sleep/* tests/stubs/*
```
Expected: all tests pass; `systemd-analyze verify` reports no errors on the four units; shellcheck clean.

- [ ] **Confirm executable bits are committed** (so `COPY` preserves them):

```bash
git ls-files -s files/system/usr/libexec/plasma-machine files/system/usr/lib/systemd/system-sleep | awk '$1!="100755"{print "NOT EXEC:", $4}'
```
Expected: no output (every script + the sleep hook is mode `100755`).

---

## Self-Review (completed during planning)

- **Spec coverage:** goals 1–5 → Tasks 3 (startup+resume), 4 (shutdown), 2 (stay registered), 5 (suspend opt-in); runtime resolution → Task 1; BlueBuild wiring (no v4l-utils layer, systemd enable/disable) → Task 6; README + checklist → Task 7. No gaps.
- **Placeholder scan:** every step has complete file contents or exact commands with expected output. No TBD/TODO.
- **Type/name consistency:** `resolve_cec_device`, `resolve_cec_device_wait`, `wait_for_registration`, `cec_device_pa`, `_pa_valid`, `handle_line`, `monitor_once` are defined in Task 1/5 and used with the same names/signatures in Tasks 2–5. Env-var injection points (`CEC_CTL`, `CEC_DEV_GLOB`, `CEC_FOLLOWER`, `SYSTEMCTL`, `CEC_MONITOR_FIXTURE`, `CEC_FIXTURE_DIR`, `CEC_CALLS`, `FOLLOWER_CALLS`, `CEC_TEST_SOURCE`) are consistent between scripts, stubs, and tests.
