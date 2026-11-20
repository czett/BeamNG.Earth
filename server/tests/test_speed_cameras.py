"""Unit tests for Loop 5: DE speed-limit polish, urban-chain propagation, and OSM/mobile speed cameras."""

import json
import math
import os
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

import numpy as np

os.environ.setdefault(
    "BNE_REGIONAL_DIR",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures", "regional"),
)
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import borderfixtures  # noqa: E402
import de_enhancer  # noqa: E402
import geodesy  # noqa: E402
import mapgeom  # noqa: E402
import navgraph  # noqa: E402
import roads  # noqa: E402
from de_street_enhancer import furniture_de, speed_cameras, speed_limits  # noqa: E402


DORTMUND = (51.5136, 7.4653)
PARIS = (48.8566, 2.3522)
SALZBURG = (47.8095, 13.0550)


def setUpModule():
    borderfixtures.require()


def _flat_ground(x, y):
    return np.zeros(len(x), dtype=np.float64)


def _road_spec(cls="primary", width=7.5, urban=True, kmh=None, oneway=False, direction=0):
    return roads.Spec(width=width, kind="paved", urban=urban, cls=cls, oneway=oneway, walk=urban, dir=direction, kmh=kmh)


def _make_road_features(frame, segments, names=None, classes=None, osm_ms=None, connectors=None):
    """Build synthetic `roads` mapgeom.Features from ENU polylines."""
    coords, coff, roff, poff = [], [0], [0], [0]
    for pts in segments:
        arr = np.asarray(pts, dtype=np.float64)
        la, lo, _ = frame.enu_to_geodetic(arr[:, 0], arr[:, 1], 0.0)
        ll = np.column_stack([lo, la])
        coords.append(ll)
        coff.append(coff[-1] + len(ll))
        roff.append(len(coff) - 1)
        poff.append(len(roff) - 1)
    n = len(segments)
    f = mapgeom.Features(
        layer="roads",
        ids=np.array([f"seg_{i}" for i in range(n)], dtype=object),
        kind=np.full(n, mapgeom.LINE, np.uint8),
        part_off=np.array(poff, np.int64),
        ring_off=np.array(roff, np.int64),
        coord_off=np.array(coff, np.int64),
        lonlat=np.vstack(coords),
        attrs={
            "class": np.array(classes or ["primary"] * n, dtype=object),
            "subtype": np.array(["road"] * n, dtype=object),
            "name": np.array(names or ["Hellweg"] * n, dtype=object),
        },
        rules={},
    )
    if osm_ms is not None:
        f.attrs["osm_maxspeed"] = np.array(osm_ms, dtype=object)
    if connectors is not None:
        f.rules["connectors"] = mapgeom.rule_table(connectors, "text")
    return f


class SpeedLimitNormalizationTest(unittest.TestCase):
    def test_explicit_osm_tokens_and_units(self):
        self.assertEqual(speed_limits.parse_maxspeed_kph("DE:urban"), 50.0)
        self.assertEqual(speed_limits.parse_maxspeed_kph("de:rural"), 100.0)
        self.assertEqual(speed_limits.parse_maxspeed_kph("DE:motorway"), 0.0)
        self.assertEqual(speed_limits.parse_maxspeed_kph("none", country="DE", cls="motorway"), 0.0)
        self.assertEqual(speed_limits.parse_maxspeed_kph("DE:living_street"), 10.0)
        self.assertEqual(speed_limits.parse_maxspeed_kph("walk"), 10.0)
        self.assertEqual(speed_limits.parse_maxspeed_kph("DE:zone30"), 30.0)
        self.assertEqual(speed_limits.parse_maxspeed_kph("DE:20"), 20.0)
        self.assertEqual(speed_limits.parse_maxspeed_kph("50"), 50.0)
        self.assertEqual(speed_limits.parse_maxspeed_kph("70 km/h"), 70.0)
        self.assertAlmostEqual(speed_limits.parse_maxspeed_kph("30 mph"), 48.3, places=1)
        self.assertIsNone(speed_limits.parse_maxspeed_kph("signals"))
        self.assertIsNone(speed_limits.parse_maxspeed_kph("garbage"))
        self.assertIsNone(speed_limits.parse_maxspeed_kph(None))

    def test_urban_chain_propagation_prevents_50_to_100_flicker(self):
        frame = geodesy.EnuFrame(*DORTMUND)
        # 3 connected segments of "Hellweg": [0..100] tagged 50, [100..220] untagged short gap, [220..340] tagged 50
        segs = [
            [[0.0, 0.0], [100.0, 0.0]],
            [[100.0, 0.0], [220.0, 0.0]],
            [[220.0, 0.0], [340.0, 0.0]],
            # Long rural highway segment (> 250 m) must NOT get pulled down to 50
            [[0.0, 100.0], [450.0, 100.0]],
        ]
        cons = [
            (0, "c0", [0.0, 0.0]), (0, "c1", [1.0, 1.0]),
            (1, "c1", [0.0, 0.0]), (1, "c2", [1.0, 1.0]),
            (2, "c2", [0.0, 0.0]), (2, "c3", [1.0, 1.0]),
        ]
        feats = _make_road_features(
            frame,
            segs,
            names=["Hellweg", "Hellweg", "Hellweg", "B1"],
            classes=["primary", "primary", "primary", "primary"],
            osm_ms=["DE:urban", None, "50", None],
            connectors=cons,
        )
        specs = [
            _road_spec("primary", urban=True, kmh=50.0),
            _road_spec("primary", urban=False, kmh=None),  # untagged gap where landcover flicked rural
            _road_spec("primary", urban=True, kmh=50.0),
            _road_spec("primary", urban=False, kmh=None),  # long rural highway
        ]
        prop = speed_limits.propagate_urban_limits(feats, specs, country="DE")
        self.assertEqual(prop.get(1), 50.0, "short untagged gap between 50 km/h urban segments must inherit 50")
        self.assertNotIn(3, prop, "isolated long rural road stays untagged -> 100 km/h rural default")
        self.assertEqual(speed_limits.resolve_feature_limit_kph(feats, 1, specs[1], country="DE", propagated=prop), 50.0)
        self.assertEqual(speed_limits.resolve_feature_limit_kph(feats, 3, specs[3], country="DE", propagated=prop), 100.0)

    def test_navgraph_road_mph_respects_de_tokens_and_off_switch(self):
        frame = geodesy.EnuFrame(*DORTMUND)
        feats = _make_road_features(
            frame,
            [[[0.0, 0.0], [100.0, 0.0]], [[0.0, 50.0], [100.0, 50.0]]],
            classes=["primary", "motorway"],
            osm_ms=["DE:urban", "DE:motorway"],
        )
        sp_urb = _road_spec("primary", urban=True, kmh=None)
        sp_mw = _road_spec("motorway", urban=False, kmh=None)
        with mock.patch.dict(os.environ, {"BNE_DE_STREET_IMMERSION": "on"}):
            self.assertAlmostEqual(navgraph.road_mph(feats, 0, sp_urb, mph=False, country="DE") * 1.609344, 50.0, places=1)
            self.assertAlmostEqual(navgraph.road_mph(feats, 1, sp_mw, mph=False, country="DE") * 1.609344, 130.0, places=1)
        # Off-switch parity: untouched stock behavior
        with mock.patch.dict(os.environ, {"BNE_DE_STREET_IMMERSION": "off"}):
            self.assertAlmostEqual(navgraph.road_mph(feats, 1, sp_mw, mph=False, country="DE") * 1.609344, 120.0, places=1)


class SpeedCameraExtractionAndPlacementTest(unittest.TestCase):
    def _make_infra_cameras(self, frame, pts_tags):
        lonlat = np.array([frame.enu_to_geodetic(x, y, 0.0)[1::-1] for x, y, _ in pts_tags], dtype=np.float64)
        n = len(pts_tags)
        return mapgeom.Features(
            layer="infrastructure",
            ids=np.array([f"osm_cam_{i}" for i in range(n)], dtype=object),
            kind=np.full(n, mapgeom.POINT, np.uint8),
            part_off=np.arange(n + 1, dtype=np.int64),
            ring_off=np.arange(n + 1, dtype=np.int64),
            coord_off=np.arange(n + 1, dtype=np.int64),
            lonlat=lonlat,
            attrs={
                "class": np.array(["speed_camera"] * n, dtype=object),
                "tags": np.array([json.dumps(t) for _, _, t in pts_tags], dtype=object),
            },
            rules={},
        )

    def test_osm_speed_camera_clearance_bearing_and_tile_serialization(self):
        frame = geodesy.EnuFrame(*DORTMUND)
        box = (0.0, 0.0, 256.0, 256.0)
        road_pts = np.array([[10.0, 120.0, 0.0], [240.0, 120.0, 0.0]], dtype=np.float64)
        sp = _road_spec("primary", width=8.0, urban=True, kmh=50.0)
        near_roads = [("r_main", sp, road_pts, DORTMUND[1])]

        # Place OSM node right on the road carriageway (100, 121) -> must be pushed cleanly outside >= 0.65 m
        feats = self._make_infra_cameras(
            frame,
            [(100.0, 121.0, {"highway": "speed_camera", "maxspeed": "DE:urban"})],
        )
        fake_md = types.SimpleNamespace(
            cell=lambda key, layers=(), kind="demand": types.SimpleNamespace(
                layers={"infrastructure": feats if "infrastructure" in layers else None}
            )
        )
        with mock.patch.dict(os.environ, {"BNE_DE_STREET_IMMERSION": "on"}):
            props, cams = de_enhancer.build_speed_cameras(
                fake_md, frame, 0, 0, box, near_roads, [], _flat_ground, de_detail="medium"
            )
        self.assertEqual(len(props), 1)
        self.assertEqual(len(cams), 1)
        self.assertEqual(props[0][0], "de_radar")
        # Verify strict >= 0.65 m clearance from the 8 m carriageway (half-width = 4.0 m -> |y - 120| >= 4.65 m)
        bands = furniture_de._all_road_bands(near_roads)
        cam_xy = np.array([props[0][1], props[0][2]], dtype=np.float64)
        self.assertGreaterEqual(furniture_de._min_road_edge_dist(cam_xy, bands), speed_cameras.CARRIAGEWAY_CLEAR_M)
        # Verify gate row schema: [id, gx, gy, gz, yaw, half, limit, cx, cy, cz, urban, kind]
        gate = cams[0]
        self.assertEqual(len(gate), 12)
        self.assertEqual(gate[6], 50.0)
        self.assertEqual(gate[10], 1)
        self.assertEqual(gate[11], 0)

        # Verify write_tile serializes deSpeedCameras cleanly
        with tempfile.TemporaryDirectory() as tmp:
            path, _ = roads.write_tile(tmp, "/world", 1, 0, 0, [], props=props, de_speed_cameras=cams)
            tile = json.loads((Path(tmp) / Path(path).name).read_text(encoding="utf-8"))
            self.assertEqual(tile["deSpeedCameras"], cams)
            self.assertIn("de_radar", tile["props"]["groups"])

    def test_off_switch_and_border_isolation(self):
        frame_de = geodesy.EnuFrame(*DORTMUND)
        frame_fr = geodesy.EnuFrame(*PARIS)
        frame_at = geodesy.EnuFrame(*SALZBURG)
        box = (0.0, 0.0, 256.0, 256.0)
        road_pts = np.array([[10.0, 120.0, 0.0], [240.0, 120.0, 0.0]], dtype=np.float64)
        near_roads = [("r_main", _road_spec("primary", 8.0, True, 50.0), road_pts, DORTMUND[1])]

        feats_de = self._make_infra_cameras(frame_de, [(100.0, 121.0, {"highway": "speed_camera", "maxspeed": "50"})])
        fake_md = types.SimpleNamespace(
            cell=lambda key, layers=(), kind="demand": types.SimpleNamespace(
                layers={"infrastructure": feats_de if "infrastructure" in layers else None}
            )
        )
        # Off-switch parity in Germany
        with mock.patch.dict(os.environ, {"BNE_DE_STREET_IMMERSION": "off"}):
            p_off, c_off = de_enhancer.build_speed_cameras(fake_md, frame_de, 0, 0, box, near_roads, [], _flat_ground)
            self.assertEqual((p_off, c_off), ([], []))

        # Enabled outside Germany (Paris & Salzburg) -> zero cameras
        with mock.patch.dict(os.environ, {"BNE_DE_STREET_IMMERSION": "on"}):
            for fr in (frame_fr, frame_at):
                p_out, c_out = de_enhancer.build_speed_cameras(fake_md, fr, 0, 0, box, near_roads, [], _flat_ground)
                self.assertEqual((p_out, c_out), ([], []))


if __name__ == "__main__":
    unittest.main()
