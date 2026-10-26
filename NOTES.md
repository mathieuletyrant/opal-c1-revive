# Opal C1 — reverse-engineering notes (2026-10-26)

## Hardware / USB
- USB `03e7:f63d` = Intel Movidius **Myriad X**, Luxonis **DepthAI** device in `X_LINK_FLASH_BOOTED` state.
- Interfaces: 0 vendor bulk `S_BULKDATA` (XLink), 1-2 UVC (NV12 3840x2160 / 2560x1440 / 1920x1080 / 1280x720), 3-4 UAC2 mic.
- UVC controls: CT id 1 (AE mode, exposure, focus, autofocus), PU id 3 (brightness, contrast, gain, hue, saturation, sharpness, backlight, anti-flicker, auto-WB), XU id 4 (GUID all-FF, 80 controls, unexplored).
- NOR flash 32 MB (JEDEC 01 02 19). Backup: `backup/opal_c1_fullflash_32MB.bin` (+ .sha256).

## Flash layout
| offset | content |
|---|---|
| 0x000000 | Luxonis USB bootloader. Shipped **0.0.15** (depthai warns `< 0.0.28 susceptible to bootup/restart failure`); upgraded to **0.0.29** on 2026-10-26 |
| 0x0fc000 | bootloader config (usb pid 0xf63c, timeoutMs 0, maxUsbSpeed 3) |
| 0x100000 | SBR app package: `__firmware` (zlib, Opal-custom DepthAI fw), `pipeline` (libnop), `assets`, `asset_storage` |

Extracted in `backup/extracted/`:
- `firmware.mvcmd` — custom Luxonis build: pipeline uses `UAC`, `AudioMic`, `PDAF` nodes that don't exist in public depthai.
- `script.py` — on-device Script node: maps the UVC frame index to an ImageManip resize.
- `camTuning.bin` == app's `Opal582_v2.bin` (IMX582 ISP tuning).
- `blob_facedet.blob` == app's `dd0bad95b2.tlv` (face-detection NN, feeds autofocus).

Pipeline (decoded with `fw/libnop.py`):
```
ColorCamera.isp ──► ImageManip ──► UVC            video path
Script ──► ImageManip.inputConfig                 resolution switch
ColorCamera.preview 300x300 ──► DetectionNetwork (face) ──► PDAF.inFD
ColorCamera.raw + preview ──► PDAF ──► ColorCamera.inputControl   autofocus
AudioMic ──► UAC                                   mic
```
SBR header: "BR" + 17 × 30-byte entries (name[16], size, offset, checksum, type, flags), data from +0x200.
Section checksum = **djb2** (`h = h*33 + b`, seed 5381). Sectors are zero-padded.

## Opal Composer 1.4.4 (still downloadable: updates.opal.camera/release/Opal_Composer_1.4.4_22.dmg)
- `OpalCameraDeviceService.xpc` links **depthai-core 2.15.1** (device fw commit e2929eb3, BL fwp 7958b241). When running, it RAM-boots the camera with its own pipeline over XLink and pushes frames into the CMIO virtual camera (`opalCameraExtension`). The "Flashing device" log message is misleading: it only calls `startPipeline`.
- `+[DeviceUtils resetDevice]`: `libusb_control_transfer(03e7:f63b, 0x00, 0xF5, 0x0DA1)` = standard XLink reset.
- `OpalCameraUVCService.xpc` is for the Tadpole camera, not the C1.

## Tools in this repo
- `app/` — OpalMini: a menu-bar app for UVC controls over IOKit (no root) that also logs 03e7 attach/detach events to `~/Library/Logs/OpalMini.log`. Build: `app/build.sh`. Check: `OpalMini.app/Contents/MacOS/OpalMini --selftest`.
- `backup_flash.py` — read-only flash dump (RAM-boots BL 0.0.29 via the old BL; writes nothing).
- `probe.py` — lists DepthAI devices.
- `flash_bootloader.py` — bootloader upgrade (already applied).
- `fw/patch.py` — builds/flashes/rolls back a pipeline without face detection (built, not flashed yet).
- Run the Python scripts with `uv run --with 'depthai<3' python <script>`.

## Firmware: what can be done
1. Upgrade the bootloader from 0.0.15 to 0.0.29 (official Luxonis, fixes boot/restart hangs). It only touches 0x000000–0x0fffff; the app package is kept. A failed write leaves ROM USB boot (`03e7:2485`), which depthai can recover from.
2. Reflash the app package with changes, e.g. drop the face-detection NN (less heat), change the script or the tuning. The `__firmware` blob would be reused as-is.
3. A from-scratch Myriad X firmware is not realistic: the Intel MDK is proprietary.
