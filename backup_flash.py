# Read-only flash backup. Old flashed BL (0.0.15) can't ReadFlash, so we RAM-boot the
# newer embedded BL through it (bootMemory), then read. Nothing is written to flash.
import depthai as dai, hashlib, sys, time
size = int(sys.argv[1], 0) if len(sys.argv) > 1 else 0

def find():
    for _ in range(40):
        for d in dai.Device.getAllAvailableDevices():
            if d.platform == dai.XLinkPlatform.X_LINK_MYRIAD_X: return d
        time.sleep(0.5)
    sys.exit("device not found")

info = find(); print("state", info.state)
with dai.DeviceBootloader(info, allowFlashingBootloader=False) as bl:
    print("bootloader", bl.getVersion())
    if tuple(map(int, str(bl.getVersion()).split("."))) < (0, 0, 19):
        bl.bootMemory(dai.DeviceBootloader.getEmbeddedBootloaderBinary(dai.DeviceBootloader.Type.USB))
        time.sleep(2)
if 'bl' in dir(): del bl
info = find(); print("state", info.state)
with dai.DeviceBootloader(info, allowFlashingBootloader=False) as bl:
    print("bootloader now", bl.getVersion())
    try: m = bl.getMemoryInfo(dai.DeviceBootloader.Memory.FLASH); print("flash:", m.available, m.size, m.info); size = size or m.size
    except Exception as e: print("meminfo:", e)
    ok, err, data = bl.readCustom(dai.DeviceBootloader.Memory.FLASH, 0, size, lambda p: print(f"\r{p*100:.0f}%", end=""))
    print()
    if not ok: sys.exit(f"read failed: {err}")
    blob = bytes(data)
    open(f"backup/opal_c1_flash_{size:#x}.bin", "wb").write(blob)
    print("dumped", len(blob), "sha256", hashlib.sha256(blob).hexdigest())
