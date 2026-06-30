# Stable + testing image channels

## Goal

Produce two customized Plasma Machine images from one repo:

- a **stable** channel that tracks `bazzite-deck:stable` (today's behavior), and
- a **testing** channel that tracks `bazzite-deck:testing`.

Both carry the identical Plasma Machine customizations (Plymouth theme, Steam
Controller wakeup rule, signing, etc.) and differ only in which upstream Bazzite
channel they derive from.

## Channels as tags, not separate packages

The two channels are published as **tags on a single GHCR package**
(`ghcr.io/<owner>/plasma-machine`), mirroring how upstream expresses channels
(`bazzite-deck:stable` / `bazzite-deck:testing`). They are *not* separate
packages.

BlueBuild derives the package name from a recipe's `name:` field, so both recipes
keep `name: plasma-machine`. The tag distinction comes from the BlueBuild
`alt-tags` field:

| Channel | Recipe              | `image-version` | `alt-tags`         | Resulting tags (incl. version/timestamp/sha variants) |
| ------- | ------------------- | --------------- | ------------------ | ----------------------------------------------------- |
| stable  | `recipe.yml`        | `stable`        | `[latest, stable]` | `latest`, `stable`, `*-latest-*`, `*-stable-*`        |
| testing | `recipe-testing.yml`| `testing`       | `[testing]`        | `testing`, `*-testing-*`                              |

Notes:

- `alt-tags` **overrides** BlueBuild's default `latest` + timestamp tagging. So
  the stable recipe must list `latest` explicitly to keep the existing deploy ref
  (`plasma-machine:latest`) working — that is why stable is `[latest, stable]`,
  not just `[stable]`.
- `latest` stays bound to **stable** only. Testing never publishes `latest`.
- BlueBuild still emits the version/timestamp/commit-sha suffixed variants
  alongside each listed tag, so per-build pinning/rollback references remain
  available on both channels.

## DRY recipe structure via `from-file`

The two recipes are identical except for `image-version` and `alt-tags`. The
shared 5-module pipeline lives in one file so a theme/module change can't drift
between channels.

- `recipes/modules.yml` *(new)* — the module list as a **bare YAML list** (no
  top-level `modules:` key), in the order required today:
  1. `dnf` install `plymouth-plugin-script`
  2. `files` copy `system/*` → `/`
  3. `script` run `plymouth-set-default-theme plasma-machine`
  4. `initramfs` regenerate
  5. `signing` install the cosign policy
- `recipes/recipe.yml` *(edited)* — stable:
  ```yaml
  name: plasma-machine
  description: Custom Bazzite Deck (KDE) image for the Plasma Machine, with the Plasma Machine boot splash.
  base-image: ghcr.io/ublue-os/bazzite-deck
  image-version: stable
  alt-tags:
    - latest
    - stable
  modules:
    - from-file: modules.yml
  ```
- `recipes/recipe-testing.yml` *(new)* — testing: same as above but
  `image-version: testing`, `alt-tags: [testing]`, and a description noting the
  testing channel.

`from-file` resolves relative to `recipes/`, so the reference is just
`modules.yml`.

## CI workflow change

`.github/workflows/build.yml` already builds via a matrix over `recipe`. Add the
testing recipe:

```yaml
matrix:
  recipe:
    - recipe.yml
    - recipe-testing.yml
```

Behavioral consequences (all desired, no other workflow changes needed):

- Both channels rebuild on every push to `main` (non-`.md`), PRs, the daily
  `06:00 UTC` cron (which is what pulls in upstream channel updates), and manual
  dispatch.
- `fail-fast: false` is already set, so a testing-channel breakage (e.g. upstream
  `bazzite-deck:testing` churn) does **not** block the stable build.
- Both recipes are signed with the same `SIGNING_SECRET` cosign key. The cosign
  policy (`cosign.pub`) verifies by image **name**, which is identical for both
  channels, so every tag verifies against the one committed key.

## Deploy

Stable is unchanged (`plasma-machine:latest`). To put a machine on testing:

```bash
rpm-ostree rebase ostree-image-signed:docker://ghcr.io/drzero42/plasma-machine:testing
systemctl reboot
```

(First-time/unverified bootstrap and the unverified→signed switch follow the same
pattern as stable, substituting the `:testing` tag.)

## Docs

Update `CLAUDE.md`:

- Layout section: two recipes (`recipe.yml`, `recipe-testing.yml`) sharing
  `recipes/modules.yml` via `from-file`.
- Note the `:latest`/`:stable` vs `:testing` tag scheme and that `latest` tracks
  stable.
- Add the testing rebase snippet to the deploy section.

## Out of scope

- No change to the theme, the Steam Controller wakeup rule, or signing.
- No separate GHCR packages.
- No per-channel divergence in customizations — both channels are intended to stay
  identical apart from the upstream base channel.
