# Stable + testing image channels — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish a `testing`-channel variant of the Plasma Machine image alongside the existing stable one, as tags on the same GHCR package.

**Architecture:** One GHCR package (`plasma-machine`), two channels expressed as tags. Two thin recipes (`recipe.yml` for stable, `recipe-testing.yml` for testing) share their module pipeline via a `from-file: modules.yml` include. The channel difference is two fields: `image-version` and `alt-tags`. CI builds both via the existing build matrix.

**Tech Stack:** BlueBuild recipe YAML, GitHub Actions (`blue-build/github-action`), cosign signing.

## Global Constraints

- Both recipes MUST keep `name: plasma-machine` so they publish to the same GHCR package (channels are tags, not separate packages).
- `latest` MUST remain bound to the **stable** channel only — the existing deploy ref `plasma-machine:latest` must keep working with no machine migration.
- `alt-tags` overrides BlueBuild's default `latest`+timestamp tagging, so any recipe using `alt-tags` must list every plain tag it needs explicitly.
- Stable tags: `alt-tags: [latest, stable]`. Testing tags: `alt-tags: [testing]`.
- The shared module file is a **bare YAML list** (no top-level `modules:` key); `from-file` paths resolve relative to `recipes/`.
- Module order is unchanged from today: dnf → files → script → initramfs → signing.
- No changes to the Plymouth theme, the Steam Controller wakeup rule, or signing config. No separate GHCR packages. No per-channel customization divergence.
- This repo has no local YAML/BlueBuild build tooling; the authoritative verification is the CI build. Local steps verify structure via `git diff` and `grep`.

---

### Task 1: Extract shared modules and convert stable recipe to `from-file` + `alt-tags`

Pull the current 5-module pipeline out of `recipe.yml` into a reusable `recipes/modules.yml`, then rewrite `recipe.yml` to reference it and add the stable `alt-tags`. This task leaves the stable image's *content* and `image-version: stable` unchanged — only how the recipe is structured and tagged changes.

**Files:**
- Create: `recipes/modules.yml`
- Modify: `recipes/recipe.yml`

**Interfaces:**
- Produces: `recipes/modules.yml` — a bare YAML list of BlueBuild modules, consumed by both `recipe.yml` and (Task 2) `recipe-testing.yml` via `- from-file: modules.yml`.

- [ ] **Step 1: Create the shared module list**

Create `recipes/modules.yml` with exactly the modules currently in `recipe.yml`, as a bare list (no `modules:` key):

```yaml
# yaml-language-server: $schema=https://schema.blue-build.org/modules-v1.json
# Shared module pipeline for all Plasma Machine channels (stable + testing).
# Included by recipes/recipe.yml and recipes/recipe-testing.yml via `from-file`.
# Bare list: no top-level `modules:` key. Order matters.

# 1. The theme uses the Plymouth "script" renderer, whose plugin
#    (/usr/lib64/plymouth/script.so) is not in the Bazzite base image. Layer it.
- type: dnf
  install:
    packages:
      - plymouth-plugin-script

# 2. Copy everything under files/system/* into the image root (/).
#    This places the theme at /usr/share/plymouth/themes/plasma-machine/.
- type: files
  files:
    - source: system
      destination: /

# 3. Make it the default Plymouth theme.
- type: script
  snippets:
    - "plymouth-set-default-theme plasma-machine"

# 4. Regenerate the initramfs so the theme is present at early boot.
#    (This is the step that cannot persist when done at runtime on an atomic system.)
- type: initramfs

# 5. Install the cosign signing policy so signed pulls verify against cosign.pub.
- type: signing
```

- [ ] **Step 2: Rewrite the stable recipe to use the shared list + stable alt-tags**

Replace the entire contents of `recipes/recipe.yml` with:

```yaml
# yaml-language-server: $schema=https://schema.blue-build.org/recipe-v1.json
# Stable channel. Published to ghcr.io/<owner>/plasma-machine with tags
# `latest` and `stable` (plus version/timestamp/sha variants).
name: plasma-machine
description: Custom Bazzite Deck (KDE) image for the Plasma Machine, with the Plasma Machine boot splash.

# Base image (FROM) and channel tag. "stable" tracks the Bazzite stable channel.
base-image: ghcr.io/ublue-os/bazzite-deck
image-version: stable

# Channel tags. alt-tags OVERRIDES BlueBuild's default latest+timestamp tagging,
# so `latest` is listed explicitly to keep the existing deploy ref working.
alt-tags:
  - latest
  - stable

# Module pipeline is shared with the testing channel; see recipes/modules.yml.
modules:
  - from-file: modules.yml
```

- [ ] **Step 3: Verify the stable recipe still declares the right name, version, and tags**

Run:
```bash
grep -E '^(name|image-version):' recipes/recipe.yml && grep -A2 '^alt-tags:' recipes/recipe.yml && grep 'from-file' recipes/recipe.yml
```
Expected output contains:
```
name: plasma-machine
image-version: stable
alt-tags:
  - latest
  - stable
  - from-file: modules.yml
```

- [ ] **Step 4: Verify the shared module list is a bare list with all 5 modules in order**

Run:
```bash
grep -nE '^- type:|^- type: initramfs' recipes/modules.yml
```
Expected: five `- type:` lines, in order `dnf`, `files`, `script`, `initramfs`, `signing`. Confirm there is **no** `modules:` line in the file:
```bash
grep -c '^modules:' recipes/modules.yml
```
Expected: `0`

- [ ] **Step 5: Commit**

```bash
git add recipes/modules.yml recipes/recipe.yml
git commit -m "refactor(recipe): share modules via from-file; tag stable as latest+stable"
```

---

### Task 2: Add the testing recipe

Add `recipe-testing.yml` — identical to stable except it tracks the upstream testing channel and tags only `testing`.

**Files:**
- Create: `recipes/recipe-testing.yml`

**Interfaces:**
- Consumes: `recipes/modules.yml` (Task 1) via `- from-file: modules.yml`.

- [ ] **Step 1: Create the testing recipe**

Create `recipes/recipe-testing.yml`:

```yaml
# yaml-language-server: $schema=https://schema.blue-build.org/recipe-v1.json
# Testing channel. Published to ghcr.io/<owner>/plasma-machine with the `testing`
# tag (plus version/timestamp/sha variants). Same package as stable — channels
# are tags, not separate packages. `latest` stays bound to the stable channel.
name: plasma-machine
description: Custom Bazzite Deck (KDE) image for the Plasma Machine, tracking the Bazzite testing channel.

# Base image (FROM) and channel tag. "testing" tracks the Bazzite testing channel.
base-image: ghcr.io/ublue-os/bazzite-deck
image-version: testing

# Channel tags. alt-tags OVERRIDES BlueBuild's default latest+timestamp tagging.
# Only `testing` here — `latest` must stay on the stable channel.
alt-tags:
  - testing

# Module pipeline is shared with the stable channel; see recipes/modules.yml.
modules:
  - from-file: modules.yml
```

- [ ] **Step 2: Verify the testing recipe has matching name, testing version, and testing-only tag**

Run:
```bash
grep -E '^(name|image-version):' recipes/recipe-testing.yml && grep -A1 '^alt-tags:' recipes/recipe-testing.yml && grep 'from-file' recipes/recipe-testing.yml
```
Expected output contains:
```
name: plasma-machine
image-version: testing
alt-tags:
  - testing
  - from-file: modules.yml
```

- [ ] **Step 3: Verify `latest` is NOT present in the testing recipe**

Run:
```bash
grep -c 'latest' recipes/recipe-testing.yml
```
Expected: `0`

- [ ] **Step 4: Commit**

```bash
git add recipes/recipe-testing.yml
git commit -m "feat(recipe): add testing channel recipe (plasma-machine:testing)"
```

---

### Task 3: Build both channels in CI

Add the testing recipe to the existing build matrix so both channels build on every trigger.

**Files:**
- Modify: `.github/workflows/build.yml:35-36`

- [ ] **Step 1: Add the testing recipe to the matrix**

In `.github/workflows/build.yml`, change the matrix `recipe` list from:

```yaml
        recipe:
          - recipe.yml
```
to:
```yaml
        recipe:
          - recipe.yml
          - recipe-testing.yml
```

(Leave `fail-fast: false` and everything else unchanged — a testing breakage must not block stable, which `fail-fast: false` already guarantees.)

- [ ] **Step 2: Verify both recipes are in the matrix**

Run:
```bash
grep -A3 'recipe:' .github/workflows/build.yml | grep -E 'recipe(-testing)?\.yml'
```
Expected:
```
          - recipe.yml
          - recipe-testing.yml
```

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/build.yml
git commit -m "ci: build stable and testing channels in the matrix"
```

---

### Task 4: Document the two channels

Update `CLAUDE.md` so the layout, tagging scheme, and deploy instructions reflect both channels.

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update the Layout section**

In `CLAUDE.md`, find the `- `recipes/recipe.yml` — BlueBuild recipe...` bullet at the top of the **Layout** section and replace that single bullet with:

```markdown
- `recipes/recipe.yml` & `recipes/recipe-testing.yml` — BlueBuild recipes for the
  **stable** and **testing** channels. Both share `recipes/modules.yml` (a bare
  module list) via `from-file`, so the customization pipeline can't drift between
  channels. They differ only in `image-version` (`stable` vs `testing`) and
  `alt-tags`. Modules in order:
  1. `dnf` — layers `plymouth-plugin-script`. **Required:** the Bazzite base image
     ships Plymouth without `/usr/lib64/plymouth/script.so`, so a script-renderer
     theme can't be set without it (`plymouth-set-default-theme` errors otherwise).
  2. `files` — copy the theme + config into the image.
  3. `script` — `plymouth-set-default-theme plasma-machine`.
  4. `initramfs` — regenerate, baking the theme into early boot.
  5. `signing` — install the cosign verification policy.
- `recipes/modules.yml` — the shared module pipeline (bare YAML list, no
  top-level `modules:` key), included by both recipes via `- from-file: modules.yml`.
```

- [ ] **Step 2: Add a Channels/tags note to the Layout section**

Immediately after the `recipes/modules.yml` bullet added in Step 1, add:

```markdown
- **Channels are tags, not separate packages.** Both recipes use `name:
  plasma-machine`, so they publish to one GHCR package. Tags: `latest` + `stable`
  → stable channel; `testing` → testing channel. `alt-tags` overrides BlueBuild's
  default `latest`+timestamp tags, which is why the stable recipe lists `latest`
  explicitly. `latest` always tracks stable, so the existing deploy ref keeps
  working.
```

- [ ] **Step 3: Add the testing rebase snippet to the Deploy section**

In the **Deploy (on the machine)** section, after the existing signed-ref rebase block, add:

```markdown
To put a machine on the **testing** channel instead, substitute the `:testing`
tag (same unverified→signed bootstrap as stable):

```bash
rpm-ostree rebase ostree-image-signed:docker://ghcr.io/drzero42/plasma-machine:testing
systemctl reboot
```
```

- [ ] **Step 4: Update the Update cadence section**

In the **Update cadence** section, in the **Image rebuilds** bullet, append a sentence noting both channels build together:

```markdown
  Every build trigger (push, PR, daily cron, manual dispatch) builds **both** the
  stable and testing channels via the workflow matrix; `fail-fast: false` keeps a
  testing-channel break from blocking the stable build.
```

- [ ] **Step 5: Verify the docs mention both recipes, the tag scheme, and the testing deploy**

Run:
```bash
grep -E 'recipe-testing\.yml|modules\.yml|:testing|alt-tags' CLAUDE.md
```
Expected: matches for `recipe-testing.yml`, `modules.yml`, the `:testing` rebase ref, and the `alt-tags` explanation.

- [ ] **Step 6: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: document stable + testing channels and tag scheme"
```

---

### Task 5: Verify in CI after push

The only place a real BlueBuild build runs. This task confirms the matrix produces both channels and the testing tag lands in GHCR.

**Files:** none (verification only).

- [ ] **Step 1: Push the branch and open/observe the build**

```bash
git push
```
If working on a branch, open a PR to `main` (PRs trigger the build). On `main`, the push triggers it directly.

- [ ] **Step 2: Confirm the matrix ran two jobs**

Run:
```bash
gh run list --workflow build.yml --limit 1
gh run view --log | grep -iE 'recipe-testing\.yml|recipe\.yml' | head
```
Expected: the latest run shows two build jobs (one per recipe), both succeeding.

- [ ] **Step 3: Confirm both channel tags exist in GHCR**

After a successful `main` build, run:
```bash
gh api "/users/drzero42/packages/container/plasma-machine/versions" --jq '[.[].metadata.container.tags[]] | unique' 2>/dev/null | grep -E 'latest|stable|testing'
```
Expected: the tag set includes `latest`, `stable`, and `testing`.
(If the package is under an org rather than a user, use `/orgs/drzero42/...`.)

- [ ] **Step 4: (Optional, on the machine) smoke-test the testing rebase**

On the Plasma Machine, optionally verify the testing image pulls and verifies:
```bash
rpm-ostree rebase ostree-unverified-registry:ghcr.io/drzero42/plasma-machine:testing
```
Expected: pulls successfully. Roll back with `rpm-ostree rollback` if you don't intend to stay on testing.

---

## Self-Review

**Spec coverage:**
- Channels-as-tags / `alt-tags` scheme → Tasks 1 & 2 (Global Constraints + recipe content).
- Stable `[latest, stable]`, testing `[testing]`, `latest`→stable → Tasks 1, 2 (with negative-assertion verification steps).
- DRY via `from-file` + bare-list `modules.yml` → Task 1.
- Both recipes keep `name: plasma-machine` → Tasks 1, 2 verification steps.
- CI matrix builds both, `fail-fast: false` → Task 3.
- Signing applies to both → unchanged (signing is in shared `modules.yml`; no task needed beyond Task 1).
- Deploy snippet for testing → Task 4 Step 3.
- Docs (layout, tag scheme, deploy, cadence) → Task 4.
- Real verification only in CI → Task 5.
- Testing recipe `description:` wording ("…tracking the Bazzite testing channel.") → Task 2 Step 1.

**Placeholder scan:** No TBD/TODO/"add appropriate…" — every file's full content is given verbatim.

**Type/name consistency:** `name: plasma-machine` and `from-file: modules.yml` are identical across Tasks 1 and 2; tag sets match the spec table; module order matches the original recipe.
