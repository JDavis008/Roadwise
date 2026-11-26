#!/usr/bin/env python3
"""Builds the offline search index for one area from an OpenStreetMap extract.

Usage: make_places.py <input.osm.pbf> <output.sqlite>

The index is one SQLite FTS5 table the iPhone app queries with no signal: towns, named places
(gas, food, shops, parks...), street names (one row per street per ~2 km cell) and house
addresses. Ways are placed at the average of their nodes.
"""
import sqlite3
import sys

import osmium

# (tag key, value or None for any) -> (category label, emoji)
CATEGORIES = [
    (("amenity", "fuel"), ("gas station", "⛽")),
    (("amenity", "charging_station"), ("EV charging", "🔌")),
    (("amenity", "restaurant"), ("restaurant", "🍽️")),
    (("amenity", "fast_food"), ("fast food", "🍔")),
    (("amenity", "cafe"), ("cafe", "☕")),
    (("amenity", "bar"), ("bar", "🍺")),
    (("amenity", "pub"), ("pub", "🍺")),
    (("amenity", "parking"), ("parking", "🅿️")),
    (("amenity", "hospital"), ("hospital", "🏥")),
    (("amenity", "pharmacy"), ("pharmacy", "💊")),
    (("amenity", "school"), ("school", "🏫")),
    (("amenity", "university"), ("university", "🎓")),
    (("amenity", "bank"), ("bank", "🏦")),
    (("amenity", "post_office"), ("post office", "📮")),
    (("amenity", "police"), ("police", "👮")),
    (("amenity", "fire_station"), ("fire station", "🚒")),
    (("amenity", "place_of_worship"), ("place of worship", "⛪")),
    (("amenity", "toilets"), ("restrooms", "🚻")),
    (("shop", "supermarket"), ("supermarket", "🛒")),
    (("shop", "convenience"), ("convenience store", "🏪")),
    (("shop", "grocery"), ("grocery", "🛒")),
    (("tourism", "hotel"), ("hotel", "🛏️")),
    (("tourism", "motel"), ("motel", "🛏️")),
    (("tourism", "camp_site"), ("campground", "🏕️")),
    (("tourism", "attraction"), ("attraction", "📍")),
    (("tourism", "museum"), ("museum", "🏛️")),
    (("leisure", "park"), ("park", "🌳")),
    (("leisure", "stadium"), ("stadium", "🏟️")),
    (("aeroway", "aerodrome"), ("airport", "✈️")),
    (("railway", "station"), ("station", "🚉")),
    (("highway", "rest_area"), ("rest area", "🅿️")),
    (("amenity", None), (None, "📍")),
    (("shop", None), (None, "🛍️")),
    (("tourism", None), (None, "📍")),
    (("leisure", None), (None, "📍")),
    (("office", None), (None, "🏢")),
    (("healthcare", None), (None, "🏥")),
    (("craft", None), (None, "📍")),
]
TOWNS = {"city": 6, "town": 5, "village": 4, "hamlet": 2, "suburb": 3, "neighbourhood": 2, "locality": 1}
STREETS = {"motorway", "trunk", "primary", "secondary", "tertiary", "unclassified", "residential",
           "living_street", "service", "track", "motorway_link", "trunk_link", "primary_link", "secondary_link"}


def category(tags):
    for (k, v), (label, emoji) in CATEGORIES:
        val = tags.get(k)
        if val is None or (v is not None and val != v):
            continue
        return (label or val.replace("_", " ")), emoji
    return None


def address_of(tags):
    street = " ".join(x for x in (tags.get("addr:housenumber"), tags.get("addr:street")) if x)
    town = tags.get("addr:city") or tags.get("addr:place") or ""
    return ", ".join(x for x in (street, town) if x)


class Handler(osmium.SimpleHandler):
    def __init__(self, db):
        super().__init__()
        self.db = db
        self.rows = []
        self.streets = set()

    def add(self, name, address, kind, emoji, lat, lon, boost):
        self.rows.append((name, address, kind, emoji or "", round(lat, 6), round(lon, 6), boost))
        if len(self.rows) >= 50000:
            self.flush()

    def flush(self):
        self.db.executemany("INSERT INTO places(name, address, kind, emoji, lat, lon, boost) VALUES (?,?,?,?,?,?,?)", self.rows)
        self.rows = []

    def thing(self, tags, lat, lon, way_nodes=None):
        name = tags.get("name")
        place = tags.get("place")
        if name and place in TOWNS:
            self.add(name, tags.get("is_in:state") or "", place, "🏘️", lat, lon, TOWNS[place])
            return
        if name:
            cat = category(tags)
            if cat:
                self.add(name, address_of(tags), cat[0], cat[1], lat, lon, 1.5)
                return
        if tags.get("addr:housenumber") and tags.get("addr:street"):
            label = f"{tags['addr:housenumber']} {tags['addr:street']}"
            town = tags.get("addr:city") or tags.get("addr:place") or ""
            extra = " ".join(x for x in (town, tags.get("addr:postcode") or "") if x)
            self.add(label, extra, "address", "🏠", lat, lon, 0.6)

    def node(self, n):
        if len(n.tags) == 0 or not n.location.valid():
            return
        self.thing(n.tags, n.location.lat, n.location.lon)

    def way(self, w):
        tags = w.tags
        if len(tags) == 0:
            return
        pts = [(nd.lat, nd.lon) for nd in w.nodes if nd.location.valid()]
        if not pts:
            return
        hw = tags.get("highway")
        name = tags.get("name")
        if hw in STREETS and name:
            # One row per street name per ~2 km cell, at the middle node.
            mid = pts[len(pts) // 2]
            key = (name, round(mid[0] / 0.02), round(mid[1] / 0.02))
            if key not in self.streets:
                self.streets.add(key)
                self.add(name, "", "street", "🛣️", mid[0], mid[1], 1.0)
            return
        lat = sum(p[0] for p in pts) / len(pts)
        lon = sum(p[1] for p in pts) / len(pts)
        self.thing(tags, lat, lon)


def main(src, out):
    db = sqlite3.connect(out)
    db.executescript("""
        PRAGMA journal_mode=OFF; PRAGMA synchronous=OFF;
        DROP TABLE IF EXISTS places;
        CREATE VIRTUAL TABLE places USING fts5(
            name, address, kind UNINDEXED, emoji UNINDEXED, lat UNINDEXED, lon UNINDEXED, boost UNINDEXED,
            tokenize = 'unicode61 remove_diacritics 2', prefix = '2 3 4');
        CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
    """)
    h = Handler(db)
    h.apply_file(src, locations=True, idx="flex_mem")
    h.flush()
    count = db.execute("SELECT count(*) FROM places").fetchone()[0]
    db.execute("INSERT OR REPLACE INTO meta VALUES ('rows', ?)", (str(count),))
    db.commit()
    db.execute("INSERT INTO places(places) VALUES ('optimize')")
    db.commit()
    db.execute("VACUUM")
    db.close()
    print(f"{out}: {count} rows")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
