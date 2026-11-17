"""Unit tests for Transport Modes (server/transport_modes.py)."""
import json
import os
import sys
import unittest
from types import SimpleNamespace
from unittest import mock

import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import mapcells  # noqa: E402
import transport_modes as tm  # noqa: E402


class FakeFeatures:
    """Minimal Overture Features test double supporting ids, attrs, parts(), and rules."""

    def __init__(self, items, rules=None):
        self.ids = [it["id"] for it in items]
        self._parts = [it["parts"] for it in items]
        self.rules = rules or {}
        keys = set()
        for it in items:
            keys.update(it.get("attrs", {}).keys())
        self.attrs = {k: [it.get("attrs", {}).get(k, "") for it in items] for k in keys}

    def parts(self, i):
        return self._parts[i]


class FakeMapData:
    """In-memory MapData stub indexed by (cell_key, layer)."""

    def __init__(self):
        self.cells = {}

    def put(self, key, layer, feats):
        self.cells[(key, layer)] = feats

    def has(self, key, layer):
        return (key, layer) in self.cells

    def cell(self, key, layers=("roads",), kind="demand"):
        return SimpleNamespace(layers={ly: self.cells.get((key, ly)) for ly in layers})


def _make_road(fid, lat0, lon0, lat1, lon1, cls="residential", name="Main St", subtype="road", subclass="", is_bridge=False):
    attrs = {"class": cls, "name": name, "subtype": subtype}
    if subclass:
        attrs["subclass"] = subclass
    if is_bridge:
        attrs["level_rules"] = [{"value": 1, "between": [0.0, 1.0]}]
    return {"id": fid, "attrs": attrs, "parts": [[np.array([[lon0, lat0], [lon1, lat1]], np.float64)]]}


def _make_place(fid, lat, lon, name, cat="cafe"):
    return {
        "id": fid,
        "attrs": {"name": name, "basic_category": cat, "taxonomy": cat, "operating_status": "open", "confidence": 0.9, "cx": lon, "cy": lat},
        "parts": [[np.array([[lon, lat]], np.float64)]],
    }


def _make_building(fid, lat, lon, name, cls="warehouse"):
    return {
        "id": fid,
        "attrs": {"name": name, "class": cls, "cx": lon, "cy": lat},
        "parts": [[np.array([[lon, lat], [lon + 0.0001, lat], [lon + 0.0001, lat + 0.0001]], np.float64)]],
    }


def _seed_corridor_md(base_lat=39.285, base_lon=-76.610):
    """Build synthetic MapData covering ~15 km north/east around (base_lat, base_lon)."""
    md = FakeMapData()
    # Populate a grid of cells around base and stepped distances (up to ~14 km)
    road_buckets = {}
    place_buckets = {}
    bld_buckets = {}

    def add_road(r, lat, lon):
        k = mapcells.cell_of(lat, lon)
        road_buckets.setdefault(k, []).append(r)

    # Local dense street grid around origin (including footway & bridge to verify exclusion)
    add_road(_make_road("r_foot", base_lat, base_lon, base_lat + 0.002, base_lon, cls="footway", name="Park Path"), base_lat, base_lon)
    add_road(_make_road("r_drv", base_lat, base_lon, base_lat + 0.002, base_lon, cls="service", subclass="driveway", name="Driveway"), base_lat, base_lon)
    add_road(_make_road("r_main", base_lat - 0.003, base_lon + 0.003, base_lat + 0.015, base_lon + 0.003, cls="secondary", name="Harbor St"), base_lat, base_lon)

    # Roads & places every ~1 km out to 14 km northeast and north
    for km in range(1, 15):
        la, lo = tm.offset_latlon(base_lat, base_lon, km * 1000.0, 20.0)
        la2, lo2 = tm.offset_latlon(la, lo, 250.0, 90.0)
        k = mapcells.cell_of(la, lo)
        road_buckets.setdefault(k, []).append(
            _make_road(f"r_{km}", la - 0.001, lo - 0.001, la2, lo2, cls="secondary", name=f"Corridor Rd {km}")
        )
        place_buckets.setdefault(k, []).append(
            _make_place(f"p_{km}", la + 0.0002, lo + 0.0002, f"Market Square {km}", cat="supermarket" if km % 2 else "hotel")
        )
        bld_buckets.setdefault(k, []).append(
            _make_building(f"b_{km}", la - 0.0002, lo + 0.0002, f"Depot {km}", cls="warehouse")
        )

    # Pickup POI near 500 m from base
    pu_lat, pu_lon = tm.offset_latlon(base_lat, base_lon, 550.0, 20.0)
    pk = mapcells.cell_of(pu_lat, pu_lon)
    place_buckets.setdefault(pk, []).append(_make_place("p_pu", pu_lat, pu_lon, "Central Cafe", cat="cafe"))
    road_buckets.setdefault(pk, []).append(_make_road("r_pu", pu_lat - 0.001, pu_lon, pu_lat + 0.001, pu_lon, cls="residential", name="Pratt St"))

    for k, items in road_buckets.items():
        md.put(k, "roads", FakeFeatures(items))
    for k, items in place_buckets.items():
        md.put(k, "places", FakeFeatures(items))
    for k, items in bld_buckets.items():
        md.put(k, "buildings", FakeFeatures(items))
    return md


class ValidationTest(unittest.TestCase):
    def test_validate_request(self):
        req, err = tm.validate_request({"mode": "Taxi", "tier": "City", "lat": 39.28, "lon": -76.61, "heading": 450})
        self.assertIsNone(err)
        self.assertEqual(req["mode"], "taxi")
        self.assertEqual(req["tier"], "city")
        self.assertAlmostEqual(req["heading"], 90.0)

        for bad in (
            {"mode": "plane", "tier": "city", "lat": 0, "lon": 0},
            {"mode": "taxi", "tier": "long", "lat": 0, "lon": 0},
            {"mode": "bus", "tier": "partial", "lat": float("nan"), "lon": 0},
            {"mode": "logistics", "tier": "local", "lat": 91.0, "lon": 0},
        ):
            r, e = tm.validate_request(bad)
            self.assertIsNone(r)
            self.assertIsInstance(e, str)


class SnapToRoadTest(unittest.TestCase):
    def test_excludes_footway_driveway_and_bridges(self):
        lat, lon = 39.285, -76.610
        key = mapcells.cell_of(lat, lon)
        md = FakeMapData()
        # Footway right at player, driveway right next to player, real street 80 m east
        r_lat, r_lon = tm.offset_latlon(lat, lon, 80.0, 90.0)
        b_lat, b_lon = tm.offset_latlon(lat, lon, 20.0, 0.0)
        feats = FakeFeatures([
            _make_road("foot", lat, lon, lat + 0.001, lon, cls="footway", name="Walkway"),
            _make_road("drv", lat, lon + 0.0001, lat + 0.001, lon + 0.0001, cls="service", subclass="driveway", name="Alley Drive"),
            _make_road("br", b_lat, b_lon - 0.001, b_lat, b_lon + 0.001, cls="primary", name="Sky Bridge"),
            _make_road("st", r_lat - 0.001, r_lon, r_lat + 0.001, r_lon, cls="residential", name="Oak St"),
        ])
        md.put(key, "roads", feats)
        # Mock quick_ground_parts so "br" has no ground parts (it is 100% bridge)
        orig_qgp = tm.roadsmod.quick_ground_parts
        with mock.patch.object(tm.roadsmod, "quick_ground_parts", side_effect=lambda f, i: [] if f.ids[i] == "br" else orig_qgp(f, i)):
            snapped = tm.snap_to_road(md, lat, lon, radius_m=250.0)
        self.assertIsNotNone(snapped)
        self.assertEqual(snapped["road"], "Oak St")
        self.assertEqual(snapped["roadClass"], "residential")


class TaxiModeTest(unittest.TestCase):
    def test_neighborhood_and_city_deterministic(self):
        md = _seed_corridor_md()
        r1 = tm.generate_job(md, None, mode="taxi", tier="neighborhood", lat=39.285, lon=-76.610, heading=20.0, seed=7)
        r2 = tm.generate_job(md, None, mode="taxi", tier="neighborhood", lat=39.285, lon=-76.610, heading=20.0, seed=7)
        self.assertTrue(r1["ok"], r1)
        self.assertEqual(r1, r2)
        self.assertEqual(len(r1["stops"]), 2)
        self.assertEqual(r1["stops"][0]["kind"], "pickup")
        self.assertEqual(r1["stops"][1]["kind"], "dropoff")
        d = tm.dist_m(r1["stops"][0]["lat"], r1["stops"][0]["lon"], r1["stops"][1]["lat"], r1["stops"][1]["lon"])
        self.assertGreaterEqual(d, 950.0)
        self.assertLessEqual(d, 4000.0)

        rc = tm.generate_job(md, None, mode="taxi", tier="city", lat=39.285, lon=-76.610, heading=20.0, seed=3)
        self.assertTrue(rc["ok"], rc)
        dc = tm.dist_m(rc["stops"][0]["lat"], rc["stops"][0]["lon"], rc["stops"][1]["lat"], rc["stops"][1]["lon"])
        self.assertGreaterEqual(dc, 3800.0)
        self.assertLessEqual(dc, 15000.0)

    def test_regional_uses_towns_globally(self):
        # Southern hemisphere test location (Sydney area)
        base_lat, base_lon = -33.868, 151.209
        t_lat, t_lon = tm.offset_latlon(base_lat, base_lon, 35000.0, 40.0)
        md = FakeMapData()
        for la, lo, nm in ((base_lat, base_lon, "George St"), (t_lat, t_lon, "Coast Hwy")):
            k = mapcells.cell_of(la, lo)
            md.put(k, "roads", FakeFeatures([_make_road(f"r_{nm}", la - 0.003, lo - 0.001, la + 0.005, lo + 0.001, cls="secondary", name=nm)]))
        with mock.patch.object(tm.randomplace, "towns", return_value=[(t_lat, t_lon, "Gosford")]):
            r = tm.generate_job(md, None, mode="taxi", tier="regional", lat=base_lat, lon=base_lon, heading=40.0, seed=1)
        self.assertTrue(r["ok"], r)
        self.assertEqual(len(r["stops"]), 2)
        self.assertIn("Gosford", r["stops"][1]["address"] + " " + r["stops"][1]["name"])


class BusModeTest(unittest.TestCase):
    def test_parse_bus_relations_dedups_stop_and_platform(self):
        base_lat, base_lon = 50.08, 14.42
        stops_el = []
        members = []
        for i in range(1, 6):
            sla, slo = tm.offset_latlon(base_lat, base_lon, i * 400.0, 90.0)
            pla, plo = tm.offset_latlon(sla, slo, 12.0, 0.0)  # < 45 m paired platform
            stops_el.append({"type": "node", "id": 100 + i, "lat": sla, "lon": slo, "tags": {"public_transport": "stop_position", "name": f"Stop {i}"}})
            stops_el.append({"type": "way", "id": 200 + i, "center": {"lat": pla, "lon": plo}, "tags": {"public_transport": "platform", "name": f"Stop {i} Plat"}})
            members.append({"type": "node", "ref": 100 + i, "role": "stop"})
            members.append({"type": "way", "ref": 200 + i, "role": "platform"})
        rel = {"type": "relation", "id": 999, "tags": {"type": "route", "route": "bus", "ref": "22", "name": "Line 22"}, "members": members}
        parsed = tm.parse_bus_relations({"elements": stops_el + [rel]})
        self.assertEqual(len(parsed), 1)
        self.assertEqual(parsed[0]["ref"], "22")
        self.assertEqual(len(parsed[0]["stops"]), 5)
        self.assertEqual(parsed[0]["stops"][0]["name"], "Stop 1")

    def test_osm_overpass_and_fallbacks(self):
        base_lat, base_lon = 50.08, 14.42
        md = _seed_corridor_md(base_lat, base_lon)
        payload = {"elements": []}
        members = []
        for i in range(1, 9):
            sla, slo = tm.offset_latlon(base_lat, base_lon, i * 350.0, 20.0)
            payload["elements"].append({"type": "node", "id": i, "lat": sla, "lon": slo, "tags": {"highway": "bus_stop", "name": f"Tram/Bus {i}"}})
            members.append({"type": "node", "ref": i, "role": "stop"})
        payload["elements"].append({"type": "relation", "id": 50, "tags": {"route": "bus", "ref": "133", "name": "133 Express"}, "members": members})

        fake_net = SimpleNamespace(get=lambda url, kind="demand": SimpleNamespace(body=json.dumps(payload).encode()))
        tm._bus_cache.clear()
        rp = tm.generate_job(md, fake_net, mode="bus", tier="partial", lat=base_lat, lon=base_lon, heading=20.0, seed=1)
        self.assertTrue(rp["ok"], rp)
        self.assertEqual(rp["source"], "osm_bus")
        self.assertTrue(4 <= len(rp["stops"]) <= 6)

        rf = tm.generate_job(md, fake_net, mode="bus", tier="full", lat=base_lat, lon=base_lon, heading=20.0, seed=1)
        self.assertTrue(rf["ok"], rf)
        self.assertEqual(len(rf["stops"]), 8)

        # Overpass error -> falls back cleanly to Overture / road_chain without failing
        tm._bus_cache.clear()
        bad_net = SimpleNamespace(get=mock.Mock(side_effect=RuntimeError("overpass 429")))
        rb = tm.generate_job(md, bad_net, mode="bus", tier="partial", lat=base_lat, lon=base_lon, heading=20.0, seed=2)
        self.assertTrue(rb["ok"], rb)
        self.assertIn(rb["source"], ("overture", "road_chain"))
        self.assertGreaterEqual(len(rb["stops"]), 4)


class LogisticsModeTest(unittest.TestCase):
    def test_local_and_city_delivery(self):
        md = _seed_corridor_md()
        rl = tm.generate_job(md, None, mode="logistics", tier="local", lat=39.285, lon=-76.610, heading=20.0, seed=4)
        self.assertTrue(rl["ok"], rl)
        self.assertTrue(3 <= len(rl["stops"]) <= 4)
        self.assertEqual(rl["stops"][0]["kind"], "loading")

        rc = tm.generate_job(md, None, mode="logistics", tier="city", lat=39.285, lon=-76.610, heading=20.0, seed=4)
        self.assertTrue(rc["ok"], rc)
        self.assertTrue(5 <= len(rc["stops"]) <= 8)

    def test_regional_and_long_haul_no_overpass(self):
        base_lat, base_lon = 52.52, 13.405  # Berlin
        d50_lat, d50_lon = tm.offset_latlon(base_lat, base_lon, 50000.0, 90.0)
        d115_lat, d115_lon = tm.offset_latlon(base_lat, base_lon, 115000.0, 90.0)
        md = FakeMapData()
        for la, lo, nm in (
            (base_lat, base_lon, "Berlin Freight Yard"),
            (d50_lat, d50_lon, "Frankfurt Oder Logistics"),
            (d115_lat, d115_lon, "Poznan West Depot"),
        ):
            k = mapcells.cell_of(la, lo)
            md.put(k, "roads", FakeFeatures([_make_road(f"r_{nm}", la - 0.008, lo - 0.008, la + 0.008, lo + 0.008, cls="primary", name="Freight Rd")]))
            md.put(k, "land_use", FakeFeatures([{"id": f"lu_{nm}", "attrs": {"name": nm, "class": "industrial", "cx": lo, "cy": la}, "parts": [[np.array([[lo, la]], np.float64)]]}]))

        net = SimpleNamespace(get=mock.Mock(side_effect=AssertionError("Overpass must not be called for logistics")))
        with mock.patch.object(tm.randomplace, "towns", return_value=[(d50_lat, d50_lon, "Furstenwalde"), (d115_lat, d115_lon, "Zielona Gora")]):
            rr = tm.generate_job(md, net, mode="logistics", tier="regional", lat=base_lat, lon=base_lon, heading=90.0, seed=1)
            rl = tm.generate_job(md, net, mode="logistics", tier="long", lat=base_lat, lon=base_lon, heading=90.0, seed=1)
        self.assertTrue(rr["ok"], rr)
        self.assertTrue(2 <= len(rr["stops"]) <= 3)
        self.assertTrue(rl["ok"], rl)
        self.assertEqual(len(rl["stops"]), 2)
        self.assertGreater(rl["estimatedKm"], 95.0)
        net.get.assert_not_called()


if __name__ == "__main__":
    unittest.main()
