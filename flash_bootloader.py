# Upgrades the flashed USB bootloader to depthai's embedded one (0.0.29). Leaves the Opal app package (0x100000+) alone.
# Old BL 0.0.15 lacks newer requests, so we RAM-boot the new BL through it first, then flash from there.
# Writes the result to ~/Library/Application Support/OpalMini/bootloader.txt for OpalMini to display.
import depthai as dai, hashlib, sys, time, pathlib, datetime

def find():
    for _ in range(60):
        for d in dai.Device.getAllAvailableDevices():
            if d.platform == dai.XLinkPlatform.X_LINK_MYRIAD_X: return d
        time.sleep(0.5)
    sys.exit("device not found")

def ver(bl): return tuple(map(int, str(bl.getVersion()).split(".")))

backup = pathlib.Path("backup/opal_c1_fullflash_32MB.bin").read_bytes()
APP = slice(0x100000, 0x1000000)

with dai.DeviceBootloader(find(), allowFlashingBootloader=True) as bl:
    print("flashed BL:", bl.getVersion())
    if ver(bl) < (0, 0, 19):
        bl.bootMemory(dai.DeviceBootloader.getEmbeddedBootloaderBinary(dai.DeviceBootloader.Type.USB))
        time.sleep(2)

with dai.DeviceBootloader(find(), allowFlashingBootloader=True) as bl:
    print("running BL:", bl.getVersion(), "-> flashing", dai.DeviceBootloader.getEmbeddedBootloaderVersion())
    ok, err = bl.flashBootloader(dai.DeviceBootloader.Memory.FLASH, dai.DeviceBootloader.Type.USB,
                                 lambda p: print(f"\rflash {p*100:.0f}%", end=""))
    print()
    if not ok: sys.exit(f"FLASH FAILED: {err}  (device still recoverable over USB; backup in backup/)")

time.sleep(3)
with dai.DeviceBootloader(find()) as bl:  # reboots camera into the freshly flashed BL
    v = str(bl.getVersion()); print("flashed BL now:", v)
    # verify in a fresh session: a readback in the same session as the flash returned stale data
    ok, err, data = bl.readCustom(dai.DeviceBootloader.Memory.FLASH, APP.start, APP.stop - APP.start)
    assert ok and bytes(data) == backup[APP], "Opal app package changed!"
    print("Opal app package intact")
    assert v == str(dai.DeviceBootloader.getEmbeddedBootloaderVersion())
out = pathlib.Path.home() / "Library/Application Support/OpalMini"
out.mkdir(parents=True, exist_ok=True)
(out / "bootloader.txt").write_text(f"{v} ({datetime.date.today()})\n")
print("OK")
