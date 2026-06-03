"""One-time GPU tool: convert RGBAF .raw heightmaps so that peak = 0."""
import shutil
import subprocess
import sys
import os
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[2]
GPU_SCRIPT = "tools/terrain/invert_height_raw_gpu.gd"


def _godot_exe() -> str:
    return (
        os.environ.get("GODOT_EXE")
        or os.environ.get("GODOT_BIN")
        or shutil.which("godot")
        or "godot"
    )


def invert(filepath: str | Path, w: int = 256, h: int = 256) -> int:
    return _run_gpu([str(filepath), str(w), str(h)])


def _run_gpu(user_args: list[str]) -> int:
    # GPU path only: RGBA32F raw buffer, 4 floats/pixel, R height valid when > -10000.
    # The Godot shader reduces peak, barriers, subtracts peak from valid R values, and readbacks.
    cmd = [
        _godot_exe(),
        "--path",
        str(PROJECT_ROOT),
        "--rendering-driver",
        "vulkan",
        "--script",
        GPU_SCRIPT,
    ]
    if user_args:
        cmd.append("--")
        cmd.extend(user_args)
    try:
        completed = subprocess.run(
            cmd,
            cwd=PROJECT_ROOT,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
    except FileNotFoundError:
        print("ERROR: Godot executable not found; set GODOT_EXE or add godot to PATH")
        return 1
    return completed.returncode


if __name__ == "__main__":
    sys.exit(_run_gpu(sys.argv[1:]))
