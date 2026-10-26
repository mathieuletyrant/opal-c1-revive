"""Minimal libnop codec (the serializer DepthAI uses for pipelines). Decode -> python, encode -> identical bytes."""
import struct

class Struct(list): pass          # 0xb9
class Map(list): pass             # 0xbb, list of (k, v)
class Variant(tuple): pass        # 0xb6 (index, value)
class Raw(bytes): pass            # 0xbc binary
class Num:                        # keeps the exact encoding byte for round-trip
    def __init__(s, tag, v): s.tag, s.v = tag, v
    def __repr__(s): return repr(s.v)

INT = {0x80: "<B", 0x81: "<H", 0x82: "<I", 0x83: "<Q", 0x84: "<b", 0x85: "<h", 0x86: "<i", 0x87: "<q", 0x88: "<f", 0x89: "<d"}

def decode(b, i=0):
    t = b[i]; i += 1
    if t <= 0x7f: return Num(None, t), i
    if t >= 0xc0: return Num(None, t - 0x100), i
    if t in INT:
        f = INT[t]; n = struct.calcsize(f)
        return Num(t, struct.unpack_from(f, b, i)[0]), i + n
    if t in (0xb9, 0xba, 0xbb, 0xbc, 0xbd):
        n, i = decode(b, i); n = n.v
        if t == 0xbd: return b[i:i + n].decode(), i + n
        if t == 0xbc: return Raw(b[i:i + n]), i + n
        out = []
        for _ in range(n):
            if t == 0xbb:
                k, i = decode(b, i); v, i = decode(b, i); out.append((k, v))
            else:
                v, i = decode(b, i); out.append(v)
        return {0xb9: Struct, 0xba: list, 0xbb: Map}[t](out), i
    if t == 0xbe: return None, i     # Nil (empty std::optional)
    if t == 0xb6:
        idx, i = decode(b, i); v, i = decode(b, i); return Variant((idx, v)), i
    raise ValueError(f"unknown tag {t:#x} at {i-1}")

def enc_int(v, tag=None):
    if tag is None:
        if 0 <= v <= 0x7f: return bytes([v])
        if -64 <= v < 0: return bytes([v + 0x100])
        tag = 0x80 if 0 <= v <= 0xff else 0x81 if 0 <= v <= 0xffff else 0x82 if 0 <= v <= 0xffffffff else 0x87
    return bytes([tag]) + struct.pack(INT[tag], v)

def encode(x):
    if x is None: return b"\xbe"
    if isinstance(x, Num): return enc_int(x.v, x.tag)
    if isinstance(x, str): e = x.encode(); return b"\xbd" + enc_int(len(e)) + e
    if isinstance(x, Raw): return b"\xbc" + enc_int(len(x)) + bytes(x)
    if isinstance(x, Variant): return b"\xb6" + encode(x[0]) + encode(x[1])
    if isinstance(x, Map): return b"\xbb" + enc_int(len(x)) + b"".join(encode(k) + encode(v) for k, v in x)
    if isinstance(x, Struct): return b"\xb9" + enc_int(len(x)) + b"".join(map(encode, x))
    if isinstance(x, list): return b"\xba" + enc_int(len(x)) + b"".join(map(encode, x))
    raise TypeError(type(x))

if __name__ == "__main__":  # round-trip check on the real dumped pipeline
    import sys
    raw = open(sys.argv[1] if len(sys.argv) > 1 else "../backup/extracted/pipeline.bin", "rb").read()
    v, end = decode(raw)
    assert end == len(raw), (end, len(raw))
    assert encode(v) == raw, "round-trip mismatch"
    print("libnop round-trip OK", len(raw), "bytes")
