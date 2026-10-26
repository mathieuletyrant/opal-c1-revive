"""Patch the Opal C1 flashed app: remove the face-detection NN (only used to bias autofocus).

    python fw/patch.py build      # writes fw/out/*.bin, touches nothing on the device
    python fw/patch.py flash      # writes the 2 patched 4 KB blocks, verifies in a fresh session
    python fw/patch.py rollback   # writes the original 2 blocks back from the backup

Run flash/rollback with: uv run --with 'depthai<3' python fw/patch.py flash
Only the SBR header block and the pipeline block change; firmware, assets and bootloader stay byte-identical.
"""
import struct, sys, time, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).parent))
from libnop import decode, encode, Map, Struct

ROOT = pathlib.Path(__file__).parent
BACKUP = (ROOT / "../backup/opal_c1_fullflash_32MB.bin").read_bytes()
APP = 0x100000          # SBR package start in flash
BLOCK = 0x1000          # flash erase sector
SECTION = 30            # SBR entry: name[16], size u32, offset u32, checksum u32, type u8, flags u8

def djb2(d):
    h = 5381
    for b in d: h = (h * 33 + b) & 0xFFFFFFFF
    return h

def sections(img):
    p, out = APP + 2, {}
    while (name := img[p:p + 16].split(b"\0")[0].decode()):
        size, off, ck = struct.unpack_from("<III", img, p + 16)
        out[name] = (p, size, off, ck)
        p += SECTION
    return out

def without_face_detection(raw):
    conns, glob, nodes = decode(raw)[0]
    fd = [k.v for k, n in nodes if "DetectionNetwork" in n]
    assert fd == [5], fd
    nodes = Map((k, n) for k, n in nodes if k.v not in fd)
    conns = [c for c in conns if c[0].v not in fd and c[3].v not in fd]
    assert len(conns) == 7, len(conns)
    return encode(Struct([conns, glob, nodes]))

def build():
    secs = sections(BACKUP)
    hdr_at, size, off, ck = secs["pipeline"]
    old = BACKUP[APP + off:APP + off + size]
    assert djb2(old) == ck, "backup pipeline checksum mismatch"
    new = without_face_detection(old)

    header = bytearray(BACKUP[APP:APP + BLOCK])
    struct.pack_into("<I", header, hdr_at - APP + 16, len(new))
    struct.pack_into("<I", header, hdr_at - APP + 24, djb2(new))
    pipe_at = APP + off
    assert pipe_at % BLOCK == 0
    pipe = bytearray(BACKUP[pipe_at:pipe_at + BLOCK])
    assert size <= BLOCK and set(pipe[size:]) == {0x00}  # original writer zero-pads the sector
    pipe[:size] = bytes(size)
    pipe[:len(new)] = new

    # self-check: the patched image parses, checksums hold, and nothing else moved
    img = bytearray(BACKUP); img[APP:APP + BLOCK] = header; img[pipe_at:pipe_at + BLOCK] = pipe
    s2 = sections(bytes(img))
    for name, (_, sz, of, c) in s2.items():
        assert djb2(img[APP + of:APP + of + sz]) == c, name
    assert {k: v for k, v in s2.items() if k != "pipeline"} == {k: v for k, v in secs.items() if k != "pipeline"}
    print(f"pipeline {size} -> {len(new)} bytes, checksums OK, other sections unchanged")
    return {APP: bytes(header), pipe_at: bytes(pipe)}

def original():
    return {a: BACKUP[a:a + BLOCK] for a in build()}

def write(blocks):
    import depthai as dai
    def find():
        for _ in range(60):
            for d in dai.Device.getAllAvailableDevices():
                if d.platform == dai.XLinkPlatform.X_LINK_MYRIAD_X: return d
            time.sleep(0.5)
        sys.exit("device not found")
    with dai.DeviceBootloader(find()) as bl:
        assert str(bl.getVersion()) >= "0.0.19", bl.getVersion()
        for addr, data in blocks.items():
            ok, err = bl.flashCustom(dai.DeviceBootloader.Memory.FLASH, addr, list(data))
            if not ok: sys.exit(f"write {addr:#x} failed: {err} -- run rollback")
            print(f"wrote {addr:#x}")
    time.sleep(3)
    with dai.DeviceBootloader(find()) as bl:  # fresh session: same-session readback returned stale data before
        for addr, data in blocks.items():
            ok, err, got = bl.readCustom(dai.DeviceBootloader.Memory.FLASH, addr, len(data))
            assert ok and bytes(got) == data, f"verify {addr:#x} failed -- run rollback"
    print("verified; camera reboots into the app when this exits")

if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "build"
    blocks = build()
    if cmd == "build":
        (ROOT / "out").mkdir(exist_ok=True)
        for a, d in blocks.items(): (ROOT / f"out/block_{a:#x}.bin").write_bytes(d)
        print("built", [f"{a:#x}" for a in blocks])
    elif cmd == "flash": write(blocks)
    elif cmd == "rollback": write(original())
    else: sys.exit(__doc__)
