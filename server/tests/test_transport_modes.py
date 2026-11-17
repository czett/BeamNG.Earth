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

    def test_infra_bus_stops_dedups_without_tuple_str_typeerror(self):
        # Regression test: Overture infrastructure fallback previously indexed (lat, lon) tuples in `seen` with o["lat"]
        base_lat, base_lon = 48.135, 11.582
        md = FakeMapData()
        infra_items = []
        road_items = []
        for idx, dist_step in enumerate((300.0, 320.0, 720.0, 1150.0, 1600.0, 2050.0)):
            sla, slo = tm.offset_latlon(base_lat, base_lon, dist_step, 90.0)
            infra_items.append({
                "id": f"bus_{idx}",
                "attrs": {"class": "bus_stop", "name": f"Platform {idx}", "tags": "{}"},
                "parts": [[np.array([[slo, sla]], np.float64)]],
            })
            road_items.append(_make_road(f"br_{idx}", sla, slo - 0.001, sla, slo + 0.001, cls="secondary", name="Bus Ave"))
        # Distribute into cell buckets
        by_cell_i, by_cell_r = {}, {}
        for it in infra_items:
            pt = it["parts"][0][0][0]
            by_cell_i.setdefault(mapcells.cell_of(pt[1], pt[0]), []).append(it)
        for r in road_items:
            pt = r["parts"][0][0][0]
            by_cell_r.setdefault(mapcells.cell_of(pt[1], pt[0]), []).append(r)
        for k, items in by_cell_i.items():
            md.put(k, "infrastructure", FakeFeatures(items))
        for k, items in by_cell_r.items():
            md.put(k, "roads", FakeFeatures(items))

        tm._bus_cache.clear()
        empty_net = SimpleNamespace(get=lambda url, kind="demand": SimpleNamespace(body=json.dumps({"elements": []}).encode()))
        rb = tm.generate_job(md, empty_net, mode="bus", tier="partial", lat=base_lat, lon=base_lon, heading=90.0, seed=1)
        self.assertTrue(rb["ok"], rb)
        self.assertEqual(rb["source"], "overture")
        self.assertGreaterEqual(len(rb["stops"]), 4)
        # Paired 300 m and 320 m stops (< 45 m) must deduplicate into one stop
        names = [s["name"] for s in rb["stops"]]
        self.assertNotIn("Platform 1", names)


class CurbAndLoadingBayTest(unittest.TestCase):
    def test_taxi_and_bus_offset_to_right_hand_curb(self):
        # Northbound road (bearing 0 deg) along lon=base_lon: right-hand curb is east (+90 deg)
        base_lat, base_lon = 40.75, -73.98
        k = mapcells.cell_of(base_lat, base_lon)
        md = FakeMapData()
        md.put(k, "roads", FakeFeatures([
            _make_road("r_nb", base_lat - 0.002, base_lon, base_lat + 0.002, base_lon, cls="secondary", name="5th Ave"),
        ]))
        poi_lat, poi_lon = tm.offset_latlon(base_lat, base_lon, 8.0, 90.0)
        snapped = tm.snap_to_road(md, poi_lat, poi_lon, radius_m=100.0)
        curb = tm._apply_curb_offset(snapped, poi_lat, poi_lon, snapped["lat"], snapped["lon"], [])
        self.assertIsNotNone(curb)
        self.assertGreater(curb["lon"], base_lon)
        off_m = tm.dist_m(snapped["lat"], snapped["lon"], curb["lat"], curb["lon"])
        self.assertGreaterEqual(off_m, 1.5)
        self.assertLessEqual(off_m, 4.0)

    def test_logistics_prefers_onsite_aisle_and_clears_building_footprints(self):
        base_lat, base_lon = 41.88, -87.63
        # Warehouse polygon centered at (poi_lat, poi_lon) ~30x30 m
        poi_lat, poi_lon = tm.offset_latlon(base_lat, base_lon, 50.0, 0.0)
        dlat = 15.0 / tm.M_LAT
        dlon = 15.0 / (tm.M_LAT * tm._cos_lat(poi_lat))
        bld = {
            "id": "b_wh",
            "attrs": {"name": "North Dock", "class": "warehouse", "cx": poi_lon, "cy": poi_lat},
            "parts": [[np.array([
                [poi_lon - dlon, poi_lat - dlat],
                [poi_lon + dlon, poi_lat - dlat],
                [poi_lon + dlon, poi_lat + dlat],
                [poi_lon - dlon, poi_lat + dlat],
                [poi_lon - dlon, poi_lat - dlat],
            ], np.float64)]],
        }
        # Main arterial road 50 m south, plus an on-site parking_aisle 24 m east of warehouse center (9 m outside east wall)
        aisle_lon = poi_lon + (24.0 / (tm.M_LAT * tm._cos_lat(poi_lat)))
        md = FakeMapData()
        k = mapcells.cell_of(poi_lat, poi_lon)
        md.put(k, "buildings", FakeFeatures([bld]))
        md.put(k, "roads", FakeFeatures([
            _make_road("r_art", base_lat, base_lon - 0.002, base_lat, base_lon + 0.002, cls="primary", name="Outer Blvd"),
            _make_road("r_aisle", poi_lat - 0.0004, aisle_lon, poi_lat + 0.0004, aisle_lon, cls="service", subclass="parking_aisle", name="Dock Lane"),
        ]))

        bay = tm._snap_logistics_spot(md, poi_lat, poi_lon, tm.time.monotonic() + 2.0)
        self.assertIsNotNone(bay)
        self.assertEqual(bay["stopType"], "loading_bay")
        self.assertEqual(bay["road"], "Dock Lane")
        polys = tm._building_polys(md, poi_lat, poi_lon)
        self.assertTrue(tm._clear_of_buildings(bay["lat"], bay["lon"], poi_lat, poi_lon, polys, 2.5))

        # Without service aisle -> building-perimeter loading bay >= 2.5 m outside wall
        md2 = FakeMapData()
        md2.put(k, "buildings", FakeFeatures([bld]))
        md2.put(k, "roads", FakeFeatures([
            _make_road("r_art", base_lat, base_lon - 0.002, base_lat, base_lon + 0.002, cls="primary", name="Outer Blvd"),
        ]))
        perim = tm._snap_logistics_spot(md2, poi_lat, poi_lon, tm.time.monotonic() + 2.0)
        self.assertIsNotNone(perim)
        self.assertEqual(perim["stopType"], "loading_bay")
        polys2 = tm._building_polys(md2, poi_lat, poi_lon)
        self.assertTrue(tm._clear_of_buildings(perim["lat"], perim["lon"], poi_lat, poi_lon, polys2, 2.5))


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


class Phase2CargoAndDwellTest(unittest.TestCase):
    def test_vehicle_class_cargo_bounds(self):
        md = _seed_corridor_md()
        for vclass, lo, hi, tier in (
            ("car", 80, 350, "long"),        # even on long/city, car never exceeds 350 kg
            ("van", 400, 1400, "city"),
            ("box_truck", 2500, 8000, "city"),
            ("semi", 12000, 26000, "local"),
        ):
            r = tm.generate_job(
                md, None, mode="logistics", tier=tier if tier in ("local", "city") else "city",
                lat=39.285, lon=-76.610, heading=20.0, seed=5,
                vehicle={"class": vclass, "coupler": "fifthwheel" if vclass == "semi" else "none", "hasTrailer": False},
            )
            self.assertTrue(r["ok"], r)
            self.assertEqual(r["vehicleClass"], vclass)
            kg = r["cargo"]["massKg"]
            self.assertGreaterEqual(kg, lo)
            self.assertLessEqual(kg, hi)
            deltas = [s["cargoDeltaKg"] for s in r["stops"]]
            self.assertEqual(deltas[0], kg)
            self.assertEqual(sum(deltas), 0)
            for s in r["stops"]:
                self.assertIn("dwellTargetS", s)
                self.assertGreaterEqual(s["dwellTargetS"], 3.5)

    def test_dynamic_dwell_targets_per_mode(self):
        self.assertTrue(2.0 <= tm.compute_dwell_target_s("taxi", "neighborhood", "pickup", name="Central Cafe") <= 2.5)
        self.assertEqual(tm.compute_dwell_target_s("taxi", "city", "dropoff", name="City Airport"), 3.0)
        self.assertGreaterEqual(tm.compute_dwell_target_s("bus", "partial", "bus_stop", name="Union Station"), 4.5)
        self.assertTrue(3.0 <= tm.compute_dwell_target_s("bus", "partial", "bus_stop", name="Oak & 4th") <= 3.8)
        self.assertTrue(3.5 <= tm.compute_dwell_target_s("logistics", "local", "loading", cargo_kg=800) <= 4.5)
        self.assertTrue(6.0 <= tm.compute_dwell_target_s("logistics", "city", "delivery", cargo_kg=5000) <= 8.0)
        self.assertTrue(9.0 <= tm.compute_dwell_target_s("logistics", "long", "loading", cargo_kg=24000) <= 12.0)


if __name__ == "__main__":
    unittest.main()
