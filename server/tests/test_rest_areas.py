"""Unit tests for German Autobahn Rest Areas & Parking Areas (`server/de_street_enhancer/rest_areas.py`)."""

import json
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
from de_street_enhancer import classifier  # noqa: E402
from de_street_enhancer import furniture_de  # noqa: E402
from de_street_enhancer import rest_areas  # noqa: E402


DORTMUND = (51.5136, 7.4653)
PARIS = (48.8566, 2.3522)
SALZBURG = (47.8095, 13.0550)


def setUpModule():
    borderfixtures.require()


def _flat_ground(x, y):
    return np.zeros(len(x), dtype=np.float64)


def _road_spec(cls="motorway", width=11.0, urban=False, kmh=130.0):
    return roads.Spec(
        width=width,
        kind="paved",
        urban=urban,
        cls=cls,
        oneway=cls in ("motorway", "motorway_link"),
        walk=False,
        dir=1 if cls in ("motorway", "motorway_link") else 0,
        kmh=kmh,
    )


def _make_point_features(frame, items, layer="infrastructure"):
    """Build point `mapgeom.Features` from `[(x, y, cls_str, tags_dict), ...]`."""
    lonlat = np.array([frame.enu_to_geodetic(x, y, 0.0)[1::-1] for x, y, _, _ in items], dtype=np.float64)
    n = len(items)
    return mapgeom.Features(
        layer=layer,
        ids=np.array([f"ra_{layer}_{i}" for i in range(n)], dtype=object),
        kind=np.full(n, mapgeom.POINT, np.uint8),
        part_off=np.arange(n + 1, dtype=np.int64),
        ring_off=np.arange(n + 1, dtype=np.int64),
        coord_off=np.arange(n + 1, dtype=np.int64),
        lonlat=lonlat,
        attrs={
            "class": np.array([c for _, _, c, _ in items], dtype=object),
            "tags": np.array([json.dumps(t) for _, _, _, t in items], dtype=object),
        },
        rules={},
    )


def _make_polygon_feature(frame, ring_xy, cls_str, tags_dict, layer="land_use"):
    """Build a single polygon `mapgeom.Features` from ENU ring coordinates."""
    lonlat = np.array([frame.enu_to_geodetic(x, y, 0.0)[1::-1] for x, y in ring_xy], dtype=np.float64)
    n_pts = len(ring_xy)
    return mapgeom.Features(
        layer=layer,
        ids=np.array([f"ra_poly_{layer}_0"], dtype=object),
        kind=np.array([mapgeom.POLYGON], np.uint8),
        part_off=np.array([0, 1], dtype=np.int64),
        ring_off=np.array([0, 1], dtype=np.int64),
        coord_off=np.array([0, n_pts], dtype=np.int64),
        lonlat=lonlat,
        attrs={
            "class": np.array([cls_str], dtype=object),
            "tags": np.array([json.dumps(tags_dict)], dtype=object),
        },
        rules={},
    )


def _fake_md(infra=None, land_use=None):
    return types.SimpleNamespace(
        cell=lambda key, layers=(), kind="demand": types.SimpleNamespace(
            layers={
                "infrastructure": infra if "infrastructure" in layers else None,
                "land_use": land_use if "land_use" in layers else None,
            }
        )
    )


class RestAreasTest(unittest.TestCase):
    def test_package_version_off_switch_and_border_isolation(self):
        self.assertEqual(de_enhancer.PACKAGE_VERSION, 5)
        frame_de = geodesy.EnuFrame(*DORTMUND)
        frame_fr = geodesy.EnuFrame(*PARIS)
        frame_at = geodesy.EnuFrame(*SALZBURG)
        box = (0.0, 0.0, 256.0, 256.0)
        road_pts = np.array([[10.0, 100.0, 0.0], [240.0, 100.0, 0.0]], dtype=np.float64)
        near_roads = [("m_a40", _road_spec("motorway", 11.0), road_pts, DORTMUND[1])]

        feats_de = _make_point_features(frame_de, [(120.0, 124.0, "services", {"highway": "services"})])
        md_de = _fake_md(infra=feats_de)

        # Off-switch parity: strictly empty when disabled.
        with mock.patch.dict(os.environ, {"BNE_DE_STREET_IMMERSION": "off"}):
            self.assertEqual(de_enhancer.build_rest_areas(md_de, frame_de, 0, 0, box, near_roads, [], _flat_ground), [])

        # Border isolation: strictly empty outside Germany (France & Austria).
        with mock.patch.dict(os.environ, {"BNE_DE_STREET_IMMERSION": "on"}):
            for fr in (frame_fr, frame_at):
                feats_out = _make_point_features(fr, [(120.0, 124.0, "services", {"highway": "services"})])
                self.assertEqual(
                    de_enhancer.build_rest_areas(_fake_md(infra=feats_out), fr, 0, 0, box, near_roads, [], _flat_ground),
                    [],
                )

    def test_highway_services_and_rest_area_detection_and_clearance(self):
        frame = geodesy.EnuFrame(*DORTMUND)
        box = (0.0, 0.0, 256.0, 256.0)
        road_pts = np.array([[10.0, 100.0, 0.0], [240.0, 100.0, 0.0]], dtype=np.float64)
        # Also add an internal rest-area slip road to verify clearance against ALL carriageways.
        slip_pts = np.array([[70.0, 114.0, 0.0], [180.0, 114.0, 0.0]], dtype=np.float64)
        near_roads = [
            ("m_a40", _road_spec("motorway", 11.0), road_pts, DORTMUND[1]),
            ("s_slip", _road_spec("service", 5.0), slip_pts, DORTMUND[1]),
        ]
        all_bands = furniture_de._all_road_bands(near_roads)

        # Building footprint near the rest area to verify zero props fall inside buildings.
        bld_ring = np.array(
            [[116.0, 126.0], [126.0, 126.0], [126.0, 136.0], [116.0, 136.0]],
            dtype=np.float64,
        )

        # Place `highway=services` polygon and `highway=rest_area` point (intentionally right on the slip road!).
        poly_ring = np.array(
            [[105.0, 122.0], [140.0, 122.0], [140.0, 148.0], [105.0, 148.0], [105.0, 122.0]],
            dtype=np.float64,
        )
        lu_feats = _make_polygon_feature(frame, poly_ring, "services", {"highway": "services"}, layer="land_use")
        inf_feats = _make_point_features(frame, [(200.0, 114.0, "rest_area", {"highway": "rest_area"})])
        md = _fake_md(infra=inf_feats, land_use=lu_feats)

        with mock.patch.dict(os.environ, {"BNE_DE_STREET_IMMERSION": "on"}):
            props = de_enhancer.build_rest_areas(md, frame, 0, 0, box, near_roads, [bld_ring], _flat_ground, de_detail="medium")

        self.assertGreaterEqual(len(props), 6)
        groups = {p[0] for p in props}
        self.assertTrue(groups.issubset(rest_areas.REST_AREA_PROP_GROUPS))
        self.assertIn("picnictable", groups)
        self.assertIn("bin", groups)
        self.assertIn("eu_lamp_steel", groups)
        self.assertIn("de_sign_274_30", groups)

        # Every emitted prop must have >= 0.65 m clearance from ALL carriageways and stay outside buildings.
        for row in props:
            self.assertEqual(len(row), 8)
            pt = np.array([float(row[1]), float(row[2])], dtype=np.float64)
            self.assertGreaterEqual(furniture_de._min_road_edge_dist(pt, all_bands), rest_areas.ROAD_CLEAR_M)
            self.assertFalse(classifier._point_in_ring(pt, bld_ring))

        # Verify tile serialization emits valid prop groups.
        with tempfile.TemporaryDirectory() as tmp:
            path, _ = roads.write_tile(tmp, "/world", 1, 0, 0, [], props=props)
            tile = json.loads((Path(tmp) / Path(path).name).read_text(encoding="utf-8"))
            self.assertTrue(set(tile["props"]["groups"]).issubset(rest_areas.REST_AREA_PROP_GROUPS))
            self.assertIn("picnictable", tile["props"]["groups"])

    def test_parking_motorway_adjacency_filter(self):
        frame = geodesy.EnuFrame(*DORTMUND)
        box = (0.0, 0.0, 256.0, 256.0)
        road_pts = np.array([[10.0, 100.0, 0.0], [240.0, 100.0, 0.0]], dtype=np.float64)

        # Generic `amenity=parking` next to a residential street must NOT trigger Autobahn rest-area props.
        res_roads = [("r_res", _road_spec("residential", 6.5, urban=True, kmh=30.0), road_pts, DORTMUND[1])]
        park_feats = _make_point_features(frame, [(120.0, 120.0, "parking", {"amenity": "parking"})])
        with mock.patch.dict(os.environ, {"BNE_DE_STREET_IMMERSION": "on"}):
            self.assertEqual(
                de_enhancer.build_rest_areas(_fake_md(infra=park_feats), frame, 0, 0, box, res_roads, [], _flat_ground),
                [],
            )

        # Same `amenity=parking` adjacent to a `motorway` DOES trigger rest-area props.
        mw_roads = [("m_a2", _road_spec("motorway", 11.0), road_pts, DORTMUND[1])]
        with mock.patch.dict(os.environ, {"BNE_DE_STREET_IMMERSION": "on"}):
            props = de_enhancer.build_rest_areas(_fake_md(infra=park_feats), frame, 0, 0, box, mw_roads, [], _flat_ground)
        self.assertGreaterEqual(len(props), 3)

        # Explicit `parking=rest_area` also triggers rest-area props.
        ra_park = _make_point_features(frame, [(120.0, 120.0, "parking", {"amenity": "parking", "parking": "rest_area"})])
        with mock.patch.dict(os.environ, {"BNE_DE_STREET_IMMERSION": "on"}):
            props_ra = de_enhancer.build_rest_areas(_fake_md(infra=ra_park), frame, 0, 0, box, mw_roads, [], _flat_ground)
        self.assertGreaterEqual(len(props_ra), 3)

    def test_all_emitted_groups_registered_in_trees_lua(self):
        root = Path(__file__).resolve().parents[2]
        lua_dir = root / "mod" / "beamng_earth" / "lua" / "ge" / "extensions" / "beamngEarth"
        lua_blob = "\n".join(
            (lua_dir / name).read_text(encoding="utf-8")
            for name in ("trees.lua", "europeAssets.lua", "vienna_convention_speed_signs.lua")
        )
        for group in rest_areas.REST_AREA_PROP_GROUPS:
            self.assertIn(group, lua_blob, f"Forest group {group!r} missing from Lua catalog")


if __name__ == "__main__":
    unittest.main()
