# Packs PNGs into an .icns (iconutil rejects the NSBitmapImageRep PNGs on this machine).
import struct, sys, subprocess, tempfile, os
src, out = sys.argv[1], sys.argv[2]
types = [("icp4", 16), ("icp5", 32), ("icp6", 64), ("ic07", 128), ("ic08", 256), ("ic09", 512),
         ("ic10", 1024), ("ic11", 32), ("ic12", 64), ("ic13", 256), ("ic14", 512)]
chunks = b""
with tempfile.TemporaryDirectory() as d:
    for t, s in types:
        p = os.path.join(d, f"{s}.png")
        if not os.path.exists(p):
            subprocess.run(["sips", "-z", str(s), str(s), src, "--out", p], check=True, capture_output=True)
        data = open(p, "rb").read()
        chunks += t.encode() + struct.pack(">I", len(data) + 8) + data
open(out, "wb").write(b"icns" + struct.pack(">I", len(chunks) + 8) + chunks)
