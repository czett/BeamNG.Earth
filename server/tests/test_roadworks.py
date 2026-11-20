"""Unit tests for Loop 7 Part A: Dynamic DE Roadworks (`server/de_street_enhancer/roadworks.py`)."""

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
import roads  # noqa: E402
from de_street_enhancer import roadworks  # noqa: E402


DORTMUND = (51.5136, 7.4653)
PARIS = (48.8566, 2.3522)
SALZBURG = (47.8095, 13.0550)


def setUpModule():
    borderfixtures.require()


def _flat_ground(x, y):
    return np.zeros(len(x), dtype=np.float64)


def _road_spec(cls="primary", width=7.5, urban=True, kmh=50.0):
    return roads.Spec(
        width=width,
        kind="paved",
        urban=urban,
        cls=cls,
        oneway=False,
        walk=urban,
        dir=0,
        kmh=kmh,
    )


class DynamicRoadworksTest(unittest.TestCase):
    def _make_infra_roadworks(self, frame, pts_tags):
        lonlat = np.array([frame.enu_to_geodetic(x, y, 0.0)[1::-1] for x, y, _ in pts_tags], dtype=np.float64)
        n = len(pts_tags)
        return mapgeom.Features(
            layer="infrastructure",
            ids=np.array([f"osm_rw_{i}" for i in range(n)], dtype=object),
            kind=np.full(n, mapgeom.POINT, np.uint8),
            part_off=np.arange(n + 1, dtype=np.int64),
            ring_off=np.arange(n + 1, dtype=np.int64),
            coord_off=np.arange(n + 1, dtype=np.int64),
            lonlat=lonlat,
            attrs={
                "class": np.array(["construction"] * n, dtype=object),
                "tags": np.array([json.dumps(t) for _, _, t in pts_tags], dtype=object),
            },
            rules={},
        )

    def test_package_version_and_off_switch_and_border_isolation(self):
        self.assertEqual(de_enhancer.PACKAGE_VERSION, 4)
        frame_de = geodesy.EnuFrame(*DORTMUND)
        frame_fr = geodesy.EnuFrame(*PARIS)
        frame_at = geodesy.EnuFrame(*SALZBURG)
        box = (0.0, 0.0, 256.0, 256.0)
        road_pts = np.array([[10.0, 120.0, 0.0], [240.0, 120.0, 0.0]], dtype=np.float64)
        near_roads = [("r_main", _road_spec("primary", 8.0, True, 50.0), road_pts, DORTMUND[1])]

        feats_de = self._make_infra_roadworks(frame_de, [(120.0, 121.0, {"highway": "construction"})])
        fake_md = types.SimpleNamespace(
            cell=lambda key, layers=(), kind="demand": types.SimpleNamespace(
                layers={"infrastructure": feats_de if "infrastructure" in layers else None}
            )
        )
        with mock.patch.dict(os.environ, {"BNE_DE_STREET_IMMERSION": "off"}):
            self.assertEqual(de_enhancer.build_roadworks(fake_md, frame_de, 0, 0, box, near_roads, [], _flat_ground), ([], []))

        with mock.patch.dict(os.environ, {"BNE_DE_STREET_IMMERSION": "on"}):
            for fr in (frame_fr, frame_at):
                self.assertEqual(de_enhancer.build_roadworks(fake_md, fr, 0, 0, box, near_roads, [], _flat_ground), ([], []))

    def test_osm_roadworks_props_clearance_and_tile_serialization(self):
        frame = geodesy.EnuFrame(*DORTMUND)
        box = (0.0, 0.0, 256.0, 256.0)
        road_pts = np.array([[10.0, 120.0, 0.0], [240.0, 120.0, 0.0]], dtype=np.float64)
        width = 7.2
        near_roads = [("r_main", _road_spec("primary", width, True, 50.0), road_pts, DORTMUND[1])]
        feats = self._make_infra_roadworks(frame, [(125.0, 120.5, {"highway": "construction", "roadworks": "yes"})])
        fake_md = types.SimpleNamespace(
            cell=lambda key, layers=(), kind="demand": types.SimpleNamespace(
                layers={"infrastructure": feats if "infrastructure" in layers else None}
            )
        )

        with mock.patch.dict(os.environ, {"BNE_DE_STREET_IMMERSION": "on"}):
            props, rw_rows = de_enhancer.build_roadworks(fake_md, frame, 0, 0, box, near_roads, [], _flat_ground, de_detail="medium")

        self.assertEqual(len(rw_rows), 1)
        row = rw_rows[0]
        self.assertEqual(len(row), 7)
        self.assertIn(row[6], (30.0, 50.0))

        groups = [p[0] for p in props]
        self.assertIn("de_barrier", groups)
        self.assertIn("de_sign_123", groups)
        self.assertTrue("de_sign_274_30" in groups or "de_sign_274_50" in groups)

        # Verify >= 3.4 m clear drivable carriageway width past barrier inner edge
        barriers = [p for p in props if p[0] == "de_barrier"]
        self.assertGreaterEqual(len(barriers), 4)
        for b in barriers:
            # Road centerline is y=120, right edge is y=120 - width/2 = 116.4
            dist_from_opposite_kerb = abs(b[2] - (120.0 + width * 0.5))
            self.assertGreaterEqual(dist_from_opposite_kerb, roadworks.MIN_CLEAR_WIDTH_M)

        with tempfile.TemporaryDirectory() as tmp:
            path, _ = roads.write_tile(tmp, "/world", 1, 0, 0, [], props=props, de_roadworks=rw_rows)
            tile = json.loads((Path(tmp) / Path(path).name).read_text(encoding="utf-8"))
            self.assertEqual(tile["deRoadworks"], rw_rows)
            self.assertIn("de_barrier", tile["props"]["groups"])

    def test_procedural_rate_and_narrow_or_short_roads_skipped(self):
        frame = geodesy.EnuFrame(*DORTMUND)
        box = (0.0, 0.0, 256.0, 256.0)
        road_pts = np.array([[10.0, 120.0, 0.0], [230.0, 120.0, 0.0]], dtype=np.float64)
        near_roads = [("r_elig", _road_spec("secondary", 7.0, False, 100.0), road_pts, DORTMUND[1])]

        hits = 0
        with mock.patch.dict(os.environ, {"BNE_DE_STREET_IMMERSION": "on"}):
            for tx in range(10):
                for ty in range(20):
                    p, rw = de_enhancer.build_roadworks(None, frame, tx, ty, box, near_roads, [], _flat_ground, de_detail="medium")
                    if rw:
                        self.assertEqual(len(rw), 1)
                        self.assertGreaterEqual(len(p), 4)
                        hits += 1
        # Expect ~13.5% over 200 tiles -> roughly 15..42 hits
        self.assertGreaterEqual(hits, 14)
        self.assertLessEqual(hits, 44)

        # Narrow (< 5.0 m) or short (< 90 m) or residential roads must never spawn procedural roadworks
        short_pts = np.array([[20.0, 120.0, 0.0], [85.0, 120.0, 0.0]], dtype=np.float64)
        bad_roads = [
            ("r_short", _road_spec("primary", 7.5, True, 50.0), short_pts, DORTMUND[1]),
            ("r_narrow", _road_spec("tertiary", 4.2, True, 30.0), road_pts, DORTMUND[1]),
            ("r_res", _road_spec("residential", 7.0, True, 30.0), road_pts, DORTMUND[1]),
        ]
        with mock.patch.dict(os.environ, {"BNE_DE_STREET_IMMERSION": "on"}):
            for tx in range(30):
                p, rw = de_enhancer.build_roadworks(None, frame, tx, 0, box, bad_roads, [], _flat_ground)
                self.assertEqual((p, rw), ([], []))


if __name__ == "__main__":
    unittest.main()
