# Offline downloads for the iPhone app

The iPhone app (and CarPlay) plans routes and searches with no signal using per-state downloads. This folder builds them.

Each state download, `<state>.tar.xz`, holds:

- `valhalla_tiles/…` — the [Valhalla](https://github.com/valhalla/valhalla) routing tiles touching the state's bounding box. The app routes over them with [valhalla-mobile](https://github.com/Rallista/valhalla-mobile).
- `places/<state>.sqlite` — a SQLite FTS5 search index of towns, named places, streets and house addresses.

All states come from **one** Valhalla build of the whole US, so tiles from neighbouring states fit together when someone downloads several. Map tiles aren't in these packs: the app downloads them straight from OpenFreeMap as MapLibre offline packs.

`manifest.json` lists every state with its size, bounding box and SHA-256 checksum. The app reads it from `https://github.com/JDavis008/Roadwise/releases/download/offline-v1/manifest.json` (`OfflineStore.manifestURL`).

## Building (WSL Debian on the build PC, as root)

One-time setup:

```sh
apt-get install -y python3 python3-venv python3-pyosmium osmium-tool sqlite3 xz-utils curl
python3 -m venv --system-site-packages /opt/roadwise/venv
/opt/roadwise/venv/bin/pip install pyvalhalla==3.9.3   # must match valhalla-mobile's Valhalla 3.9.x
```

Build everything (downloads `us-latest.osm.pbf` and each state's extract from Geofabrik first):

```sh
curl -L -o /opt/roadwise/osm/us-latest.osm.pbf https://download.geofabrik.de/north-america/us-latest.osm.pbf
bash tools/ios-offline/build.sh /opt/roadwise/us /opt/roadwise/osm/us-latest.osm.pbf          # all states
bash tools/ios-offline/build.sh /opt/roadwise/us /opt/roadwise/osm/us-latest.osm.pbf iowa     # just one
```

The outputs land in `<work>/out/`. Upload every `.tar.xz` and `manifest.json` to the `offline-v1` release.

## Test pack

`ios/RoadwiseTests/Fixtures/cedar-rapids.tar.xz` is a small pack (downtown Cedar Rapids, Iowa) made the same way from `osmium extract --bbox -91.72,41.95,-91.62,42.02`. The unit tests unpack it, plan routes and search it.

Data © OpenStreetMap contributors, available under the Open Database License (ODbL).
