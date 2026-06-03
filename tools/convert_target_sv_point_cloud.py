from __future__ import annotations

import argparse
import json
import math
import struct
from array import array
from pathlib import Path
from typing import Any

import numpy as np
from PIL import Image


class BgeoDecodeError(RuntimeError):
    pass


class HoudiniBjsonParser:
    def __init__(self, data: bytes) -> None:
        if not data.startswith(b"\x7fNSJb"):
            raise BgeoDecodeError("Unsupported BGEO payload: missing Houdini binary JSON header")
        self._data = data
        self._offset = 5
        self._string_table: dict[int, str] = {}

    def parse(self) -> Any:
        value = self._parse_value()
        if self._offset != len(self._data):
            raise BgeoDecodeError("Trailing bytes after BGEO payload")
        return value

    def _read_compact_int(self) -> int:
        marker = self._read_u8()
        if marker < 0xF0:
            return marker
        if marker == 0xF1:
            return self._read_u8()
        if marker == 0xF2:
            value = int.from_bytes(self._read_bytes(2), "little", signed=False)
            return value
        if marker == 0xF4:
            value = int.from_bytes(self._read_bytes(4), "little", signed=False)
            return value
        if marker == 0xF8:
            value = int.from_bytes(self._read_bytes(8), "little", signed=False)
            return value
        raise BgeoDecodeError("Unsupported compact integer marker 0x%02x" % marker)

    def _parse_value(self) -> Any:
        while self._peek_u8() == 0x2B:
            self._read_u8()
            key = self._read_compact_int()
            length = self._read_compact_int()
            self._string_table[key] = self._read_bytes(length).decode("utf-8")

        token = self._read_u8()
        if token == 0x5B:
            result = []
            while self._peek_u8() != 0x5D:
                result.append(self._parse_value())
            self._read_u8()
            return result
        if token == 0x7B:
            result = {}
            while self._peek_u8() != 0x7D:
                key = self._parse_value()
                result[key] = self._parse_value()
            self._read_u8()
            return result
        if token == 0x26:
            key = self._read_compact_int()
            return self._string_table[key]
        if token == 0x27:
            length = self._read_compact_int()
            return self._read_bytes(length).decode("utf-8")
        if token == 0x30:
            return False
        if token == 0x31:
            return True
        if token == 0x10:
            return 0
        if token == 0x11:
            return int.from_bytes(self._read_bytes(1), "little", signed=True)
        if token == 0x12:
            return int.from_bytes(self._read_bytes(2), "little", signed=True)
        if token == 0x13:
            return int.from_bytes(self._read_bytes(4), "little", signed=True)
        if token == 0x14:
            return int.from_bytes(self._read_bytes(8), "little", signed=True)
        if token == 0x19:
            return struct.unpack("<f", self._read_bytes(4))[0]
        if token == 0x1A:
            return struct.unpack("<d", self._read_bytes(8))[0]
        if token == 0x40:
            return self._parse_uniform_array()
        raise BgeoDecodeError("Unsupported BGEO binary JSON token 0x%02x at byte %d" % (token, self._offset - 1))

    def _parse_uniform_array(self) -> Any:
        storage_token = self._read_u8()
        count = self._read_compact_int()
        if storage_token == 0x10:
            raw = self._read_bytes((count + 7) // 8)
            return [(raw[i // 8] >> (i % 8)) & 1 for i in range(count)]

        type_info = {
            0x11: ("b", 1),
            0x12: ("h", 2),
            0x13: ("i", 4),
            0x19: ("f", 4),
            0x1A: ("d", 8),
        }
        if storage_token not in type_info:
            raise BgeoDecodeError("Unsupported uniform array storage token 0x%02x" % storage_token)
        type_code, item_size = type_info[storage_token]
        values = array(type_code)
        values.frombytes(self._read_bytes(count * item_size))
        return values

    def _peek_u8(self) -> int:
        if self._offset >= len(self._data):
            raise BgeoDecodeError("Unexpected end of BGEO payload")
        return self._data[self._offset]

    def _read_u8(self) -> int:
        value = self._peek_u8()
        self._offset += 1
        return value

    def _read_bytes(self, count: int) -> bytes:
        if self._offset + count > len(self._data):
            raise BgeoDecodeError("Unexpected end of BGEO payload")
        result = self._data[self._offset:self._offset + count]
        self._offset += count
        return result


def read_bgeo_payload(path: Path) -> bytes:
    data = path.read_bytes()
    if not data.startswith(b"scf1"):
        return data

    try:
        import blosc2
    except ImportError as exc:
        raise BgeoDecodeError("Reading .bgeo.sc requires the Python package 'blosc2'") from exc

    if data[-4:] != b"1fcs":
        raise BgeoDecodeError("Invalid .bgeo.sc footer")

    index_length = struct.unpack(">Q", data[-12:-4])[0]
    index_begin = len(data) - 12 - index_length
    if index_begin < 12:
        raise BgeoDecodeError("Invalid .bgeo.sc index")

    index_count = (index_length - 16) // 8
    index_offset = index_begin
    block_indices = []
    for _index in range(index_count):
        block_indices.append(struct.unpack(">Q", data[index_offset:index_offset + 8])[0])
        index_offset += 8
    block_size = struct.unpack(">Q", data[index_offset:index_offset + 8])[0]
    index_offset += 8
    last_block_size = struct.unpack(">Q", data[index_offset:index_offset + 8])[0]

    payload_begin = 12
    payload_end = index_begin
    cursor = payload_begin
    out = bytearray()
    for block_index in block_indices:
        next_cursor = payload_begin + block_index
        out.extend(blosc2.decompress(data[cursor:next_cursor]))
        cursor = next_cursor
    out.extend(blosc2.decompress(data[cursor:payload_end]))

    expected_size = block_size * index_count + last_block_size
    if len(out) != expected_size:
        raise BgeoDecodeError("Unexpected decompressed BGEO size %d, expected %d" % (len(out), expected_size))
    return bytes(out)


def pairs_to_dict(values: list[Any]) -> dict[str, Any]:
    if len(values) % 2 != 0:
        raise BgeoDecodeError("Expected key/value pair array")
    return {str(values[i]): values[i + 1] for i in range(0, len(values), 2)}


def flatten_sequence(value: Any) -> list[Any]:
    if value is None:
        return []
    if isinstance(value, array):
        return list(value)
    if isinstance(value, np.ndarray):
        return value.reshape(-1).tolist()
    if isinstance(value, list):
        result: list[Any] = []
        for item in value:
            result.extend(flatten_sequence(item))
        return result
    return [value]


def float_array_from_bgeo(value: Any) -> np.ndarray:
    if isinstance(value, array):
        return np.asarray(value, dtype=np.float32)
    if isinstance(value, np.ndarray):
        return value.astype(np.float32, copy=False).reshape(-1)
    return np.asarray(flatten_sequence(value), dtype=np.float32)


def unpack_numeric_values(values: list[Any], element_count: int) -> np.ndarray:
    data = pairs_to_dict(values)
    tuple_size = int(data.get("size", 1))
    storage = str(data.get("storage", "fpreal32"))
    if storage != "fpreal32":
        raise BgeoDecodeError("Unsupported point attribute storage '%s'" % storage)

    raw = data.get("rawpagedata")
    if raw is None:
        raw = data.get("tuples")
    if raw is None:
        raise BgeoDecodeError("Point attribute has no rawpagedata or tuples")

    raw_values = float_array_from_bgeo(raw)
    page_size = int(data.get("pagesize", element_count))
    packing = [int(v) for v in flatten_sequence(data.get("packing", [tuple_size]))]
    constant_flags = [bool(v) for v in flatten_sequence(data.get("constantpageflags", []))]
    expected_count = element_count * tuple_size

    if not constant_flags and packing == [tuple_size]:
        if raw_values.size < expected_count:
            raise BgeoDecodeError("Point attribute raw data is shorter than expected")
        return raw_values[:expected_count].reshape((element_count, tuple_size)).copy()

    out = np.zeros((element_count, tuple_size), dtype=np.float32)
    page_count = (element_count + page_size - 1) // page_size
    raw_index = 0
    for page in range(page_count):
        element_begin = page * page_size
        element_end = min(element_begin + page_size, element_count)
        current_page_size = element_end - element_begin
        tuple_offset = 0
        for pack_index, pack_size in enumerate(packing):
            flag_index = pack_index * page_count + page
            is_constant = flag_index < len(constant_flags) and constant_flags[flag_index]
            if is_constant:
                segment = raw_values[raw_index:raw_index + pack_size]
                raw_index += pack_size
                out[element_begin:element_end, tuple_offset:tuple_offset + pack_size] = segment
            else:
                count = current_page_size * pack_size
                segment = raw_values[raw_index:raw_index + count].reshape((current_page_size, pack_size))
                raw_index += count
                out[element_begin:element_end, tuple_offset:tuple_offset + pack_size] = segment
            tuple_offset += pack_size
    return out


def load_point_attributes(path: Path) -> tuple[dict[str, np.ndarray], dict[str, Any]]:
    root = HoudiniBjsonParser(read_bgeo_payload(path)).parse()
    detail = pairs_to_dict(root)
    point_count = int(detail["pointcount"])
    attributes = pairs_to_dict(detail["attributes"])
    point_attributes = {}
    for attribute in attributes.get("pointattributes", []):
        metadata = pairs_to_dict(attribute[0])
        body = pairs_to_dict(attribute[1])
        name = str(metadata.get("name", ""))
        if not name or "values" not in body:
            continue
        point_attributes[name] = unpack_numeric_values(body["values"], point_count)

    info = dict(detail.get("info", {}))
    return point_attributes, {
        "point_count": point_count,
        "fileversion": detail.get("fileversion", ""),
        "bounds": [float(v) for v in info.get("bounds", [])],
        "attribute_summary": str(info.get("attribute_summary", "")),
    }


def choose_attribute(attrs: dict[str, np.ndarray], candidates: list[str]) -> tuple[str, np.ndarray]:
    for name in candidates:
        if name in attrs:
            return name, attrs[name]
    raise BgeoDecodeError("Missing point attribute, tried: %s" % ", ".join(candidates))


def build_target_sv(
    attrs: dict[str, np.ndarray],
    source_info: dict[str, Any],
    height_path: Path,
    args: argparse.Namespace,
) -> dict[str, Any]:
    position_name, positions = choose_attribute(attrs, ["P"])
    color_name, colors = choose_attribute(attrs, ["color", "Cd"])
    complex_name, complexity_values = choose_attribute(attrs, ["complexity", "complex"])
    collision_name, collision_values = choose_attribute(attrs, ["collision"])

    height_image = Image.open(height_path).convert("L")
    texture_size = int(height_image.width)
    if height_image.width != height_image.height:
        raise BgeoDecodeError("TargetSV fixture expects a square height texture")
    height_pixels = np.asarray(height_image, dtype=np.float32) / 255.0

    bounds = source_info.get("bounds", [])
    if len(bounds) >= 6:
        min_x, max_x, min_y, max_y, min_z, max_z = [float(v) for v in bounds[:6]]
    else:
        min_x = float(np.min(positions[:, 0]))
        max_x = float(np.max(positions[:, 0]))
        min_y = float(np.min(positions[:, 1]))
        max_y = float(np.max(positions[:, 1]))
        min_z = float(np.min(positions[:, 2]))
        max_z = float(np.max(positions[:, 2]))

    capture_size = float(args.capture_size) if args.capture_size > 0.0 else max(max_x - min_x, max_z - min_z)
    local_y = positions[:, 1]
    vertical_span = float(args.vertical_span)
    if vertical_span <= 0.0:
        vertical_span = max(16.0, math.ceil(float(np.max(local_y)) / 8.0) * 8.0)
    slice_count = int(args.slice_count)
    voxel_count = texture_size * texture_size * slice_count

    x_norm = (positions[:, 0] - min_x) / max(max_x - min_x, 0.0001)
    z_norm = (positions[:, 2] - min_z) / max(max_z - min_z, 0.0001)
    px = np.rint(x_norm * float(texture_size - 1)).astype(np.int32)
    pz = np.rint(z_norm * float(texture_size - 1)).astype(np.int32)
    if args.flip_z:
        pz = texture_size - 1 - pz

    complexity = np.clip(complexity_values[:, 0], 0.0, 1.0)
    collision = np.clip(collision_values[:, 0], 0.0, 1.0)
    color = np.clip(colors[:, :3], 0.0, 1.0)

    finite = (
        np.isfinite(positions[:, 0])
        & np.isfinite(positions[:, 1])
        & np.isfinite(positions[:, 2])
        & np.isfinite(complexity)
        & np.isfinite(collision)
    )
    in_bounds = finite & (px >= 0) & (px < texture_size) & (pz >= 0) & (pz < texture_size) & (local_y >= 0.0)
    used_indices = np.nonzero(in_bounds)[0]

    visual = np.zeros((slice_count, texture_size, texture_size, 4), dtype=np.float32)
    target_collision = np.zeros((slice_count, texture_size, texture_size), dtype=np.float32)
    color_sum = np.zeros((slice_count, texture_size, texture_size, 3), dtype=np.float32)
    color_weight = np.zeros((slice_count, texture_size, texture_size), dtype=np.float32)

    clipped_height_count = 0
    for point_index in used_indices:
        y = float(local_y[point_index])
        if y >= vertical_span:
            clipped_height_count += 1
        slice_index = min(max(int(math.floor((min(y, vertical_span - 0.0001) / vertical_span) * slice_count)), 0), slice_count - 1)
        x = int(px[point_index])
        z = int(pz[point_index])
        complex_value = float(complexity[point_index])
        collision_value = float(collision[point_index])
        weight = max(complex_value, collision_value, 0.001)

        visual[slice_index, z, x, 3] = max(visual[slice_index, z, x, 3], complex_value)
        target_collision[slice_index, z, x] = max(target_collision[slice_index, z, x], collision_value)
        color_sum[slice_index, z, x, :] += color[point_index, :] * weight
        color_weight[slice_index, z, x] += weight

    mask = color_weight > 0.0
    visual[:, :, :, :3][mask] = color_sum[mask] / color_weight[mask, None]

    peak_value = np.max(visual[:, :, :, 3], axis=0)
    peak_collision = np.max(target_collision, axis=0)
    voxel_weight = np.maximum(visual[:, :, :, 3], target_collision) ** 2.0
    preview_weight = np.sum(voxel_weight, axis=0)
    preview_color = np.zeros((texture_size, texture_size, 3), dtype=np.float32)
    weighted_color = np.sum(visual[:, :, :, :3] * voxel_weight[:, :, :, None], axis=0)
    preview_mask = preview_weight > 0.00001
    preview_color[preview_mask] = weighted_color[preview_mask] / preview_weight[preview_mask, None]
    preview_color = preview_color * (1.0 - peak_collision[:, :, None] * 0.35) + np.array([0.72, 0.68, 0.60], dtype=np.float32) * (peak_collision[:, :, None] * 0.35)
    preview_alpha = np.maximum(peak_value, peak_collision)
    preview_rgba = np.dstack([preview_color, preview_alpha])

    height_samples = height_pixels[np.clip(pz[used_indices], 0, texture_size - 1), np.clip(px[used_indices], 0, texture_size - 1)]
    non_empty_voxels = int(np.count_nonzero(np.maximum(visual[:, :, :, 3], target_collision) > args.occupancy_epsilon))

    return {
        "visual": visual,
        "collision": target_collision,
        "preview": np.clip(preview_rgba, 0.0, 1.0),
        "metadata": {
            "valid": True,
            "target_role": "TargetSV",
            "generator": "TargetSVPointCloudConverter",
            "source_point_cloud": "res://landscape/TargetSV_PT.bgeo.sc",
            "source_height": "res://textures/scene_height_0_1.png",
            "height_relative": True,
            "target_guidance_only": True,
            "height_buffer_applied": False,
            "collision_buffer_applied": False,
            "texture_size": texture_size,
            "slice_count": slice_count,
            "voxel_count": voxel_count,
            "max_height": float(args.height_scale),
            "capture_size": capture_size,
            "vertical_span": vertical_span,
            "visual_format": "rgba32f",
            "collision_format": "r32f",
            "attribute_map": {
                "position": position_name,
                "color": color_name,
                "complexity": complex_name,
                "collision": collision_name,
            },
            "source_bounds": [min_x, max_x, min_y, max_y, min_z, max_z],
            "point_count": int(source_info["point_count"]),
            "used_point_count": int(used_indices.size),
            "clipped_height_count": int(clipped_height_count),
            "non_empty_voxel_count": non_empty_voxels,
            "height_sample_min": float(np.min(height_samples)) if height_samples.size > 0 else 0.0,
            "height_sample_max": float(np.max(height_samples)) if height_samples.size > 0 else 0.0,
            "complexity_max": float(np.max(complexity)) if complexity.size > 0 else 0.0,
            "collision_max": float(np.max(collision)) if collision.size > 0 else 0.0,
            "fileversion": source_info.get("fileversion", ""),
        },
    }


def write_outputs(result: dict[str, Any], output_dir: Path) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    visual = result["visual"].astype("<f4", copy=False)
    collision = result["collision"].astype("<f4", copy=False)
    preview = (result["preview"] * 255.0 + 0.5).astype(np.uint8)
    metadata = dict(result["metadata"])

    visual_path = output_dir / "target_sv_point_cloud_visual.rgba32f"
    collision_path = output_dir / "target_sv_point_cloud_collision.r32f"
    preview_path = output_dir / "target_sv_point_cloud_preview.png"
    metadata_path = output_dir / "target_sv_point_cloud.json"

    visual_path.write_bytes(visual.tobytes(order="C"))
    collision_path.write_bytes(collision.tobytes(order="C"))
    Image.fromarray(preview, "RGBA").save(preview_path)

    metadata["visual_path"] = "res://demos/target-sv-point-cloud-conversion/target_sv_point_cloud_visual.rgba32f"
    metadata["collision_path"] = "res://demos/target-sv-point-cloud-conversion/target_sv_point_cloud_collision.r32f"
    metadata["preview_path"] = "res://demos/target-sv-point-cloud-conversion/target_sv_point_cloud_preview.png"
    metadata_path.write_text(json.dumps(metadata, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    print("Wrote %s" % metadata_path)
    print("  points used: %d / %d" % (metadata["used_point_count"], metadata["point_count"]))
    print("  non-empty voxels: %d" % metadata["non_empty_voxel_count"])
    print("  visual bytes: %d" % visual_path.stat().st_size)
    print("  collision bytes: %d" % collision_path.stat().st_size)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Convert TargetSV_PT.bgeo.sc point attributes into TargetSceneVoxel raw buffers.")
    parser.add_argument("--bgeo", default="landscape/TargetSV_PT.bgeo.sc")
    parser.add_argument("--height", default="textures/scene_height_0_1.png")
    parser.add_argument("--output-dir", default="demos/target-sv-point-cloud-conversion")
    parser.add_argument("--slice-count", type=int, default=16)
    parser.add_argument("--vertical-span", type=float, default=0.0, help="<= 0 picks a span large enough for the source relative heights.")
    parser.add_argument("--height-scale", type=float, default=120.0)
    parser.add_argument("--capture-size", type=float, default=0.0)
    parser.add_argument("--occupancy-epsilon", type=float, default=0.001)
    parser.add_argument("--flip-z", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    attrs, source_info = load_point_attributes(Path(args.bgeo))
    result = build_target_sv(attrs, source_info, Path(args.height), args)
    write_outputs(result, Path(args.output_dir))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
