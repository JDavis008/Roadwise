#!/usr/bin/env bash
# Builds the iPhone app's offline downloads (routing tiles + search index per state).
# Runs in Linux (WSL Debian on the build PC) as root. See README.md.
#
#   build.sh <work_dir> <routing.osm.pbf> [state-slug ...]
#
# <routing.osm.pbf> is the whole area the routing graph covers (us-latest.osm.pbf for the real
# downloads). Each state's search index comes from its own Geofabrik extract. With no slugs,
# every state in states.tsv is built.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK=${1:?work dir}; PBF=${2:?osm pbf}; shift 2
PY=${PY:-/opt/roadwise/venv/bin/python}
BASE_URL=${BASE_URL:-https://github.com/JDavis008/Roadwise/releases/download/offline-v1}
GEOFABRIK=https://download.geofabrik.de/north-america/us
mkdir -p "$WORK"/{poly,places,pbf,out}

if [ "$#" -gt 0 ]; then SLUGS=("$@"); else mapfile -t SLUGS < <(cut -f1 "$HERE/states.tsv"); fi

# 1. One routing graph for everything, so neighbouring states' tiles join up.
if [ ! -f "$WORK/tiles.done" ]; then
  rm -rf "$WORK/valhalla_tiles" && mkdir -p "$WORK/valhalla_tiles" && touch "$WORK/unused.tar"
  "$PY" - "$WORK" <<'EOF'
import json, sys
from valhalla import get_config
work = sys.argv[1]
c = get_config(tile_extract=f"{work}/unused.tar", tile_dir=f"{work}/valhalla_tiles")
c["mjolnir"]["concurrency"] = 12
c["mjolnir"].setdefault("data_processing", {})["use_admin_db"] = False
json.dump(c, open(f"{work}/valhalla.json", "w"), indent=1)
EOF
  echo "== building routing tiles from $PBF"
  "$("$PY" -m valhalla print_bin_path)/valhalla_build_tiles" -c "$WORK/valhalla.json" "$PBF"
  touch "$WORK/tiles.done"
fi

# 2. Search index per state.
for slug in "${SLUGS[@]}"; do
  [ -f "$WORK/poly/$slug.poly" ] || curl -fsSL --retry 5 -o "$WORK/poly/$slug.poly" "$GEOFABRIK/$slug.poly"
  if [ ! -f "$WORK/places/$slug.sqlite" ]; then
    if [ "${PLACES_PBF:-}" != "" ]; then src="$PLACES_PBF"; else
      src="$WORK/pbf/$slug-latest.osm.pbf"
      [ -f "$src" ] || curl -fsSL --retry 5 -o "$src.part" "$GEOFABRIK/$slug-latest.osm.pbf" && mv -f "$src.part" "$src" 2>/dev/null || true
    fi
    echo "== search index for $slug"
    "$PY" "$HERE/make_places.py" "$src" "$WORK/places/$slug.sqlite.tmp"
    mv "$WORK/places/$slug.sqlite.tmp" "$WORK/places/$slug.sqlite"
  fi
done

# 3. One .tar.xz per state + manifest.json.
"$PY" "$HERE/pack_states.py" "$WORK/valhalla_tiles" "$WORK" "$WORK/out" "$BASE_URL" "${SLUGS[@]}"
ls -la "$WORK/out"
