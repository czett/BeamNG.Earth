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

        # Legacy "neighborhood" normalizes to "short"
        req_s, err_s = tm.validate_request({"mode": "taxi", "tier": "neighborhood", "lat": 39.28, "lon": -76.61})
        self.assertIsNone(err_s)
        self.assertEqual(req_s["tier"], "short")

        req_l, err_l = tm.validate_request({"mode": "taxi", "tier": "long", "lat": 39.28, "lon": -76.61})
        self.assertIsNone(err_l)
        self.assertEqual(req_l["tier"], "long")

        for bad in (
            {"mode": "plane", "tier": "city", "lat": 0, "lon": 0},
            {"mode": "taxi", "tier": "express", "lat": 0, "lon": 0},
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
    def test_short_and_city_deterministic(self):
        md = _seed_corridor_md()
        r1 = tm.generate_job(md, None, mode="taxi", tier="short", lat=39.285, lon=-76.610, heading=20.0, seed=7)
        r2 = tm.generate_job(md, None, mode="taxi", tier="short", lat=39.285, lon=-76.610, heading=20.0, seed=7)
        self.assertTrue(r1["ok"], r1)
        self.assertEqual(r1, r2)
        self.assertEqual(len(r1["stops"]), 2)
        self.assertEqual(r1["stops"][0]["kind"], "pickup")
        self.assertEqual(r1["stops"][1]["kind"], "dropoff")
        d = tm.dist_m(r1["stops"][0]["lat"], r1["stops"][0]["lon"], r1["stops"][1]["lat"], r1["stops"][1]["lon"])
        self.assertGreaterEqual(d, 950.0)
        self.assertLessEqual(d, 4400.0)

        rc = tm.generate_job(md, None, mode="taxi", tier="city", lat=39.285, lon=-76.610, heading=20.0, seed=3)
        self.assertTrue(rc["ok"], rc)
        dc = tm.dist_m(rc["stops"][0]["lat"], rc["stops"][0]["lon"], rc["stops"][1]["lat"], rc["stops"][1]["lon"])
        self.assertGreaterEqual(dc, 3800.0)
        self.assertLessEqual(dc, 15000.0)

    def test_regional_and_long_use_towns_globally(self):
        # Southern hemisphere test location (Sydney area)
        base_lat, base_lon = -33.868, 151.209
        t_lat, t_lon = tm.offset_latlon(base_lat, base_lon, 35000.0, 40.0)
        l_lat, l_lon = tm.offset_latlon(base_lat, base_lon, 80000.0, 40.0)
        md = FakeMapData()
        for la, lo, nm in ((base_lat, base_lon, "George St"), (t_lat, t_lon, "Coast Hwy"), (l_lat, l_lon, "Airport Rd")):
            k = mapcells.cell_of(la, lo)
            md.put(k, "roads", FakeFeatures([_make_road(f"r_{nm}", la - 0.003, lo - 0.001, la + 0.005, lo + 0.001, cls="secondary", name=nm)]))
        with mock.patch.object(tm.randomplace, "towns", return_value=[(t_lat, t_lon, "Gosford"), (l_lat, l_lon, "Newcastle Airport")]):
            r = tm.generate_job(md, None, mode="taxi", tier="regional", lat=base_lat, lon=base_lon, heading=40.0, seed=1)
            rl = tm.generate_job(md, None, mode="taxi", tier="long", lat=base_lat, lon=base_lon, heading=40.0, seed=1)
        self.assertTrue(r["ok"], r)
        self.assertEqual(len(r["stops"]), 2)
        self.assertIn("Gosford", r["stops"][1]["address"] + " " + r["stops"][1]["name"])
        self.assertTrue(rl["ok"], rl)
        self.assertEqual(len(rl["stops"]), 2)
        self.assertIn("Newcastle Airport", rl["stops"][1]["address"] + " " + rl["stops"][1]["name"])


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
    def test_local_and_city_delivery_even_cycles(self):
        md = _seed_corridor_md()
        for seed in range(8):
            rl = tm.generate_job(md, None, mode="logistics", tier="local", lat=39.285, lon=-76.610, heading=20.0, seed=seed)
            self.assertTrue(rl["ok"], rl)
            self.assertIn(len(rl["stops"]), (2, 4))
            self.assertEqual(len(rl["stops"]) % 2, 0)
            self.assertEqual(rl["stops"][0]["kind"], "loading")
            self.assertEqual(rl["stops"][1]["kind"], "delivery")

            rc = tm.generate_job(md, None, mode="logistics", tier="city", lat=39.285, lon=-76.610, heading=20.0, seed=seed)
            self.assertTrue(rc["ok"], rc)
            self.assertIn(len(rc["stops"]), (4, 6))
            self.assertEqual(len(rc["stops"]) % 2, 0)
            self.assertEqual(sum(s["cargoDeltaKg"] for s in rc["stops"]), 0)

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
        self.assertIn(len(rr["stops"]), (2, 4))
        self.assertEqual(len(rr["stops"]) % 2, 0)
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
                if vclass == "semi":
                    self.assertEqual(s["dwellTargetS"], 2.5)
                else:
                    self.assertTrue(3.5 <= s["dwellTargetS"] <= 8.0)

    def test_dynamic_dwell_targets_per_mode(self):
        self.assertTrue(2.0 <= tm.compute_dwell_target_s("taxi", "short", "pickup", name="Central Cafe") <= 2.5)
        self.assertEqual(tm.compute_dwell_target_s("taxi", "city", "dropoff", name="City Airport"), 3.0)
        self.assertEqual(tm.compute_dwell_target_s("taxi", "long", "dropoff", name="Oak St"), 3.0)
        self.assertGreaterEqual(tm.compute_dwell_target_s("bus", "partial", "bus_stop", name="Union Station"), 4.5)
        self.assertTrue(3.0 <= tm.compute_dwell_target_s("bus", "partial", "bus_stop", name="Oak & 4th") <= 3.8)
        self.assertTrue(3.5 <= tm.compute_dwell_target_s("logistics", "local", "loading", cargo_kg=800, leg_kind="loaded_solo") <= 4.5)
        self.assertTrue(6.0 <= tm.compute_dwell_target_s("logistics", "city", "delivery", cargo_kg=5000, leg_kind="loaded_solo") <= 8.0)
        self.assertEqual(tm.compute_dwell_target_s("logistics", "long", "loading", cargo_kg=24000, leg_kind="loaded_trailer"), 2.5)
        self.assertEqual(tm.compute_dwell_target_s("logistics", "city", "deadhead", cargo_kg=0, leg_kind="deadhead"), 2.5)


class Phase3SemanticAndGameplayTest(unittest.TestCase):
    def test_semantic_cargo_matching(self):
        self.assertEqual(tm.classify_poi_cargo_domain(cat="supermarket", name="Fresh Mart"), "food")
        self.assertEqual(tm.classify_poi_cargo_domain(cat="pharmacy", name="City Pharmacy"), "medical")
        self.assertEqual(tm.classify_poi_cargo_domain(cat="hardware_store", name="Ace Hardware"), "hardware")
        self.assertEqual(tm.classify_poi_cargo_domain(cat="fuel", name="Shell Station"), "fuel")
        self.assertEqual(tm.classify_poi_cargo_domain(bld_class="warehouse", name="Central Hub"), "industrial")
        self.assertEqual(tm.classify_poi_cargo_domain(name="Mystery Building"), "general")

        # Supermarket never gets steel or machinery
        for seed in range(25):
            c = tm.generate_cargo_manifest({"class": "semi", "coupler": "fifthwheel"}, "city", seed, dest_domain="food")
            self.assertEqual(c["domain"], "food")
            self.assertNotIn(c["type"], ("steel", "machinery", "fuel"))

        c_fuel = tm.generate_cargo_manifest({"class": "semi", "coupler": "fifthwheel"}, "regional", 1, dest_domain="fuel")
        self.assertEqual(c_fuel["type"], "fuel")

    def test_towhitch_intentional_variety(self):
        v = {"class": "van", "coupler": "towhitch", "hasTrailer": False}
        local_trailers = sum(1 for s in range(60) if tm.generate_cargo_manifest(v, "local", s)["useTrailer"])
        city_trailers = sum(1 for s in range(60) if tm.generate_cargo_manifest(v, "city", s)["useTrailer"])
        self.assertTrue(24 <= local_trailers <= 48, f"local_trailers={local_trailers}")
        self.assertTrue(34 <= city_trailers <= 56, f"city_trailers={city_trailers}")
        for s in range(20):
            m = tm.generate_cargo_manifest(v, "local", s)
            if not m["useTrailer"]:
                self.assertTrue(350 <= m["massKg"] <= 1400)

    def test_taxi_archetypes_and_bus_passengers_schedule(self):
        md = _seed_corridor_md()
        arches = set()
        for s in range(30):
            rt = tm.generate_job(md, None, mode="taxi", tier="city", lat=39.285, lon=-76.610, heading=20.0, seed=s)
            self.assertTrue(rt["ok"], rt)
            tx = rt["taxi"]
            arches.add(tx["archetype"])
            self.assertIn(tx["paxCount"], (1, 2, 3))
            self.assertEqual(tx["paxMassKg"], tx["paxCount"] * 80)
        self.assertEqual(arches, {"standard", "express", "vip"})

        tm._bus_cache.clear()
        bad_net = SimpleNamespace(get=mock.Mock(side_effect=RuntimeError("offline")))
        rb = tm.generate_job(md, bad_net, mode="bus", tier="partial", lat=39.285, lon=-76.610, heading=20.0, seed=3)
        self.assertTrue(rb["ok"], rb)
        self.assertEqual(rb["bus"]["capacity"], 40)
        prev_t = 0.0
        for idx, st in enumerate(rb["stops"]):
            self.assertGreater(st["targetArrivalS"], prev_t)
            prev_t = st["targetArrivalS"]
            if idx == 0:
                self.assertEqual(st["paxAlight"], 0)
            else:
                self.assertTrue(0 <= st["paxAlight"] <= 8)
            self.assertTrue(2 <= st["paxBoard"] <= 12)
            self.assertTrue(0 <= st["paxAfter"] <= 40)
            self.assertIn("roadClass", st)
            self.assertIn("bidirectional", st)


class Phase4MultiLegLogisticsTest(unittest.TestCase):
    def test_multi_leg_deadhead_and_trailer_swap(self):
        md = _seed_corridor_md()
        r = tm.generate_job(
            md, None, mode="logistics", tier="city",
            lat=39.285, lon=-76.610, heading=20.0, seed=6,
            vehicle={
                "class": "semi", "coupler": "fifthwheel", "hasTrailer": False,
                "trailerModels": {"fifthwheel": ["dryvan", "reefer", "flatbed", "tanker"]},
            },
        )
        self.assertTrue(r["ok"], r)
        stops = r["stops"]
        legs = r["legs"]
        self.assertEqual(len(legs), len(stops) - 1)
        deadheads = [lg for lg in legs if lg["legKind"] == "deadhead"]
        loaded = [lg for lg in legs if lg["legKind"] == "loaded_trailer"]
        self.assertGreaterEqual(len(deadheads), 1)
        self.assertGreaterEqual(len(loaded), 2)
        for dh in deadheads:
            self.assertEqual(dh["cargoMassKg"], 0)
            self.assertEqual(dh["cargoType"], "")
            self.assertIsNone(dh["trailerModel"])
        for ld in loaded:
            self.assertGreaterEqual(ld["cargoMassKg"], 12000)
            self.assertIn(ld["trailerModel"], ("dryvan", "reefer", "flatbed", "tanker"))
            self.assertTrue(ld["trailerLabel"])
        self.assertEqual(sum(s["cargoDeltaKg"] for s in stops), 0)

    def test_installed_trailer_filtering_and_player_owned_trailer(self):
        md = _seed_corridor_md()
        r_inst = tm.generate_job(
            md, None, mode="logistics", tier="city",
            lat=39.285, lon=-76.610, heading=20.0, seed=4,
            vehicle={
                "class": "semi", "coupler": "fifthwheel", "hasTrailer": False,
                "trailerModels": {"fifthwheel": ["dryvan", "tanker"]},
            },
        )
        self.assertTrue(r_inst["ok"], r_inst)
        for lg in r_inst["legs"]:
            if lg["legKind"] == "loaded_trailer":
                self.assertIn(lg["trailerModel"], ("dryvan", "tanker"))

        r_owned = tm.generate_job(
            md, None, mode="logistics", tier="local",
            lat=39.285, lon=-76.610, heading=20.0, seed=2,
            vehicle={"class": "semi", "coupler": "fifthwheel", "hasTrailer": True},
        )
        self.assertTrue(r_owned["ok"], r_owned)
        for lg in r_owned["legs"]:
            self.assertIsNone(lg["trailerModel"])

    def test_solo_vehicle_multi_leg_has_deadhead_and_no_trailers(self):
        md = _seed_corridor_md()
        r = tm.generate_job(
            md, None, mode="logistics", tier="city",
            lat=39.285, lon=-76.610, heading=20.0, seed=5,
            vehicle={"class": "van", "coupler": "none", "hasTrailer": False},
        )
        self.assertTrue(r["ok"], r)
        for lg in r["legs"]:
            self.assertIn(lg["legKind"], ("loaded_solo", "deadhead"))
            self.assertIsNone(lg["trailerModel"])

    def test_derive_sector_label(self):
        self.assertEqual(tm.derive_sector_label(cat="supermarket", name="Edeka"), "Supermarket")
        self.assertEqual(tm.derive_sector_label(cat="bakery", name="Bäckerei"), "Bakery")
        self.assertEqual(tm.derive_sector_label(tags={"amenity": "pharmacy"}, name="Apotheke"), "Pharmacy")
        self.assertEqual(tm.derive_sector_label(cat="restaurant", name="Gasthof"), "Restaurant / Inn")
        self.assertEqual(tm.derive_sector_label(cat="hotel", name="Hotel Post"), "Hotel")
        self.assertEqual(tm.derive_sector_label(tags={"shop": "hardware"}, name="Bauhaus"), "Workshop / Hardware")
        self.assertEqual(tm.derive_sector_label(tags={"amenity": "fuel"}, name="Shell"), "Fuel Station")
        self.assertEqual(tm.derive_sector_label(cat="train_station", name="Bahnhof"), "Train / Transit Station")
        self.assertEqual(tm.derive_sector_label(bld_class="warehouse", name="Hub"), "Logistics Depot")
        self.assertEqual(tm.derive_sector_label(kind="bus_stop", name="Stop 1"), "Bus Stop")
        self.assertEqual(tm.derive_sector_label(name="Main Street"), "")

    def test_resolve_locality_and_stop_enrichment(self):
        md = _seed_corridor_md(base_lat=47.713, base_lon=11.383)
        k = mapcells.cell_of(47.713, 11.383)
        md.put(k, "town_points", FakeFeatures([{
            "id": "tp_1",
            "attrs": {"name": "Penzberg", "subtype": "locality"},
            "parts": [[np.array([[11.383, 47.713]], np.float64)]],
        }]))
        md.put(k, "hoods", FakeFeatures([{
            "id": "hd_1",
            "attrs": {"name": "Dittenried", "subtype": "neighborhood"},
            "parts": [[np.array([[11.384, 47.714]], np.float64)]],
        }]))
        loc = tm._resolve_locality(md, 47.7135, 11.3835, deadline=1e12)
        self.assertEqual(loc, "Penzberg · Dittenried")

        # Single town without hood
        md2 = FakeMapData()
        md2.put(k, "town_points", FakeFeatures([{
            "id": "tp_2",
            "attrs": {"name": "Sindelsdorf", "subtype": "village"},
            "parts": [[np.array([[11.383, 47.713]], np.float64)]],
        }]))
        self.assertEqual(tm._resolve_locality(md2, 47.7135, 11.3835, deadline=1e12), "Sindelsdorf")

        # Graceful empty fallback when neither town_points, hoods, nor randomplace.towns() match
        with mock.patch.object(tm.randomplace, "towns", return_value=[]):
            self.assertEqual(tm._resolve_locality(FakeMapData(), 47.7135, 11.3835, deadline=1e12), "")

        # End-to-end taxi job carries locality and sectorLabel on stops
        res = tm.generate_job(md, None, mode="taxi", tier="short", lat=47.713, lon=11.383, heading=20.0, seed=1)
        self.assertTrue(res["ok"], res)
        self.assertTrue(any(s.get("locality") == "Penzberg · Dittenried" for s in res["stops"]))
        self.assertTrue(any(s.get("sectorLabel") for s in res["stops"]))


class Phase6ParcelCourierTest(unittest.TestCase):
    def _seed_parcel_md(self, base_lat=47.713, base_lon=11.383):
        md = FakeMapData()
        road_buckets = {}
        bld_buckets = {}
        addr_buckets = {}
        place_buckets = {}
        streets = ["Birkenweg", "Hauptstraße", "Lindenstraße", "Ahornweg", "Gartenstraße", "Mühlweg"]
        for i in range(16):
            dist_m = 120.0 + i * 160.0
            brg = 15.0 + (i % 4) * 20.0
            la, lo = tm.offset_latlon(base_lat, base_lon, dist_m, brg)
            la2, lo2 = tm.offset_latlon(la, lo, 180.0, 90.0)
            k = mapcells.cell_of(la, lo)
            st_name = streets[i % len(streets)]
            road_buckets.setdefault(k, []).append(
                _make_road(f"pr_{i}", la - 0.0004, lo - 0.0004, la2, lo2, cls="residential", name=st_name)
            )
            if i < 4:
                # Explicit real address points with housenumber + street + locality
                addr_buckets.setdefault(k, []).append({
                    "id": f"pa_{i}",
                    "attrs": {"housenumber": f"{12 + i * 2}", "street": st_name, "locality": "Sindelsdorf", "cx": lo + 0.0001, "cy": la + 0.0001},
                    "parts": [[np.array([[lo + 0.0001, la + 0.0001]], np.float64)]],
                })
            else:
                bld_buckets.setdefault(k, []).append({
                    "id": f"pb_{i}",
                    "attrs": {"name": "", "class": "house", "subtype": "residential", "cx": lo + 0.00012, "cy": la + 0.00012},
                    "parts": [[np.array([[lo + 0.0001, la + 0.0001], [lo + 0.0002, la + 0.0001], [lo + 0.0002, la + 0.0002]], np.float64)]],
                })
        # Add one small local practice POI
        p_lat, p_lon = tm.offset_latlon(base_lat, base_lon, 520.0, 45.0)
        pk = mapcells.cell_of(p_lat, p_lon)
        place_buckets.setdefault(pk, []).append(_make_place("pp_1", p_lat, p_lon, "Praxis Dr. König", cat="doctors"))
        for k, items in road_buckets.items():
            md.put(k, "roads", FakeFeatures(items))
        for k, items in bld_buckets.items():
            md.put(k, "buildings", FakeFeatures(items))
        for k, items in addr_buckets.items():
            md.put(k, "addresses", FakeFeatures(items))
        for k, items in place_buckets.items():
            md.put(k, "places", FakeFeatures(items))
        return md

    def test_parcel_validation_and_dwell(self):
        for tier in ("local", "city", "regional", "long"):
            req, err = tm.validate_request({"mode": "parcel", "tier": tier, "lat": 47.713, "lon": 11.383})
            self.assertIsNone(err)
            self.assertEqual(req["mode"], "parcel")
            self.assertEqual(req["tier"], tier)
        req, err = tm.validate_request({"mode": "parcel", "tier": "express", "lat": 47.713, "lon": 11.383})
        self.assertIsNone(req)
        self.assertIn("unknown tier", err)
        self.assertEqual(tm.compute_dwell_target_s("parcel", "local", "delivery"), 2.5)

    def test_parcel_generation_addresses_recipients_and_manifest(self):
        import test_protocol_agreement as proto
        md = self._seed_parcel_md()
        res = tm.generate_job(md, mode="parcel", tier="local", lat=47.713, lon=11.383, heading=25.0, seed=42)
        self.assertTrue(res["ok"], res.get("error"))
        self.assertEqual(res["mode"], "parcel")
        self.assertEqual(res["tier"], "local")
        stops = res["stops"]
        self.assertTrue(5 <= len(stops) <= 7, f"expected 5-7 local stops, got {len(stops)}")

        # Determinism check
        res2 = tm.generate_job(md, mode="parcel", tier="local", lat=47.713, lon=11.383, heading=25.0, seed=42)
        self.assertEqual(res, res2)

        # Protocol schema check
        result_schema = proto.SERVER_TO_MOD["transport_job_result"]
        for k in res:
            self.assertIn(k, result_schema, f"unexpected top-level key {k!r}")
        for s in stops:
            for k in s:
                self.assertIn(k, proto.TRANSPORT_STOP_FIELDS, f"unexpected stop key {k!r}")
            self.assertEqual(s["dwellTargetS"], 2.5)
            self.assertEqual(s["stopType"], "kerbside")
            self.assertTrue(s.get("recipient"), "stop missing recipient")
            self.assertIn(s.get("parcelAction"), ("deliver", "pickup_return"))
            self.assertTrue(1 <= s["parcelCount"] <= 3)
            # Name must look like '<Street> <HouseNumber>'
            self.assertTrue(any(ch.isdigit() for ch in s["name"]), f"expected house number in {s['name']!r}")
            if s["parcelAction"] == "deliver":
                self.assertTrue(-28 <= s["cargoDeltaKg"] <= -8, f"deliver delta out of range: {s['cargoDeltaKg']}")
            else:
                self.assertTrue(6 <= s["cargoDeltaKg"] <= 15, f"return delta out of range: {s['cargoDeltaKg']}")

        # Final stop must be a delivery and parcelsRemaining must step down monotonically to 0
        self.assertEqual(stops[-1]["parcelAction"], "deliver")
        self.assertEqual(stops[-1]["parcelsRemaining"], 0)
        deliver_sum = sum(s["parcelCount"] for s in stops if s["parcelAction"] == "deliver")
        self.assertEqual(res["parcel"]["parcelsTotal"], deliver_sum)
        prev_rem = deliver_sum
        for s in stops:
            self.assertLessEqual(s["parcelsRemaining"], prev_rem)
            self.assertEqual(s["parcelsTotal"], deliver_sum)
            prev_rem = s["parcelsRemaining"]

    def test_parcel_city_and_regional_tiers_and_return_pickups(self):
        md = self._seed_parcel_md()
        city_res = tm.generate_job(md, mode="parcel", tier="city", lat=47.713, lon=11.383, heading=25.0, seed=11)
        self.assertTrue(city_res["ok"], city_res.get("error"))
        self.assertTrue(8 <= len(city_res["stops"]) <= 12)

        # Across several seeds, occasional pickup_return stops appear
        saw_return = False
        for sd in range(1, 20):
            r = tm.generate_job(md, mode="parcel", tier="city", lat=47.713, lon=11.383, heading=25.0, seed=sd)
            if any(s.get("parcelAction") == "pickup_return" for s in r["stops"]):
                saw_return = True
                break
        self.assertTrue(saw_return, "expected at least one pickup_return stop across seeds")


class CachingAndPerformanceTest(unittest.TestCase):
    def test_cell_layer_request_cache_deduplicates_decodes(self):
        md = _seed_corridor_md()
        calls = {}
        orig_cell = md.cell

        def counting_cell(key, layers=("roads",), kind="demand"):
            for ly in layers:
                calls[(key, ly)] = calls.get((key, ly), 0) + 1
            return orig_cell(key, layers=layers, kind=kind)

        md.cell = counting_cell
        for mode, tier in (("logistics", "city"), ("parcel", "city")):
            calls.clear()
            res = tm.generate_job(md, mode=mode, tier=tier, lat=39.285, lon=-76.610, heading=20.0, seed=42)
            self.assertTrue(res["ok"], f"{mode}/{tier} failed: {res}")
            dups = {k: v for k, v in calls.items() if v > 1}
            self.assertEqual(dups, {}, f"{mode}/{tier} decoded cells multiple times: {dups}")

    def test_classifier_lru_caches_and_parity(self):
        tm._classify_poi_cargo_domain_cached.cache_clear()
        tm._derive_sector_label_cached.cache_clear()
        d1 = tm.classify_poi_cargo_domain(cat="supermarket", tags={"shop": "supermarket", "extra": "ignored"}, name="REWE")
        d2 = tm.classify_poi_cargo_domain(cat="supermarket", tags={"shop": "supermarket", "extra": "other"}, name="REWE")
        self.assertEqual(d1, "food")
        self.assertEqual(d2, "food")
        self.assertGreaterEqual(tm._classify_poi_cargo_domain_cached.cache_info().hits, 1)

        s1 = tm.derive_sector_label(cat="pharmacy", tags={"amenity": "pharmacy"}, name="Apotheke")
        s2 = tm.derive_sector_label(cat="pharmacy", tags={"amenity": "pharmacy"}, name="Apotheke")
        self.assertEqual(s1, "Pharmacy")
        self.assertEqual(s2, "Pharmacy")
        self.assertGreaterEqual(tm._derive_sector_label_cached.cache_info().hits, 1)

    def test_determinism_and_latency_across_all_modes(self):
        import time
        md = _seed_corridor_md()
        cases = (
            ("taxi", "city"),
            ("bus", "partial"),
            ("logistics", "city"),
            ("parcel", "city"),
        )
        for mode, tier in cases:
            t0 = time.monotonic()
            r1 = tm.generate_job(md, mode=mode, tier=tier, lat=39.285, lon=-76.610, heading=20.0, seed=17)
            r2 = tm.generate_job(md, mode=mode, tier=tier, lat=39.285, lon=-76.610, heading=20.0, seed=17)
            dt = time.monotonic() - t0
            self.assertTrue(r1["ok"], f"{mode}/{tier} failed: {r1}")
            self.assertEqual(r1["stops"], r2["stops"], f"{mode}/{tier} not deterministic")
            self.assertLess(dt, 0.5, f"{mode}/{tier} took too long: {dt:.3f}s")


class FuelStationsTest(unittest.TestCase):
    def test_validate_fuel_stations_request(self):
        req, err = tm.validate_fuel_stations_request({"lat": 48.1351, "lon": 11.5820, "radiusM": 1800})
        self.assertIsNone(err)
        self.assertAlmostEqual(req["lat"], 48.1351)
        self.assertAlmostEqual(req["lon"], 11.5820)
        self.assertEqual(req["radiusM"], 1800.0)

        # Clamps radiusM and defaults when absent
        req_def, err_def = tm.validate_fuel_stations_request({"lat": 48.1, "lon": 11.5})
        self.assertIsNone(err_def)
        self.assertEqual(req_def["radiusM"], 1500.0)

        for bad in ({"lat": 95, "lon": 0}, {"lat": "x", "lon": 0}, {}):
            r, e = tm.validate_fuel_stations_request(bad)
            self.assertIsNone(r)
            self.assertIsInstance(e, str)

    def test_extract_deduplicate_brand_snap_and_price(self):
        base_lat, base_lon = 48.1351, 11.5820
        md = FakeMapData()
        key = mapcells.cell_of(base_lat, base_lon)

        # Station A: Shell in places + unnamed amenity=fuel in infrastructure 15 m away -> deduplicated to 1 ("Shell")
        s1_lat, s1_lon = tm.offset_latlon(base_lat, base_lon, 220.0, 90.0)
        s1_dup_lat, s1_dup_lon = tm.offset_latlon(s1_lat, s1_lon, 15.0, 0.0)
        # Station B: Aral via brand_wikidata 650 m north
        s2_lat, s2_lon = tm.offset_latlon(base_lat, base_lon, 650.0, 0.0)
        # Station C: unnamed infra fuel 900 m south -> fallback "Local Fuel Station"
        s3_lat, s3_lon = tm.offset_latlon(base_lat, base_lon, 900.0, 180.0)
        # Station D: closed station -> excluded
        s4_lat, s4_lon = tm.offset_latlon(base_lat, base_lon, 150.0, 270.0)
        # Station E: beyond 1500 m radius -> excluded
        s5_lat, s5_lon = tm.offset_latlon(base_lat, base_lon, 1800.0, 45.0)

        places_items = [
            {
                "id": "pl_shell",
                "attrs": {"name": "Shell Station", "basic_category": "gas_station", "brand_name": "shell", "operating_status": "open", "cx": s1_lon, "cy": s1_lat},
                "parts": [[np.array([[s1_lon, s1_lat]], np.float64)]],
            },
            {
                "id": "pl_aral",
                "attrs": {"name": "", "basic_category": "fueling_station", "brand_wikidata": "Q565734", "operating_status": "open", "cx": s2_lon, "cy": s2_lat},
                "parts": [[np.array([[s2_lon, s2_lat]], np.float64)]],
            },
            {
                "id": "pl_closed",
                "attrs": {"name": "Esso Closed", "basic_category": "gas_station", "operating_status": "permanently_closed", "cx": s4_lon, "cy": s4_lat},
                "parts": [[np.array([[s4_lon, s4_lat]], np.float64)]],
            },
            {
                "id": "pl_far",
                "attrs": {"name": "OMV Far", "basic_category": "gas_station", "operating_status": "open", "cx": s5_lon, "cy": s5_lat},
                "parts": [[np.array([[s5_lon, s5_lat]], np.float64)]],
            },
        ]
        infra_items = [
            {
                "id": "in_shell_dup",
                "attrs": {"name": "", "class": "fuel", "tags": {"amenity": "fuel"}, "cx": s1_dup_lon, "cy": s1_dup_lat},
                "parts": [[np.array([[s1_dup_lon, s1_dup_lat]], np.float64)]],
            },
            {
                "id": "in_local",
                "attrs": {"name": "", "class": "fuel", "tags": {"amenity": "fuel"}, "cx": s3_lon, "cy": s3_lat},
                "parts": [[np.array([[s3_lon, s3_lat]], np.float64)]],
            },
        ]
        roads_items = [
            _make_road("rd_s1", s1_lat - 0.0004, s1_lon, s1_lat + 0.0004, s1_lon, cls="service", subclass="driveway", name="Shell Forecourt"),
            _make_road("rd_s2", s2_lat, s2_lon - 0.0005, s2_lat, s2_lon + 0.0005, cls="secondary", name="Leopoldstraße"),
            _make_road("rd_s3", s3_lat - 0.0005, s3_lon, s3_lat + 0.0005, s3_lon, cls="tertiary", name="Ringstraße"),
        ]
        # Place into respective cells
        for layer, items in (("places", places_items), ("infrastructure", infra_items), ("roads", roads_items)):
            buckets = {}
            for it in items:
                if "cx" in it["attrs"]:
                    ck = mapcells.cell_of(it["attrs"]["cy"], it["attrs"]["cx"])
                else:
                    p0 = it["parts"][0][0][0]
                    ck = mapcells.cell_of(float(p0[1]), float(p0[0]))
                buckets.setdefault(ck, []).append(it)
            for ck, b_items in buckets.items():
                md.put(ck, layer, FakeFeatures(b_items))

        st1 = tm.find_nearby_fuel_stations(md, base_lat, base_lon, radius_m=1500.0)
        st2 = tm.find_nearby_fuel_stations(md, base_lat, base_lon, radius_m=1500.0)
        self.assertEqual(st1, st2, "fuel station query must be deterministic")
        self.assertEqual(len(st1), 3, f"expected 3 deduplicated open stations in radius, got {st1}")

        # Sorted by distM ascending: Shell (~220m), Aral (~650m), Local Fuel Station (~900m)
        self.assertEqual(st1[0]["brand"], "Shell")
        self.assertIn("Shell", st1[0]["name"])
        self.assertEqual(st1[1]["brand"], "Aral")
        self.assertEqual(st1[1]["name"], "Aral")
        self.assertEqual(st1[2]["name"], "Local Fuel Station")

        for s in st1:
            self.assertGreaterEqual(s["pricePerLiter"], 1.72)
            self.assertLessEqual(s["pricePerLiter"], 1.89)
            self.assertTrue(0.0 <= s["bearingDeg"] < 360.0)
            self.assertIsInstance(s["id"], str)
            self.assertIsInstance(s["locality"], str)


class CargoSensitivityTest(unittest.TestCase):
    def test_distribution_and_tier_gating(self):
        # local tier, taxi, and bus always return standard (0.0)
        for m, t in (("logistics", "local"), ("parcel", "local"), ("taxi", "city"), ("bus", "full")):
            for seed in range(25):
                s = tm.assign_cargo_sensitivity(m, t, "general", "pallets", seed)
                self.assertEqual(s["cargoSensitivity"], "standard")
                self.assertEqual(s["hazardBonusMult"], 0.0)
                self.assertEqual(s["sensitivityLabel"], "")

        # city/regional/long on logistics hit ~35% fragile and ~20% hazmat
        counts = {"standard": 0, "fragile": 0, "hazmat": 0}
        for seed in range(200):
            s = tm.assign_cargo_sensitivity("logistics", "city", "industrial", "machinery", seed)
            counts[s["cargoSensitivity"]] += 1
            if s["cargoSensitivity"] == "fragile":
                self.assertEqual(s["hazardBonusMult"], 0.35)
                self.assertEqual(s["sensitivityLabel"], "Zerbrechlich · Sanft fahren (+35% Bonus)")
            elif s["cargoSensitivity"] == "hazmat":
                self.assertEqual(s["hazardBonusMult"], 0.50)
                self.assertEqual(s["sensitivityLabel"], "Gefahrgut · Vorsichtig fahren (+50% Bonus)")
            else:
                self.assertEqual(s["hazardBonusMult"], 0.0)
                self.assertEqual(s["sensitivityLabel"], "")

        self.assertGreaterEqual(counts["fragile"], 50)
        self.assertLessEqual(counts["fragile"], 90)
        self.assertGreaterEqual(counts["hazmat"], 25)
        self.assertLessEqual(counts["hazmat"], 55)

        # parcel deliveries never spawn hazmat, but still spawn fragile (~35%)
        p_counts = {"standard": 0, "fragile": 0, "hazmat": 0}
        for seed in range(200):
            s = tm.assign_cargo_sensitivity("parcel", "city", "retail", "parcels", seed)
            p_counts[s["cargoSensitivity"]] += 1
            self.assertNotEqual(s["cargoSensitivity"], "hazmat")
            if s["cargoSensitivity"] == "fragile":
                self.assertEqual(s["hazardBonusMult"], 0.35)
                self.assertEqual(s["sensitivityLabel"], "Zerbrechlich · Sanft fahren (+35% Bonus)")
            else:
                self.assertEqual(s["hazardBonusMult"], 0.0)
                self.assertEqual(s["sensitivityLabel"], "")

        self.assertEqual(p_counts["hazmat"], 0)
        self.assertGreaterEqual(p_counts["fragile"], 50)
        self.assertLessEqual(p_counts["fragile"], 90)


if __name__ == "__main__":
    unittest.main()
