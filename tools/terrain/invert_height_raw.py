"""One-time tool: convert RGBAF .raw heightmaps so that peak = 0 (UE convention)."""
import os
import struct
from pathlib import Path

def invert(filepath, w=256, h=256):
    pix = w * h
    fpp = 4  # R,G,B,A
    total = pix * fpp
    with open(filepath, "rb") as f:
        raw = f.read()
    if len(raw) != total * 4:
        print(f"ERROR: size {len(raw)}, expected {total * 4}")
        return
    vals = list(struct.unpack(f"<{total}f", raw))
    peak = max((vals[i] for i in range(0, total, fpp) if vals[i] > -10000), default=None)
    if peak is None:
        print("No valid pixels found"); return
    print(f"  Before: peak = {peak:.4f}")
    for i in range(0, total, fpp):
        if vals[i] > -10000:
            vals[i] -= peak
    lo = min((vals[i] for i in range(0, total, fpp) if vals[i] > -10000), default=0)
    hi = max((vals[i] for i in range(0, total, fpp) if vals[i] > -10000), default=0)
    print(f"  After:  range [{lo:.4f}, {hi:.4f}]")
    with open(filepath, "wb") as f:
        f.write(struct.pack(f"<{total}f", *vals))
    print(f"  Written: {filepath}")

if __name__ == "__main__":
    geo = Path(__file__).resolve().parents[2] / "geo"
    for name in ["cliff_01_height.raw", "cliff_02_height.raw"]:
        p = geo / name
        if os.path.isfile(p):
            print(f"Converting {name}...")
            invert(p)
        else:
            print(f"SKIP (not found): {p}")
