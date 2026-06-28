# Plasma Machine

Custom **Bazzite Deck (KDE)** OS image for a self-built Steam Machine ("Plasma
Machine") in the living room. Hardware: **AMD**. Built from
`ghcr.io/ublue-os/bazzite-deck:stable` with [BlueBuild](https://blue-build.org).
The first customization is a custom **Plymouth boot splash**; the repo is meant to
grow into the machine's full image definition (packages, tweaks, etc.).

## Critical constraint: this is an atomic/immutable OS

`/usr` is **read-only at runtime**. Changes made live (`ostree admin unlock`,
`rpm-ostree usroverlay`) do **not** survive — in particular, anything that needs
the initramfs regenerated (like a Plymouth theme) is lost on the next deployment.

**Therefore: all OS changes go through the image.** Edit the recipe/files, push,
let CI build & publish, then `rpm-ostree rebase` on the machine. Never instruct the
user to hand-edit `/usr` on the box as a persistent fix.

## Layout

- `recipes/recipe.yml` — BlueBuild recipe. Modules in order:
  1. `dnf` — layers `plymouth-plugin-script`. **Required:** the Bazzite base image
     ships Plymouth without `/usr/lib64/plymouth/script.so`, so a script-renderer
     theme can't be set without it (`plymouth-set-default-theme` errors otherwise).
  2. `files` — copy the theme + config into the image.
  3. `script` — `plymouth-set-default-theme plasma-machine`.
  4. `initramfs` — regenerate, baking the theme into early boot.
  5. `signing` — install the cosign verification policy.
- `files/system/usr/share/plymouth/themes/plasma-machine/` — the Plymouth theme,
  copied verbatim to `/usr/share/plymouth/themes/plasma-machine/`.
- `files/system/etc/plymouth/plymouthd.conf` — sets `Theme=plasma-machine` for the
  runtime (shutdown) splash; see the startup-vs-shutdown note below.
- `.github/workflows/build.yml` — CI: builds on push to `main`, PRs, daily cron
  (track upstream), and manual dispatch. Publishes `ghcr.io/<owner>/plasma-machine`.
- `cosign.pub` — public signing key (committed). Private key is the `SIGNING_SECRET`
  repo secret; `cosign.key` is gitignored and must never be committed.
- `devenv.nix` — toolchain (`cosign`, `jq`, `gh`). `devenv shell` or direnv.
- `docs/superpowers/specs/` — design specs.

## The Plymouth theme

Script-module theme. `plasma-machine.script`:
- Centers `splash2.png` (the clean logo composition; `splash.png` is the older
  variant with a baked-in circle, kept but unused). Scale = fit-to-screen, never
  upscaled.
- Spinner: `spinner.png` (a generated glowing arc ring). Pre-renders `NUM_FRAMES`
  rotated frames via `Image.Rotate()` and re-centers each tick — rotates in place.
  Positioned just below the wordmark bar.
- Tunables in the script: spinner size (`logo.disp_h * 0.11`), vertical position
  (`logo.disp_h * 0.86`), speed (`NUM_FRAMES`).

`spinner.png` was generated with ImageMagick (faint track ring + bright glowing
cyan arc, rounded caps). Regenerate by editing and re-running the ImageMagick draw
commands, then re-verify layout by compositing a simulated boot frame before push.

**Startup vs shutdown read the theme from different places.** Startup Plymouth
runs from the initramfs (baked by the `initramfs` module → correct theme).
Shutdown/reboot Plymouth runs from the real root and reads
`/etc/plymouth/plymouthd.conf`; if that file is missing it falls back to Bazzite's
default (`bgrt`). So the image ships
`files/system/etc/plymouth/plymouthd.conf` with `Theme=plasma-machine` to make the
shutdown splash match. (If a machine has a tracked ostree deletion of that file
from earlier manual tinkering, the image copy is shadowed — recreate it locally.)

## Verifying changes

There is no way to see the real boot splash from CI. Before pushing, verify layout
by compositing a simulated boot frame with ImageMagick. To see the live animation,
the user can preview on the machine after rebase: `sudo plymouthd; sudo plymouth
--show-splash; sleep 8; sudo plymouth --quit` (best from a TTY).

## Deploy (on the machine)

```bash
# first rebase (policy not yet present → unverified):
rpm-ostree rebase ostree-unverified-registry:ghcr.io/drzero42/plasma-machine:latest
systemctl reboot
# then switch to the signed ref:
rpm-ostree rebase ostree-image-signed:docker://ghcr.io/drzero42/plasma-machine:latest
```

After the first unverified→signed switch, all future updates just track the signed
`:latest` ref automatically. Rollback is via ostree deployments (`rpm-ostree
rollback` or the boot menu), not the tag — so the rolling `:latest` target is the
intended pattern here, not a smell.

If migrating a machine that was previously hand-tinkered: a locally layered
`plymouth-plugin-script` collides with this image's base copy — drop it in the same
transaction (`rpm-ostree rebase <ref> --uninstall plymouth-plugin-script`). And a
prior `rm` of `/etc/plymouth/plymouthd.conf` leaves a tracked ostree deletion that
shadows the image's copy; recreate the file locally if the shutdown splash reverts
to `bgrt`.

## Update cadence

- **Image rebuilds:** on every push to `main` (non-`.md`), plus a daily `06:00 UTC`
  cron that re-derives from upstream `bazzite-deck:stable` (this is what pulls in
  upstream Bazzite updates), plus manual dispatch. Caveat: GitHub auto-disables
  scheduled workflows after 60 days of repo inactivity — re-enable in the Actions
  tab if the daily build stops.
- **Machine pulls:** via the Universal Blue updater (`uupd`) on a systemd timer
  (~daily). Inspect with `systemctl list-timers | grep -i uupd`; force now with
  `ujust update` or `rpm-ostree upgrade`.
