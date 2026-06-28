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

## Signing

Images are signed with cosign. `cosign.pub` is committed; the private key is stored
as the `SIGNING_SECRET` GitHub Actions secret and is never committed.
