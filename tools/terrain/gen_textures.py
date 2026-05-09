import numpy as np
from PIL import Image
import os
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parents[2]
land_dir = ROOT_DIR / "landscape"
out_dir = ROOT_DIR / "textures"
geo_dir = ROOT_DIR / "geo"
os.makedirs(out_dir, exist_ok=True)

TARGET_SIZE = 256
MAX_HEIGHT = 50.0
TERRAIN_HEIGHT_M = 16.0
CAPTURE_SIZE = 30.0
TILE_FILE = "000000000015.png"


def save_rgba_raw(data_r, data_g, data_b, data_a, path, width, height):
    img = np.zeros((height, width, 4), dtype=np.float32)
    img[:, :, 0] = data_r
    img[:, :, 1] = data_g
    img[:, :, 2] = data_b
    img[:, :, 3] = data_a
    img.tofile(os.fspath(path))
    print(f'  {os.path.basename(path)} ({os.path.getsize(path)/1024:.0f} KB)')


# Load single tile
raw = np.array(Image.open(land_dir / TILE_FILE))[:, :, 0].astype(np.float32)
height_m = raw / 255.0 * TERRAIN_HEIGHT_M
print(f'Tile {TILE_FILE}: {raw.shape}, height=[{height_m.min():.2f}, {height_m.max():.2f}]m')

zeros = np.zeros((TARGET_SIZE, TARGET_SIZE), dtype=np.float32)

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
os.environ['OPENCV_IO_ENABLE_OPENEXR'] = '1'
import cv2
for name in ['cliff_01_height', 'cliff_02_height']:
    exr_path = geo_dir / f'{name}.exr'
    img = cv2.imread(os.fspath(exr_path), cv2.IMREAD_UNCHANGED)
    r = img[:, :, 2]
    z = np.zeros_like(r)
    save_rgba_raw(r, z, z, z, geo_dir / f'{name}.raw', 256, 256)

print('Done!')
