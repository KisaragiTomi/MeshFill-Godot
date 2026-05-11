import argparse
import os
import subprocess
import sys
from pathlib import Path
import xml.etree.ElementTree as ET


def _browser_candidates():
    env_names = ["CHROME_PATH", "CHROME", "EDGE_PATH", "MSEDGE"]
    for name in env_names:
        value = os.environ.get(name)
        if value:
            yield Path(value)
    candidates = [
        Path(r"C:\Program Files\Google\Chrome\Application\chrome.exe"),
        Path(r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe"),
        Path(r"C:\Program Files\Microsoft\Edge\Application\msedge.exe"),
        Path(r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"),
    ]
    for path in candidates:
        yield path


def _find_browser():
    for path in _browser_candidates():
        if path.is_file():
            return path
    return None


def _parse_svg_size(svg_path):
    root = ET.parse(svg_path).getroot()
    tag = root.tag.rsplit("}", 1)[-1]
    if tag != "svg":
        raise ValueError("root element is not svg")
    width = root.attrib.get("width", "")
    height = root.attrib.get("height", "")
    view_box = root.attrib.get("viewBox", "")
    return width, height, view_box


def _file_uri(path):
    return path.resolve().as_uri()


def _png_size(path):
    with path.open("rb") as handle:
        header = handle.read(24)
    if len(header) < 24 or header[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    return int.from_bytes(header[16:20], "big"), int.from_bytes(header[20:24], "big")


def render_svg(svg_path, out_path, timeout):
    width, height, view_box = _parse_svg_size(svg_path)
    browser = _find_browser()
    if browser is None:
        return {
            "ok": False,
            "rendered": False,
            "message": "No Chrome or Edge executable found.",
            "width": width,
            "height": height,
            "viewBox": view_box,
        }
    out_path.parent.mkdir(parents=True, exist_ok=True)
    window_size = "1480,1120"
    if width.isdigit() and height.isdigit():
        window_size = f"{width},{height}"
    command = [
        str(browser),
        "--headless=new",
        "--disable-gpu",
        "--hide-scrollbars",
        f"--window-size={window_size}",
        f"--screenshot={out_path}",
        _file_uri(svg_path),
    ]
    completed = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
    rendered = completed.returncode == 0 and out_path.is_file() and out_path.stat().st_size > 0
    png_size = _png_size(out_path) if rendered else None
    return {
        "ok": rendered,
        "rendered": rendered,
        "message": completed.stdout.strip() or completed.stderr.strip(),
        "browser": str(browser),
        "output": str(out_path),
        "width": width,
        "height": height,
        "viewBox": view_box,
        "png_size": "%dx%d" % png_size if png_size else "",
        "returncode": completed.returncode,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("svg", type=Path)
    parser.add_argument("--out", type=Path, default=None)
    parser.add_argument("--timeout", type=float, default=20.0)
    args = parser.parse_args()
    svg_path = args.svg.resolve()
    if not svg_path.is_file():
        print(f"ERROR svg not found: {svg_path}", file=sys.stderr)
        return 2
    out_path = args.out.resolve() if args.out else svg_path.with_suffix(".qa.png")
    try:
        result = render_svg(svg_path, out_path, args.timeout)
    except subprocess.TimeoutExpired:
        print(f"ERROR render timed out after {args.timeout:.1f}s", file=sys.stderr)
        return 3
    except Exception as exc:
        print(f"ERROR {type(exc).__name__}: {exc}", file=sys.stderr)
        return 4
    for key in ["ok", "rendered", "browser", "output", "width", "height", "viewBox", "png_size", "returncode", "message"]:
        if key in result:
            print(f"{key}: {result[key]}")
    return 0 if result.get("ok") else 1


if __name__ == "__main__":
    raise SystemExit(main())
