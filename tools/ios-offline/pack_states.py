#!/usr/bin/env python3
"""Packs one offline download per state for the iPhone app.

Usage: pack_states.py <tile_dir> <work_dir> <out_dir> <release_base_url> [slug ...]

Each <slug>.tar.xz holds:
  valhalla_tiles/<level>/<...>.gph   every routing tile touching the state's bounding box
  places/<slug>.sqlite               the offline search index (from make_places.py)
All states come from ONE Valhalla build of the whole US, so tiles from neighbouring states
fit together when someone downloads several. Writes manifest.json with sizes and checksums.
"""
import hashlib
import json
import os
import subprocess
import sys
import tarfile

LEVEL_SIZE = {0: 4.0, 1: 1.0, 2: 0.25}

# Smaller boxes for the map tiles where a state's outline is mostly open ocean
# (routing and search still cover the whole state). The app also lowers the top
# map zoom for any state still over its tile budget, such as Alaska.
MAP_BBOX = {
    "hawaii": [18.86, -160.3, 22.3, -154.75],  # the main islands, Niihau to the Big Island
}


def poly_bbox(path, slug):
    lats, lons = [], []
    with open(path) as f:
        for line in f:
            parts = line.split()
            if len(parts) != 2:
                continue
            try:
                lon, lat = float(parts[0]), float(parts[1])
            except ValueError:
                continue
            if slug == "alaska" and lon > 0:  # Aleutians past the date line
                continue
            lats.append(lat)
            lons.append(lon)
    return min(lats), min(lons), max(lats), max(lons)


def tile_bounds(level, tile_id):
    size = LEVEL_SIZE[level]
    cols = int(360 / size)
    row, col = divmod(tile_id, cols)
    min_lat = -90 + row * size
    min_lon = -180 + col * size
    return min_lat, min_lon, min_lat + size, min_lon + size


def all_tiles(tile_dir):
    for level in (0, 1, 2):
        base = os.path.join(tile_dir, str(level))
        for root, _, files in os.walk(base):
            for fn in files:
                if not fn.endswith(".gph"):
                    continue
                rel = os.path.relpath(os.path.join(root, fn), tile_dir)
                digits = rel.split("/", 1)[1].replace("/", "").replace(".gph", "")
                yield level, int(digits), rel


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main(tile_dir, work, out, base_url, only):
    os.makedirs(out, exist_ok=True)
    states = []
    with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "states.tsv")) as f:
        for line in f:
            slug, name, abbr = line.rstrip("\n").split("\t")
            states.append((slug, name, abbr))
    tiles = list(all_tiles(tile_dir))
    manifest_path = os.path.join(out, "manifest.json")
    manifest = json.load(open(manifest_path)) if os.path.exists(manifest_path) else {"version": 1, "states": []}
    by_slug = {s["id"]: s for s in manifest["states"]}
    for slug, name, abbr in states:
        if only and slug not in only:
            continue
        poly = os.path.join(work, "poly", f"{slug}.poly")
        places = os.path.join(work, "places", f"{slug}.sqlite")
        if not os.path.exists(poly) or not os.path.exists(places):
            print(f"skip {slug}: missing poly or places")
            continue
        s, w, n, e = poly_bbox(poly, slug)
        picked = [rel for level, tid, rel in tiles
                  if (lambda b: b[0] < n and b[2] > s and b[1] < e and b[3] > w)(tile_bounds(level, tid))]
        tar_path = os.path.join(out, f"{slug}.tar")
        with tarfile.open(tar_path, "w", format=tarfile.USTAR_FORMAT) as tar:
            for rel in sorted(picked):
                tar.add(os.path.join(tile_dir, rel), arcname=f"valhalla_tiles/{rel}")
            tar.add(places, arcname=f"places/{slug}.sqlite")
        raw = os.path.getsize(tar_path)
        subprocess.run(["xz", "-f", "-T0", "-6", "--check=crc32", tar_path], check=True)
        xz_path = tar_path + ".xz"
        by_slug[slug] = {
            "id": slug, "name": name, "abbr": abbr,
            "bbox": [round(s, 4), round(w, 4), round(n, 4), round(e, 4)],
            "url": f"{base_url.rstrip('/')}/{slug}.tar.xz",
            "bytes": os.path.getsize(xz_path), "unpackedBytes": raw,
            "sha256": sha256(xz_path), "tiles": len(picked),
        }
        if slug in MAP_BBOX:
            by_slug[slug]["mapBbox"] = MAP_BBOX[slug]
        print(f"{slug}: {len(picked)} tiles, {raw / 1e6:.0f} MB -> {os.path.getsize(xz_path) / 1e6:.0f} MB")
        manifest["states"] = sorted(by_slug.values(), key=lambda x: x["name"])
        json.dump(manifest, open(manifest_path, "w"), indent=1)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], set(sys.argv[5:]))
