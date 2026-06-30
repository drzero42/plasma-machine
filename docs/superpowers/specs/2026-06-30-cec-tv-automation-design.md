# HDMI-CEC TV automation — design

**Date:** 2026-06-30
**Status:** Approved (pending written-spec review)
**Channel impact:** shared `recipes/modules.yml` → both stable and testing.

## Goal

Make the booted Plasma Machine drive the living-room TV over HDMI-CEC:

1. **On startup** — wake the TV and switch it to the PC's input.
2. **On shutdown** — send the TV to standby.
3. **Stay registered** — keep the PC on the CEC bus answering TV polls, so it
   never replies `FEATURE_ABORT`.
4. **On resume** — re-wake the TV and grab its input again.
5. **Optional, opt-in** — when the TV broadcasts `<Standby>` (TV turned off),
   suspend the PC.

CEC reaches the TV through amdgpu's CEC-tunneling-over-AUX on a DP→HDMI adapter
(no native-HDMI CEC). All hardware specifics are resolved **at runtime on the
booted machine** — nothing is hardcoded, so the design survives moving the cable
to a different GPU port (re-resolved on next boot).

## Hardware facts (from on-device testing — context, not re-verifiable in CI)

Observed with `cec-follower -d /dev/cec0 -m -s` on the target:

- Single CEC device `/dev/cec0`, **driver `amdgpu`**, adapter "DP-3",
  card 1 / connector 129. Capabilities include *Monitor All* and *Needs HPD*.
- The kernel **derives and maintains the physical address itself** from the
  connector EDID. Boot sequence: `PA f.f.f.f / LA 0x0000` → `PA 4.0.0.0 / LA
  0x0000` → `PA 4.0.0.0 / LA 0x0800`. **No userspace `cec-ctl -E` / EDID parsing
  is required.**
- The PA **self-heals across a TV power-cycle**: TV-off drops HPD
  (`PA f.f.f.f`), TV-on re-derives `PA 4.0.0.0` and the follower re-claims its LA.
- `cec-follower` alone registers the PC as **Playback Device 3** (LA `0x0800`,
  OSD name "Playback").
- TV-off is signalled by a broadcast **`TV to all (0 to 15): STANDBY (0x36)`**
  (initiator = TV / logical address 0).
- `cec-follower` reacts to that `STANDBY` only by flipping its *own* emulated
  power state — **it does not suspend the host.** So no zero-code path suspends
  the PC on TV-off; the opt-in suspend unit (component #4) is what provides that
  behavior.
- The bus also carries a Sony TV (0), an Audio System (5, `3.0.0.0`), and other
  Playback devices (4, 8). Coexistence is fine.

These facts let the design key entirely off CEC state from `cec-ctl`/`cec-follower`
— it never touches DRM sysfs.

## Architecture

A single long-running **backbone** owns the device's CEC configuration; everything
else is transmit-only or passive, so nothing thrashes the adapter:

- **`cec-follower`** is the only process that claims a logical address. It keeps
  the PC registered and answers polls, and re-claims its LA after PA changes.
- **tv-on / tv-standby** are short `cec-ctl` transmits that reuse the follower's
  claimed LA. They do **not** pass `--playback`/`--tv` (which would reconfigure).
- **suspend-on-tv-off** is a passive `cec-ctl --monitor` reader.

### Runtime resolution (`cec-lib.sh`, sourced by every script)

No value from the hardware-facts section is baked in. Helpers:

- `resolve_cec_device`:
  1. Enumerate `/dev/cec*`; keep those whose `cec-ctl -d <dev>` driver name is
     `amdgpu`.
  2. Prefer the one reporting a **valid Physical Address** (`!= f.f.f.f`) — that
     is precisely the port the TV is plugged into and powered on, even if the
     cable moved to a different connector.
  3. Fallbacks when no port has a valid PA yet (e.g. TV off at boot): if exactly
     one `amdgpu` cec device exists, use it; otherwise **wait/retry** (bounded)
     until a port reports a valid PA.
  4. Log the chosen device and why.
- `read_phys_addr <dev>`: parse "Physical Address" from `cec-ctl -d <dev>`.
- `wait_for_registration <dev> [timeout]`: poll `cec-ctl -d <dev>` until the
  Logical Address Mask is non-zero (follower has claimed an LA), or timeout.

Because the PA is read live and fed to `--active-source`, a move to a port that
yields a different PA (e.g. `2.0.0.0`) works with zero edits after a reboot.

## Components

All scripts live in `/usr/libexec/plasma-machine/` (committed with the exec bit
so the BlueBuild `files` module → `COPY` preserves it). All units live in
`/usr/lib/systemd/system/`. Everything runs as **root**; no unit references a
username.

### 1. `cec-follower.service` (backbone — enabled)

- `ExecStart` = `cec-follower-start`, which resolves the device then
  `exec cec-follower -d <dev>`.
- `Restart=always`, `RestartSec` small — survives transient failures and the
  "TV off at boot, retry until it appears" case.
- `WantedBy=multi-user.target`.

### 2. `cec-tv-on.service` (startup + resume — enabled)

- `Type=oneshot`, `After=cec-follower.service`, `Wants=cec-follower.service`,
  `WantedBy=multi-user.target` (earlier than graphical so the TV wakes sooner).
- `ExecStart` = `cec-tv-on`: resolve device → `wait_for_registration` → send
  `cec-ctl -d <dev> --to 0 --image-view-on`, then
  `cec-ctl -d <dev> --active-source phys-addr=<own PA>`.
- **Resume:** `/usr/lib/systemd/system-sleep/50-cec-tv-on` runs on `post` (resume)
  and does `systemctl --no-block restart cec-tv-on.service`. The hook returns
  immediately (no blocking resume); the service does the waiting/transmitting and
  reuses the exact startup logic.

### 3. `cec-tv-standby.service` (shutdown — enabled)

- `Type=oneshot`, `RemainAfterExit=yes`, `ExecStart=/bin/true`,
  `ExecStop` = `cec-tv-standby` (`cec-ctl -d <dev> --to 0 --standby`).
- `After=cec-follower.service` so on shutdown this unit stops **before** the
  follower (reverse-dependency order) — the adapter is still configured when the
  standby is sent. `WantedBy=multi-user.target`.

### 4. `cec-suspend-on-tv-off.service` (opt-in — installed but DISABLED)

- `ExecStart` = `cec-suspend-on-tv-off`: `cec-ctl -d <dev> --monitor`, match a
  broadcast `STANDBY` **from initiator TV (0)**, debounce, `systemctl suspend`.
  Matching from-TV (not destination) means the PC's own outgoing standby on
  shutdown never self-triggers.
- **Suspend-loop guard:** after firing `systemctl suspend`, the script debounces
  and restarts its `cec-ctl --monitor` so a `STANDBY` buffered before suspend
  can't immediately re-suspend on resume.
- `Restart=always`. Shipped **disabled**; the toggle is
  `sudo systemctl enable --now cec-suspend-on-tv-off.service` (writable `/etc`,
  survives image updates).

## BlueBuild integration (`recipes/modules.yml`)

Both channels share this file, so the feature lands on stable + testing together.

- **Packages:** `cec-ctl` and `cec-follower` (`v4l-utils`) are already in the
  `bazzite-deck` base, so **no `dnf` layer is added** — re-layering a base package
  can error under rpm-ostree. The dependency is documented in a comment, with a
  ready-to-uncomment `dnf` module as fallback should a future base drop it.
- **Files:** the existing `files` module already copies all of `files/system/*`,
  so the new units + scripts are baked in with no change to that module.
- **New `systemd` module entry:**

  ```yaml
  - type: systemd
    system:
      enabled:
        - cec-follower.service
        - cec-tv-on.service
        - cec-tv-standby.service
      disabled:
        - cec-suspend-on-tv-off.service
  ```

- The existing `90-cec-uaccess.rules` is left as-is (services run as root; the
  rule is for interactive use). Not duplicated.

## README

A new "HDMI-CEC TV automation" section: what each service does, the
runtime-resolution approach (and the port-move guarantee), how to toggle unit #4,
and the validation checklist below.

## Validation checklist (on-device, after rebase — for the maintainer)

1. **Resolution:** `systemctl status cec-follower` logs the chosen `/dev/cecN`;
   confirm it's the `amdgpu` device on the TV's port.
2. **Registration steady state:** with the TV on a few seconds, `cec-ctl -d
   /dev/cec0` shows `Physical Address 4.0.0.0` and `Logical Address Mask 0x0800`.
   (The tail of the test log briefly showed PA-without-LA during rapid flapping —
   confirm it reliably settles back to a claimed LA; if it ever sticks at
   `0x0000`, `systemctl restart cec-follower` is the mitigation.)
3. **No FEATURE_ABORT:** with `cec-follower -m` (or the service running), confirm
   TV polls (`GIVE_DEVICE_POWER_STATUS`, etc.) get replies, not `FEATURE_ABORT`.
4. **Startup:** reboot → TV wakes and switches to the PC input.
5. **Shutdown:** `systemctl stop cec-tv-standby` (and a real reboot/poweroff) →
   TV goes to standby.
6. **Resume:** suspend then wake → TV wakes and switches input again.
7. **Monitor parse (unit #4):** run `cec-ctl -d /dev/cec0 --monitor`, turn the TV
   off, and **confirm the exact text** of the received STANDBY line matches the
   script's regex (the one thing not verifiable off-device). Adjust the regex if
   the monitor format differs from `cec-follower`'s.
8. **Suspend-on-TV-off decision:** first confirm nothing already suspends the PC
   on TV-off (the test log shows `cec-follower` does **not**). If you want the
   behavior, `systemctl enable --now cec-suspend-on-tv-off.service`, turn the TV
   off → PC suspends; then verify **no suspend loop on resume**.

## Out of scope

- udev-driven hot re-resolution when the cable is moved while running (reboot or
  `systemctl restart` re-resolves instead).
- Audio-system / AVR control.
- CEC-based wake (handled separately by the Steam Controller wakeup source).
