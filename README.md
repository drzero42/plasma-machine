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

## Signing

Images are signed with cosign. `cosign.pub` is committed; the private key is stored
as the `SIGNING_SECRET` GitHub Actions secret and is never committed.
