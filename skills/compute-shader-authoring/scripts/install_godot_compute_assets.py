#!/usr/bin/env python3
"""Install reusable Godot compute-shader assets into a Godot project."""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Asset:
    source: str
    target_dir: str


ASSETS = [
    Asset("godot_compute_shader_base.gd", "scripts"),
    Asset("sparse_tile_dispatch.gd", "scripts"),
    Asset("sparse_tile_dispatch_3d.gd", "scripts"),
    Asset("std_compact_generic.glsl", "shaders"),
    Asset("std_compact_generic_3d.glsl", "shaders"),
    Asset("std_finalize_compact.glsl", "shaders"),
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Copy integrated Godot compute base and sparse dispatch assets into a project."
    )
    parser.add_argument(
        "project",
        nargs="?",
        default=".",
        help="Godot project root containing project.godot. Defaults to current directory.",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Overwrite existing destination files.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print planned operations without copying files.",
    )
    parser.add_argument(
        "--base-only",
        action="store_true",
        help="Install only godot_compute_shader_base.gd.",
    )
    parser.add_argument(
        "--sparse-only",
        action="store_true",
        help="Install only sparse dispatch scripts and shaders.",
    )
    parser.add_argument(
        "--godot",
        default="",
        help="Optional Godot executable path for --import or --check.",
    )
    parser.add_argument(
        "--import",
        dest="run_import",
        action="store_true",
        help="Run Godot --import after copying shader files.",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Run Godot --check-only on installed GDScript files after copying.",
    )
    return parser.parse_args()


def skill_root() -> Path:
    return Path(__file__).resolve().parents[1]


def resolve_project(path_text: str) -> Path:
    project = Path(path_text).expanduser().resolve()
    if not project.exists():
        raise SystemExit(f"Project path does not exist: {project}")
    if not (project / "project.godot").exists():
        raise SystemExit(f"Not a Godot project root, missing project.godot: {project}")
    return project


def selected_assets(args: argparse.Namespace) -> list[Asset]:
    if args.base_only and args.sparse_only:
        raise SystemExit("Use only one of --base-only or --sparse-only.")
    if args.base_only:
        return [asset for asset in ASSETS if asset.source == "godot_compute_shader_base.gd"]
    if args.sparse_only:
        return [asset for asset in ASSETS if asset.source != "godot_compute_shader_base.gd"]
    return ASSETS


def copy_asset(source: Path, destination: Path, force: bool, dry_run: bool) -> str:
    if destination.exists() and not force:
        return f"skip exists: {destination}"
    if dry_run:
        action = "overwrite" if destination.exists() else "copy"
        return f"{action}: {source} -> {destination}"
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)
    return f"copied: {destination}"


def run_godot(godot: str, project: Path, args: list[str]) -> None:
    if not godot:
        raise SystemExit("--godot is required when using --import or --check.")
    command = [godot, "--headless", "--path", str(project), *args]
    print("+ " + " ".join(command))
    subprocess.run(command, check=True)


def main() -> int:
    args = parse_args()
    root = skill_root()
    assets_dir = root / "assets"
    project = resolve_project(args.project)

    copied_scripts: list[Path] = []
    for asset in selected_assets(args):
        source = assets_dir / asset.source
        if not source.exists():
            raise SystemExit(f"Missing skill asset: {source}")
        destination = project / asset.target_dir / asset.source
        message = copy_asset(source, destination, args.force, args.dry_run)
        print(message)
        if destination.suffix == ".gd":
            copied_scripts.append(destination)

    if args.dry_run:
        return 0

    if args.run_import:
        run_godot(args.godot, project, ["--import"])

    if args.check:
        for script in copied_scripts:
            rel = script.relative_to(project).as_posix()
            run_godot(args.godot, project, ["--check-only", "--script", f"res://{rel}"])

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
