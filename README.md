# opal-c1-revive

Keep the **Opal C1** webcam alive after Opal shut down.

A small macOS menu-bar app to control the camera, the tools to back up and update its flash, and notes on how it works inside.

<p align="center"><code>📷  Opal C1 · Firmware 4.10 · Bootloader 0.0.29</code></p>

## Why

The Opal C1 was a well-made 4K webcam with a premium price. Opal stopped working on it: the Composer app no longer gets updates and the camera's firmware won't change again. Owners are left with:

- a heavy app that still installs a camera extension, background services and analytics, just to adjust a few settings;
- no way to read or change the camera's settings without that app;
- a camera that **drops off USB for 10–15 minutes** at random, with nobody left to fix it.

This project started as a reverse-engineering pass to answer three questions:
1. What is actually inside this camera?
2. Can a tiny native app replace Composer for everyday office use?
3. Can the firmware be maintained without the vendor?

Answers: 1. it's a Luxonis DepthAI module, 2. yes, 3. partly. Details below.

## What's inside

| | |
|---|---|
| SoC | Intel Movidius **Myriad X**, running Luxonis **DepthAI** (`03e7:f63d`) |
| Sensor | Sony IMX582, with a custom ISP tuning blob |
| Flash | 32 MB NOR: Luxonis bootloader + a DepthAI "standalone" app package |
| USB | UVC (NV12 up to 3840×2160), UAC2 mic, vendor bulk (XLink) |

Without Composer, the camera boots its flashed DepthAI pipeline and works as a plain UVC webcam. Composer only re-boots it over XLink with a richer pipeline and pipes the frames through a virtual camera.

The flashed pipeline:

```
ColorCamera.isp ──► ImageManip ──► UVC                         video
Script ──► ImageManip.inputConfig                              resolution switch
ColorCamera.preview ──► DetectionNetwork (face) ──► PDAF       face-weighted autofocus
ColorCamera.raw ──► PDAF ──► ColorCamera.inputControl
AudioMic ──► UAC                                               microphone
```

Some nodes (`PDAF`, `UAC`, `AudioMic`) only exist in Opal's private firmware build. A firmware written from scratch isn't realistic, since the Intel Myriad X SDK is proprietary. The **pipeline**, however, is a documented container format and can be edited safely.

Full findings are in [NOTES.md](NOTES.md).

## OpalMini: the app

A single-file SwiftUI menu-bar app. It uses standard UVC requests through IOKit, needs no root and has no dependencies.

- Live preview, running only while the menu is open
- Brightness, contrast, saturation, sharpness, anti-flicker (50/60 Hz) and autofocus, plus an **Advanced** section for exposure, gain, focus, white balance, hue and backlight
- Remembers your settings and re-applies them whenever the camera reconnects (the camera forgets them on power loss)
- Launch at login
- Logs every attach/detach of the camera to `~/Library/Logs/OpalMini.log`, to help diagnose dropouts
- Shows firmware and bootloader versions

```sh
app/build.sh                      # builds and installs /Applications/OpalMini.app
open /Applications/OpalMini.app
/Applications/OpalMini.app/Contents/MacOS/OpalMini --selftest   # hardware check
```

Requires macOS 13+ and the Xcode command-line tools.

## Flash tools

Every script talks to the camera through the open-source [`depthai`](https://github.com/luxonis/depthai-core) library:

```sh
uv run --with 'depthai<3' python <script>
```

| Script | What it does | Writes to camera? |
|---|---|---|
| `probe.py` | Lists DepthAI devices and their state | no |
| `backup_flash.py` | Dumps the full 32 MB flash to `backup/` | no |
| `flash_bootloader.py` | Upgrades the Luxonis bootloader to 0.0.29 and verifies the app package is untouched | **yes** |
| `fw/patch.py build\|flash\|rollback` | Builds a pipeline without the face-detection network, flashes it, or restores the original | `flash`/`rollback` only |

**Always run `backup_flash.py` first and keep the dump somewhere safe.** It's the only way back to the original firmware.

How the backup works on the shipped 0.0.15 bootloader: that version can't read its own flash, so the script loads the newer bootloader into RAM through the old one and reads from there. Nothing is written.

## Status

- [x] Hardware and protocol identified
- [x] Full flash backup (read-only)
- [x] Bootloader upgraded 0.0.15 → 0.0.29 (Luxonis flags versions before 0.0.28 for boot/restart failures, a likely cause of the dropouts)
- [x] OpalMini app
- [ ] Confirm the cause of the dropouts with the OpalMini log
- [ ] Try the pipeline without face detection (built and checked offline, not flashed yet)
- [ ] Explore the UVC extension unit (80 vendor controls)

## Not included

The flash dump, the extracted firmware and the generated flash blocks are **not** in this repo. They contain proprietary Opal and Luxonis binaries and per-device calibration data. Generate them from your own camera with `backup_flash.py`.

## Disclaimer

This project isn't affiliated with Opal Camera or Luxonis. Flashing your camera is at your own risk. The tools verify every write and keep a rollback path, but a bricked device is always possible.
