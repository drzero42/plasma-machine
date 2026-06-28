# Plasma Machine Plymouth Theme — v1 Design

**Date:** 2026-06-28
**Target:** Self-built Steam Machine ("Plasma Machine") running Bazzite, living-room TV (16:9, 1080p).

## Goal

Finish a working, attractive Plymouth boot splash. Existing work (from a prior
session) is broken: the script references a non-existent `spinner.png` and treats
the full-screen art as a tiny centered logo. This spec defines a clean, working v1.

## Assets

- `splash.png` — 1672×941, full composition with a baked-in static circle and
  "POWERING UP" text. **Not used in v1** (kept in folder, unused).
- `splash2.png` — 1672×941, clean logo composition: plasma ball + "PLASMA MACHINE"
  wordmark + decorative bar, on pure black. **This is the v1 background/logo.**

## Design

### Display / layout
- Black window background (`SetBackgroundTopColor`/`BottomColor` = 0,0,0) so the
  art's black background blends seamlessly to screen edges.
- `splash2.png` shown centered as a logo sprite.
- Scale: `scale = min(1.0, screen_w / img_w, screen_h / img_h)` — fit-to-screen,
  never upscaled. On 1080p this yields a crisp, centered image with a thin black
  margin. Degrades gracefully on any resolution. (Intentionally not a forced
  full-bleed for v1.)

### Spinner
- New generated `spinner.png`: a faint full "track" ring plus a bright glowing
  cyan→blue arc (~90°) with soft glow, plasma palette. 256×256, transparent bg.
- Position: horizontally centered; vertically just below the logo's decorative
  bar, computed relative to the logo sprite (`logo_top + logo_h * ~0.80`, tuned
  against a rendered preview).
- Animation: increment rotation each refresh tick via `SetRotation`, wrapping at
  360°, for continuous smooth spin.

### Files changed/created
- `plasma-machine.plymouth` — reference `splash2.png`; config otherwise unchanged.
- `plasma-machine.script` — rewritten: correct fit-scaling + spinner load,
  placement, and rotation.
- `spinner.png` — newly generated.

## Verification

Before any reboot/install: composite a simulated 1920×1080 boot frame
(background + scaled logo + spinner) as a preview PNG to eyeball layout and
spinner placement; iterate on the preview. Then provide Bazzite (atomic/immutable
distro) install instructions: place theme under `/usr/share/plymouth/themes/`,
`plymouth-set-default-theme`, rebuild initramfs.

## Out of scope (future)

- LUKS / disk-encryption password prompt dialog.
- Determinate progress bar.
- Multi-resolution / multi-aspect art variants and forced full-bleed scaling.
