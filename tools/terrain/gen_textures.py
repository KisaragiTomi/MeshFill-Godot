import numpy as np
from PIL import Image
import os
from pathlib import Path

os.environ.setdefault('OPENCV_IO_ENABLE_OPENEXR', '1')
import cv2

ROOT_DIR = Path(__file__).resolve().parents[2]
land_dir = ROOT_DIR / "landscape"
out_dir = ROOT_DIR / "textures"
geo_dir = ROOT_DIR / "geo"
os.makedirs(out_dir, exist_ok=True)

TARGET_SIZE = 256
MAX_HEIGHT = 50.0
EXR_DEPTH_BASE = 10000.0
TERRAIN_HEIGHT_M = 16.0
CAPTURE_SIZE = 30.0
TILE_FILE = "000000000015.png"
USE_EXR_SOURCES = False


def save_rgba_raw(data_r, data_g, data_b, data_a, path, width, height):
    img = np.zeros((height, width, 4), dtype=np.float32)
    img[:, :, 0] = data_r
    img[:, :, 1] = data_g
    img[:, :, 2] = data_b
    img[:, :, 3] = data_a
    img.tofile(os.fspath(path))
    print(f'  {os.path.basename(path)} ({os.path.getsize(path)/1024:.0f} KB)')


def load_exr(path):
    img = cv2.imread(os.fspath(path), cv2.IMREAD_UNCHANGED)
    if img is None:
        raise FileNotFoundError(path)
    if img.shape[0] != TARGET_SIZE or img.shape[1] != TARGET_SIZE:
        img = cv2.resize(img, (TARGET_SIZE, TARGET_SIZE), interpolation=cv2.INTER_LINEAR)
    return img.astype(np.float32, copy=False)


def exr_red(img):
    if img.ndim == 2:
        return img
    if img.shape[2] >= 3:
        return img[:, :, 2]
    return img[:, :, 0]


def exr_rgb(img):
    if img.ndim != 3 or img.shape[2] < 3:
        raise ValueError("Expected RGB/RGBA EXR data")
    return img[:, :, 2], img[:, :, 1], img[:, :, 0]


def depth_exr_to_runtime(exr_depth):
    return MAX_HEIGHT - (EXR_DEPTH_BASE - exr_depth)


zeros = np.zeros((TARGET_SIZE, TARGET_SIZE), dtype=np.float32)

exr_inputs = [
    out_dir / 'scene_depth.exr',
    out_dir / 'scene_normal.exr',
    out_dir / 'object_depth.exr',
    out_dir / 'object_normal.exr',
    out_dir / 'height_normal.exr',
    out_dir / 'target_height.exr',
]

if USE_EXR_SOURCES and all(p.is_file() for p in exr_inputs):
    print('Generating runtime .raw textures from EXR sources')

    scene_depth_exr = exr_red(load_exr(out_dir / 'scene_depth.exr'))
    object_depth_exr = exr_red(load_exr(out_dir / 'object_depth.exr'))
    scene_nx, scene_ny, scene_nz = exr_rgb(load_exr(out_dir / 'scene_normal.exr'))
    object_nx, object_ny, object_nz = exr_rgb(load_exr(out_dir / 'object_normal.exr'))
    height_nx, height_ny, height_nz = exr_rgb(load_exr(out_dir / 'height_normal.exr'))
    target_height = exr_red(load_exr(out_dir / 'target_height.exr'))

    save_rgba_raw(depth_exr_to_runtime(scene_depth_exr), zeros, zeros, zeros,
                  out_dir / 'scene_depth.raw', TARGET_SIZE, TARGET_SIZE)
    save_rgba_raw(scene_nx, scene_ny, scene_nz, zeros,
                  out_dir / 'scene_normal.raw', TARGET_SIZE, TARGET_SIZE)
    save_rgba_raw(depth_exr_to_runtime(object_depth_exr), zeros, zeros, zeros,
                  out_dir / 'object_depth.raw', TARGET_SIZE, TARGET_SIZE)
    save_rgba_raw(object_nx, object_ny, object_nz, zeros,
                  out_dir / 'object_normal.raw', TARGET_SIZE, TARGET_SIZE)
    save_rgba_raw(height_nx, height_ny, height_nz, zeros,
                  out_dir / 'height_normal.raw', TARGET_SIZE, TARGET_SIZE)
    save_rgba_raw(target_height, zeros, zeros, zeros,
                  out_dir / 'target_height.raw', TARGET_SIZE, TARGET_SIZE)
else:
    # Load single tile
    raw = np.array(Image.open(land_dir / TILE_FILE))[:, :, 0].astype(np.float32)
    height_m = raw / 255.0 * TERRAIN_HEIGHT_M
    print(f'Tile {TILE_FILE}: {raw.shape}, height=[{height_m.min():.2f}, {height_m.max():.2f}]m')

    # scene_depth: R = max_height - height
    save_rgba_raw(MAX_HEIGHT - height_m, zeros, zeros, zeros,
                  out_dir / 'scene_depth.raw', TARGET_SIZE, TARGET_SIZE)

    # scene_normal from height gradients
    cell = CAPTURE_SIZE / TARGET_SIZE
    dx = np.gradient(height_m, cell, axis=1)
    dy = np.gradient(height_m, cell, axis=0)
    nx, ny, nz = -dx, -dy, np.ones_like(height_m)
    length = np.maximum(np.sqrt(nx * nx + ny * ny + nz * nz), 1e-6)
    nx /= length; ny /= length; nz /= length

    steep_pct = (nz < 0.75).sum() / TARGET_SIZE ** 2 * 100
    print(f'Steep areas (cos<0.75): {steep_pct:.1f}%')

    save_rgba_raw(nx, ny, nz, zeros,
                  out_dir / 'scene_normal.raw', TARGET_SIZE, TARGET_SIZE)
    save_rgba_raw(nx, ny, nz, zeros,
                  out_dir / 'height_normal.raw', TARGET_SIZE, TARGET_SIZE)

    # object_depth/normal: empty (no objects)
    full_mh = np.full_like(height_m, MAX_HEIGHT)
    save_rgba_raw(full_mh, zeros, zeros, zeros,
                  out_dir / 'object_depth.raw', TARGET_SIZE, TARGET_SIZE)
    save_rgba_raw(zeros, zeros, zeros, zeros,
                  out_dir / 'object_normal.raw', TARGET_SIZE, TARGET_SIZE)

    # target_height: terrain height
    save_rgba_raw(height_m, zeros, zeros, zeros,
                  out_dir / 'target_height.raw', TARGET_SIZE, TARGET_SIZE)

# Mesh heightmaps: convert EXR to raw
for name in ['cliff_01_height', 'cliff_02_height']:
    exr_path = geo_dir / f'{name}.exr'
    if not exr_path.is_file():
        continue
    img = cv2.imread(os.fspath(exr_path), cv2.IMREAD_UNCHANGED)
    if img is None:
        continue
    r = img[:, :, 2]
    z = np.zeros_like(r)
    save_rgba_raw(r, z, z, z, geo_dir / f'{name}.raw', 256, 256)

print('Done!')
