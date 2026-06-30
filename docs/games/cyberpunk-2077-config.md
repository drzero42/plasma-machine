# Cyberpunk 2077 — Plasma Machine Config

GOG version via **Heroic** (Flatpak). 4K120 panel, no VRR (DP→HDMI adapter), so the goal is a steady, well-paced 60.

## Launcher

- Run from **Heroic**, **Desktop Mode** (not Steam Big Picture — that just re-launches Heroic).
- Proton: **proton-cachyos**.

## Heroic settings

**Wine tab**
- Enable the **Wayland driver** (Wine-Wayland). This is what allows true 4K — it bypasses the desktop's 220% scaling. Side effect: in-game "Fullscreen" is gone; use **Borderless** (it's full-screen direct scanout on Wayland, no FPS cost).

**Other tab**
- MangoHud: **off** (causes crashes).
- GameMode: off. Anti-cheat runtimes (EAC/BattlEye): off.

**Advanced → Environment Variables**
```
PROTON_ENABLE_WAYLAND=1
PROTON_USE_OPTISCALER=1
PROTON_FSR4_UPGRADE=1
PROTON_OPTISCALER_CONFIG=Menu.ShortcutKey=0x24;Upscalers.Dx12Upscaler=fsr31
DXVK_FRAME_RATE=60
```

**Advanced → Game arguments**
```
--launcher-skip -skipStartScreen
```
(`--launcher-skip` skips REDlauncher; `-skipStartScreen` skips the breach screen. Intro **logo** videos need the "No Intro Videos" archive mod — they aren't covered by any launch arg.)

## OptiScaler overlay

- Open with **Home** (rebound from Insert via the env var above — compact keyboard has no Insert key).
- **Dx12 Upscaler → fsr31** (already set by the env var; the overlay just confirms it).
- Confirm **`nvngx replacement: Exists`** is shown.
- Frame Generation: **OFF** (interpolated frames judder badly without VRR).

## In-game graphics

- Resolution: **3840×2160**, **Borderless**.
- Upscaling: **AMD FSR 3 → Performance** (internal ~1080p → upscaled to 4K; looks clean at 4K output). No Dynamic Resolution Scaling.
- Ray tracing:
  - Ray-Traced **Reflections: ON** (highest visual value — keep it)
  - Ray-Traced **Lighting: OFF**
  - Ray-Traced **Local Shadows: OFF**
  - Ray-Traced **Sun Shadows: OFF**
  - Path Tracing: OFF
- Frame Generation: **OFF**.

## Result

Steady **60 fps** at 4K, evenly paced, reflections intact.

## Revisit later

The `DXVK_FRAME_RATE=60` cap, FG-off, and Performance preset are all workarounds for **no VRR** on the DP→HDMI adapter. When AMD's native HDMI 2.1 FRL + VRR lands (≈ kernel 7.2) and the adapter can be dropped, re-enable VRR and push FSR toward **Quality** — VRR absorbs the variable framerate, so the cap and the aggressive RT cuts won't be needed.
