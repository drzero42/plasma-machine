# Plasma Machine

A custom [Bazzite Deck](https://bazzite.gg) (KDE) OS image for the **Plasma
Machine** — a self-built Steam Machine for the living room (AMD hardware). Built
with [BlueBuild](https://blue-build.org) on top of
`ghcr.io/ublue-os/bazzite-deck:stable`.

Its headline feature is a custom **Plymouth boot splash** (plasma-ball logo,
wordmark, and a glowing rotating-arc spinner). The repo is structured to grow into
the machine's full image definition over time.

## Why an image instead of just dropping in a theme?

Bazzite is an atomic/immutable OS: `/usr` is read-only and the boot splash lives in
the initramfs. Adding a Plymouth theme at runtime doesn't survive, because
regenerating the initramfs creates a fresh deployment that discards runtime `/usr`
changes. Baking it into the image — and regenerating the initramfs **at build
time** — is the only way it persists *and* survives updates.

## Layout

```
recipes/recipe.yml                                   # BlueBuild recipe
files/system/usr/share/plymouth/themes/plasma-machine/  # the Plymouth theme
.github/workflows/build.yml                           # CI: build + sign + publish
cosign.pub                                            # public signing key
devenv.nix                                            # dev toolchain
```

## Deploying to the machine

The CI publishes `ghcr.io/drzero42/plasma-machine:latest`. On the Plasma Machine:

```bash
# 1. First rebase — the signing policy isn't installed yet, so pull unverified:
rpm-ostree rebase ostree-unverified-registry:ghcr.io/drzero42/plasma-machine:latest
systemctl reboot

# 2. After reboot the image carries the signing policy, so switch to the signed ref:
rpm-ostree rebase ostree-image-signed:docker://ghcr.io/drzero42/plasma-machine:latest
```

From then on, `rpm-ostree upgrade` (automatic on Bazzite) tracks the rolling
`:latest` tag. Roll back any time with `rpm-ostree rollback` or by picking the
previous entry in the boot menu — rollback is handled by ostree deployments, not the
tag.

## Working on the image

```bash
devenv shell          # cosign, jq, gh
```

Edit `recipes/recipe.yml` or the theme under `files/system/...`, push to `main`, and
CI rebuilds and publishes. To preview the boot splash animation on the machine:

```bash
sudo plymouthd; sudo plymouth --show-splash; sleep 8; sudo plymouth --quit
```

(best run from a TTY so it doesn't fight the desktop compositor.)

## HDMI-CEC TV automation

The Bazzite base image already provides **outbound** PC→TV CEC through
`/usr/bin/cec-control` (kernel-CEC/`cec-ctl`, runtime physical-address detection),
driven by its `cec-onboot`/`cec-onpoweroff`/`cec-onsleep` one-shot units and
configured by `/etc/default/cec-control` (`CEC_MODE=dgpu` on this machine). This
image enables the base's boot/poweroff units and adds only the two things the base
doesn't cover — so there is no duplicate "wake/standby the TV" code here.

- **`cec-onboot.service`** *(base)* — on boot, wakes the TV and sets the PC as the
  active source. **Enabled by this image.**
- **`cec-onpoweroff.service`** *(base)* — on shutdown, sends the TV to standby.
  **Enabled by this image.**
- **`cec-onsleep.service`** *(base)* — sleep/resume CEC. **Left disabled** —
  `/etc/default/cec-control` sets `CEC_ONSLEEP_STANDBY=false`.
- **`cec-follower.service`** *(this repo)* — runs `cec-follower` so the PC stays
  registered on the CEC bus and answers TV polls (no `FEATURE_ABORT`). The base
  uses one-shots only, so this persistent responder has no base equivalent.
  **Enabled.**
- **`cec-suspend-on-tv-off.service`** *(this repo)* — the **inbound** direction:
  monitors the bus and suspends the PC when the TV broadcasts `<Standby>`. No base
  equivalent. **Enabled** (opt out: `systemctl disable --now cec-suspend-on-tv-off`).

The libcec example units `cec-poweroff-tv.service`, `cec-active-source.service`,
and `cec-active-source.timer` are **masked** — they hardcode `cec-client` (the
wrong backend for this kernel-CEC adapter) and would race `cec-control`.

`/etc/default/cec-control` is owned by the base/host and is **not** shipped or
modified by this image.

### Runtime resolution (the kept scripts)

`cec-ctl`/`cec-follower` already ship in the Bazzite base, so nothing is layered.
`cec-follower-start` and `cec-suspend-on-tv-off` share `cec-lib.sh`, which at
runtime picks the `amdgpu` CEC device reporting a valid physical address (the TV's
powered port) — no hardcoded device or address, and a cable moved to a different
GPU port re-resolves on the next boot.

### On-device validation checklist (after `rpm-ostree rebase` + reboot)

1. **Resolution:** `systemctl status cec-follower` logs the chosen `/dev/cecN`;
   confirm it is the `amdgpu` device on the TV's port.
2. **Registration:** with the TV on a few seconds, `cec-ctl -d /dev/cec0` shows a
   valid `Physical Address` and a non-zero `Logical Address Mask`. If it ever
   sticks at `0x0000`, `systemctl restart cec-follower`.
3. **No FEATURE_ABORT:** run `cec-follower -m` (or watch the running service) and
   confirm TV polls get replies, not `FEATURE_ABORT`.
4. **Suspend-on-TV-off:** turn the TV off → the PC suspends; on resume there
   should be **no** suspend loop.
5. **Monitor format:** if standby detection stops working, run
   `cec-ctl -d /dev/cec0 --monitor`, turn the TV off, and confirm the received
   line matches the script's `*"TV to all"*"STANDBY"*` pattern. If `--monitor`
   formats it differently than `cec-follower`, adjust `handle_line` in
   `cec-suspend-on-tv-off`.
6. **Outbound (base cec-control):** reboot → TV wakes + switches input
   (`cec-onboot`); poweroff → TV standby (`cec-onpoweroff`). These are the base's
   units; check `/etc/default/cec-control` if they misbehave.

### Developing the CEC scripts

The parsing/resolution and standby-detection logic has offline tests (Bash with
injected `cec-ctl`/`cec-follower`/`systemctl` stubs — no hardware needed):

```bash
bash tests/run.sh            # all unit tests
bash tests/verify-units.sh   # systemd-analyze verify on the unit files
shellcheck -x files/system/usr/libexec/plasma-machine/*
```

## Signing

Images are signed with cosign. `cosign.pub` is committed; the private key is stored
as the `SIGNING_SECRET` GitHub Actions secret and is never committed.
