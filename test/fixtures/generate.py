"""Writes the PMTiles test fixtures and expected.json.

Expected values come from the tiles this script writes, not from reading the files back,
so both platform readers are checked against an independent source.

Run from anywhere: python3 test/fixtures/generate.py
"""

import gzip
import hashlib
import json
import struct
from pathlib import Path

OUT = Path(__file__).resolve().parent

COMPRESSION = {"none": 1, "gzip": 2}
TILE_TYPE = {"mvt": 1, "png": 2, "jpeg": 3, "webp": 4}
CONTENT_TYPE = {
    "mvt": "application/x-protobuf",
    "png": "image/png",
    "jpeg": "image/jpeg",
    "webp": "image/webp",
}


def zxy_to_tile_id(z, x, y):
    acc = ((1 << (2 * z)) - 1) // 3
    n = 1 << z
    d = 0
    s = n >> 1
    while s > 0:
        rx = 1 if x & s else 0
        ry = 1 if y & s else 0
        d += s * s * ((3 * rx) ^ ry)
        if ry == 0:
            if rx == 1:
                x = n - 1 - x
                y = n - 1 - y
            x, y = y, x
        s >>= 1
    return acc + d


def varint(value):
    out = bytearray()
    while value >= 0x80:
        out.append((value & 0x7F) | 0x80)
        value >>= 7
    out.append(value)
    return bytes(out)


def compress(data, kind):
    return gzip.compress(data, mtime=0) if kind == "gzip" else data


def serialize_directory(entries):
    out = bytearray(varint(len(entries)))
    last_id = 0
    for tile_id, _, _, _ in entries:
        out += varint(tile_id - last_id)
        last_id = tile_id
    for _, _, _, run_length in entries:
        out += varint(run_length)
    for _, _, length, _ in entries:
        out += varint(length)
    for i, (_, offset, _, _) in enumerate(entries):
        previous = entries[i - 1] if i > 0 else None
        if previous and offset == previous[1] + previous[2]:
            out += varint(0)
        else:
            out += varint(offset + 1)
    return bytes(out)


def build_entries(tiles, tile_compression):
    """tiles: {(z, x, y): bytes}. Returns (entries, data) with run-length and duplicate dedup."""
    by_id = sorted((zxy_to_tile_id(*zxy), content) for zxy, content in tiles.items())
    entries = []
    data = bytearray()
    offsets = {}
    for tile_id, content in by_id:
        stored = compress(content, tile_compression)
        last = entries[-1] if entries else None
        if last and last[0] + last[3] == tile_id and offsets.get(stored) == last[1]:
            entries[-1] = (last[0], last[1], last[2], last[3] + 1)
            continue
        if stored not in offsets:
            offsets[stored] = len(data)
            data += stored
        entries.append((tile_id, offsets[stored], len(stored), 1))
    return entries, bytes(data)


def write_archive(path, tiles, *, tile_type, internal, tile_compression, leaf_size=None,
                  bounds=(0, 0, 0, 0), center=(0, 0, 0), metadata=None):
    entries, data = build_entries(tiles, tile_compression)

    if leaf_size:
        leaves = bytearray()
        root_entries = []
        for start in range(0, len(entries), leaf_size):
            chunk = entries[start:start + leaf_size]
            leaf = compress(serialize_directory(chunk), internal)
            root_entries.append((chunk[0][0], len(leaves), len(leaf), 0))
            leaves += leaf
        root = compress(serialize_directory(root_entries), internal)
    else:
        leaves = b""
        root = compress(serialize_directory(entries), internal)

    meta = compress(json.dumps(metadata or {}, separators=(",", ":")).encode(), internal)

    root_offset = 127
    meta_offset = root_offset + len(root)
    leaf_offset = meta_offset + len(meta)
    data_offset = leaf_offset + len(leaves)
    zooms = [z for z, _, _ in tiles]

    header = bytearray(b"PMTiles\x03")
    header += struct.pack(
        "<QQQQQQQQQQQ",
        root_offset, len(root), meta_offset, len(meta), leaf_offset, len(leaves),
        data_offset, len(data), len(tiles), len(entries), len(set(tiles.values())),
    )
    header += bytes([1, COMPRESSION[internal], COMPRESSION[tile_compression], TILE_TYPE[tile_type],
                     min(zooms), max(zooms)])
    header += struct.pack("<iiii", *(round(v * 1e7) for v in bounds))
    header += bytes([center[2]])
    header += struct.pack("<ii", round(center[0] * 1e7), round(center[1] * 1e7))
    assert len(header) == 127

    path.write_bytes(bytes(header) + root + meta + bytes(leaves) + data)
    return entries


def expected_tile(z, x, y, tiles):
    content = tiles.get((z, x, y))
    if content is None:
        return {"z": z, "x": x, "y": y, "missing": True}
    return {"z": z, "x": x, "y": y, "size": len(content), "sha256": hashlib.sha256(content).hexdigest()}


def all_positions(max_zoom):
    return [(z, x, y) for z in range(max_zoom + 1) for x in range(1 << z) for y in range(1 << z)]


def vector_gzip():
    # Root directory only, gzip everywhere, a few holes.
    holes = {(2, 0, 0), (2, 3, 3)}
    tiles = {zxy: f"vector {zxy[0]}/{zxy[1]}/{zxy[2]}".encode()
             for zxy in all_positions(2) if zxy not in holes}
    write_archive(
        OUT / "vector-gzip.pmtiles", tiles, tile_type="mvt", internal="gzip", tile_compression="gzip",
        bounds=(34.0, -3.5, 36.0, -1.5), center=(35.0, -2.5, 1),
        metadata={"vector_layers": [{"id": "fixture", "fields": {"name": "String"}}]},
    )
    checks = [(0, 0, 0), (1, 1, 0), (2, 1, 2), (2, 0, 0), (2, 3, 3), (3, 0, 0), (1, 2, 0)]
    return {
        "file": "vector-gzip.pmtiles",
        "valid": True,
        "header": {"tileType": "mvt", "contentType": CONTENT_TYPE["mvt"], "minZoom": 0, "maxZoom": 2,
                   "internalCompression": "gzip", "tileCompression": "gzip",
                   "bounds": [34.0, -3.5, 36.0, -1.5], "center": [35.0, -2.5, 1]},
        "metadata": {"vector_layers": [{"id": "fixture", "fields": {"name": "String"}}]},
        "addressedTiles": len(tiles),
        "tiles": [expected_tile(z, x, y, tiles) for z, x, y in checks],
    }


def raster_leaves():
    # Leaf directories, uncompressed PNG tiles, runs of identical tiles at z4.
    tiles = {}
    for z, x, y in all_positions(4):
        if z == 4 and x >= 8:
            tiles[(z, x, y)] = b"\x89PNG water"
        elif (z, x, y) != (3, 5, 5):
            tiles[(z, x, y)] = f"\x89PNG land {z}/{x}/{y}".encode()
    entries = write_archive(
        OUT / "raster-leaves.pmtiles", tiles, tile_type="png", internal="gzip", tile_compression="none",
        leaf_size=20, bounds=(-180.0, -85.0511, 180.0, 85.0511), center=(0.0, 0.0, 2),
    )
    assert any(run > 1 for _, _, _, run in entries), "fixture should contain run-length entries"
    checks = [(0, 0, 0), (2, 1, 3), (3, 5, 5), (3, 7, 0), (4, 0, 15), (4, 8, 0), (4, 12, 9), (4, 15, 15),
              (5, 0, 0), (4, 16, 0)]
    return {
        "file": "raster-leaves.pmtiles",
        "valid": True,
        "header": {"tileType": "png", "contentType": CONTENT_TYPE["png"], "minZoom": 0, "maxZoom": 4,
                   "internalCompression": "gzip", "tileCompression": "none",
                   "bounds": [-180.0, -85.0511, 180.0, 85.0511], "center": [0.0, 0.0, 2]},
        "metadata": {},
        "addressedTiles": len(tiles),
        "tiles": [expected_tile(z, x, y, tiles) for z, x, y in checks],
    }


def webp_uncompressed():
    # No compression anywhere, single zoom level above zero.
    tiles = {zxy: f"RIFF webp {zxy[1]}/{zxy[2]}".encode() for zxy in all_positions(1) if zxy[0] == 1}
    write_archive(
        OUT / "webp-uncompressed.pmtiles", tiles, tile_type="webp", internal="none", tile_compression="none",
        bounds=(-10.0, -10.0, 10.0, 10.0), center=(0.0, 0.0, 1),
    )
    checks = [(1, 0, 0), (1, 1, 1), (0, 0, 0)]
    return {
        "file": "webp-uncompressed.pmtiles",
        "valid": True,
        "header": {"tileType": "webp", "contentType": CONTENT_TYPE["webp"], "minZoom": 1, "maxZoom": 1,
                   "internalCompression": "none", "tileCompression": "none",
                   "bounds": [-10.0, -10.0, 10.0, 10.0], "center": [0.0, 0.0, 1]},
        "metadata": {},
        "addressedTiles": len(tiles),
        "tiles": [expected_tile(z, x, y, tiles) for z, x, y in checks],
    }


def invalid_files():
    (OUT / "invalid-magic.pmtiles").write_bytes(b"NotPMTiles" + bytes(117))
    (OUT / "truncated.pmtiles").write_bytes((OUT / "vector-gzip.pmtiles").read_bytes()[:60])
    return [
        {"file": "invalid-magic.pmtiles", "valid": False},
        {"file": "truncated.pmtiles", "valid": False},
    ]


def main():
    fixtures = [vector_gzip(), raster_leaves(), webp_uncompressed(), *invalid_files()]
    expected = {
        "description": "Expected reader results for the fixtures in this folder. Generated by generate.py.",
        "fixtures": fixtures,
    }
    (OUT / "expected.json").write_text(json.dumps(expected, indent=2) + "\n")
    print(f"wrote {len(fixtures)} fixtures to {OUT}")


if __name__ == "__main__":
    main()
