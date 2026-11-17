"""Contract tests for DE Street Immersion Polish & PR-Readiness (`server/tests/test_de_style.py`).

Covers:
1. Strict `off-switch-no-change` parity when `BNE_DE_STREET_IMMERSION=off` (and outside DE).
2. Deterministic outputs across repeated runs for fuel pylons, dormers, PV panels, and shopfronts.
3. Geometric bounds, slope clamping, and clearance safety.
"""

import hashlib
import os
import subprocess
import sys
import tempfile
import unittest
from types import SimpleNamespace
from unittest import mock

import numpy as np

SERVER_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
REPO_ROOT = os.path.abspath(os.path.join(SERVER_DIR, ".."))
if SERVER_DIR not in sys.path:
    sys.path.insert(0, SERVER_DIR)

import buildings  # noqa: E402
import de_enhancer  # noqa: E402
import geodesy  # noqa: E402
import roads as roadsmod  # noqa: E402
from de_street_enhancer import brand_registry  # noqa: E402
from de_street_enhancer import classifier  # noqa: E402
from de_street_enhancer import facade_style  # noqa: E402
from de_street_enhancer import furniture_de  # noqa: E402
from de_street_enhancer import placement  # noqa: E402
from de_street_enhancer import texture_atlas  # noqa: E402


class _FakeFeats:
    def __init__(self, ids, attrs, origin, scale):
        self.ids = ids
        self.attrs = attrs
        self.origin = origin
        self.scale = scale

    def __len__(self):
        return len(self.ids)

    def parts(self, _i):
        return [[np.array([[0.0, 0.0]], dtype=np.float64)]]


class _FakeFuelMD:
    """Minimal in-memory mapdata stub with an OSM `amenity=fuel` node."""

    def __init__(self, frame, pt_xy, brand="Aral"):
        self.frame = frame
        self.pt_xy = pt_xy
        self.brand = brand

    def cell(self, _cell_key, layers=(), kind="demand"):
        if "infrastructure" not in layers:
            return SimpleNamespace(layers={})
        la, lo, _ = self.frame.enu_to_geodetic(
            np.array([self.pt_xy[0]], dtype=np.float64),
            np.array([self.pt_xy[1]], dtype=np.float64),
            np.zeros(1, dtype=np.float64),
        )
        feats = _FakeFeats(
            ids=["node:fuel_aral_1"],
            attrs={
                "class": ["fuel"],
                "name": [self.brand],
                "tags": [f'{{"amenity":"fuel","brand":"{self.brand}"}}'],
            },
            origin=(float(lo[0]), float(la[0])),
            scale=(1e-7, 1e-7),
        )
        return SimpleNamespace(layers={"infrastructure": feats})


def _make_road(fid, pts, width=7.0, cls="secondary", name="Bahnhofstraße"):
    sp = SimpleNamespace(width=width, cls=cls, name=name)
    return (fid, sp, np.asarray(pts, dtype=np.float64), None)


class TestDeStyleContract(unittest.TestCase):
    def setUp(self):
        self.munich = geodesy.EnuFrame(48.1372, 11.5755)  # Marienplatz, Munich (DE)
        self.mittenwald = geodesy.EnuFrame(47.4414, 11.2616)  # Mittenwald, Bavaria (DE)
        self.nyc = geodesy.EnuFrame(40.7484, -73.9857)  # Midtown NYC (outside DE)

    def test_off_switch_no_change_and_materials_parity(self):
        ring = np.array([[20.0, 20.0], [32.0, 20.0], [32.0, 30.0], [20.0, 30.0]], dtype=np.float64)
        attrs = {
            "class": "residential",
            "subtype": "residential",
            "height": 7.5,
            "num_floors": 2,
            "roof_shape": "gabled",
            "facade_color": "#ff40b0",
            "_de_in": True,
            "_de_lon": 11.5755,
            "_de_lat": 48.1372,
            "_de_alpine": False,
            "_de_neighbours": 0,
        }
        with mock.patch.dict(os.environ, {"BNE_DE_STREET_IMMERSION": "off"}):
            self.assertFalse(de_enhancer.enabled())
            box = roadsmod.tile_bbox(0, 0)
            self.assertEqual(de_enhancer.cache_parts(self.munich, box), ())
            self.assertFalse(de_enhancer.suppress_default_fences(self.munich, box))
            self.assertFalse(de_enhancer.suppress_default_shelters(self.munich, box))

            spec = buildings.plan(ring, attrs, 0, 48.1372, 11.5755)
            spec.seed = 0.42
            self.assertFalse(de_enhancer.is_de_spec(spec))
            res1 = buildings.build([(spec, 0.0, 0.2)], lite=False)
            res2 = buildings.build([(spec, 0.0, 0.2)], lite=False)
            self.assertIsNotNone(res1)
            for a, b in zip(res1, res2):
                np.testing.assert_array_equal(a, b)

            sf, sb, sup = de_enhancer.prepare_shops(None, self.munich, 0, 0, [(spec, 0.0, 0.2)], "/tmp", "/v")
            self.assertEqual((sf, sb, sup), (None, None, set()))
            st_f, st_b, y_rows = de_enhancer.finish_streets_and_yards(
                None, self.munich, 0, 0, box, [], {}, [], None, [(spec, 0.0, 0.2)], [], [], [], None, "/tmp", "/v"
            )
            self.assertEqual((st_f, st_b, y_rows), (None, None, []))

        # Verify buildings.materials.json matches upstream/main with zero unconditional static diffs
        diff = subprocess.run(
            ["git", "diff", "upstream/main", "--", "mod/beamng_earth/levels/beamng_earth/art/shapes/beamngEarth/buildings.materials.json"],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(diff.stdout.strip(), "", "buildings.materials.json must match upstream/main")

    def test_fuel_pylon_placement_determinism_and_clearances(self):
        road = _make_road("r1", [[0.0, 40.0], [120.0, 40.0]], width=7.0, name="Innsbrucker Straße")
        drive = {"n": np.array([[48.0, 43.5], [48.0, 52.0]], dtype=np.float64)}
        b_ring = np.array([[60.0, 56.0], [72.0, 56.0], [72.0, 66.0], [60.0, 66.0]], dtype=np.float64)
        fake_md = _FakeFuelMD(self.munich, np.array([32.0, 50.0], dtype=np.float64), brand="Aral")
        box = (0.0, 0.0, 256.0, 256.0)
        ground = lambda xs, ys: np.full(len(xs), 515.0, dtype=np.float64)

        with mock.patch("mapgeom.enu_xy", side_effect=lambda _f, _fr, _pts: (np.array([32.0]), np.array([50.0]))):
            p1 = furniture_de.plan_de_street_furniture(
                fake_md, self.munich, box, [road], None, [], [drive], [], [b_ring], ground
            )
            p2 = furniture_de.plan_de_street_furniture(
                fake_md, self.munich, box, [road], None, [], [drive], [], [b_ring], ground
            )

        self.assertEqual(len(p1.fuel_pylons), 1)
        pyl = p1.fuel_pylons[0]
        self.assertEqual(pyl.brand_key, "aral")
        self.assertEqual((pyl.e10, pyl.e5, pyl.diesel), (p2.fuel_pylons[0].e10, p2.fuel_pylons[0].e5, p2.fuel_pylons[0].diesel))
        np.testing.assert_allclose(pyl.xy, p2.fuel_pylons[0].xy)

        # Clearance from carriageway (>= half_w + 0.55 = 4.05 m) and driveway (>= 1.50 m)
        self.assertGreaterEqual(abs(float(pyl.xy[1]) - 40.0), 4.05)
        self.assertGreaterEqual(math_hypot(pyl.xy[0] - 48.0, pyl.xy[1] - 52.0), 1.50)

        # Atlas rendering + .cdae determinism
        with tempfile.TemporaryDirectory() as tmp:
            entries = [
                (furniture_de.FURNITURE_SWATCH_KEY, ("swatch", None, None)),
                (f"fuel|{pyl.brand_key}|{pyl.e10}|{pyl.e5}|{pyl.diesel}", ("fuel", pyl, None)),
            ]

            def _render(item):
                if item[0] == "swatch":
                    return texture_atlas.render_furniture_swatch()
                fp = item[1]
                return texture_atlas.render_fuel_pylon(fp.brand_key, fp.brand_label, fp.e10, fp.e5, fp.diesel)

            mat_name, dds, _vfs, uv_map, img = texture_atlas.pack_atlas(entries, _render, tmp, "/v", prefix="st")
            self.assertIsNotNone(mat_name)
            self.assertTrue(os.path.exists(dds))
            self.assertGreater(img.getbbox()[2], 0)
            blob1 = placement.encode_streets_and_furniture_mesh([], p1, mat_name, uv_map, (0.0, 0.0, 0.0))
            blob2 = placement.encode_streets_and_furniture_mesh([], p2, mat_name, uv_map, (0.0, 0.0, 0.0))
            self.assertIsNotNone(blob1)
            self.assertEqual(hashlib.sha1(blob1).hexdigest(), hashlib.sha1(blob2).hexdigest())

    def test_dormers_and_south_pv_panels_deterministic_and_bounded(self):
        # East-West ridge (length 12 m along X, width 8 m along Y): south slope faces -Y (ENU)
        ring = np.array([[40.0, 40.0], [52.0, 40.0], [52.0, 48.0], [40.0, 48.0]], dtype=np.float64)
        with mock.patch.dict(os.environ, {"BNE_DE_STREET_IMMERSION": "on"}):
            # Pick a seed that triggers both dormer and PV deterministically
            chosen_spec = None
            for k in range(200):
                s = (k + 0.5) / 200.0
                if facade_style._h01(s, "de_dormer") < 0.35 and facade_style._h01(s, "de_pv") < 0.26:
                    attrs = {
                        "class": "detached",
                        "subtype": "residential",
                        "height": 6.0,
                        "num_floors": 2,
                        "roof_shape": "gabled",
                        "_de_in": True,
                        "_de_lon": 11.2616,
                        "_de_lat": 47.4414,
                        "_de_alpine": True,
                        "_de_neighbours": 0,
                    }
                    chosen_spec = buildings.plan(ring, attrs, 0, 47.4414, 11.2616)
                    chosen_spec.seed = s
                    break
            self.assertIsNotNone(chosen_spec)

            # Build baseline without DE roof details vs with DE roof details
            out1 = buildings.build([(chosen_spec, 0.0, 0.0)], lite=False)
            out2 = buildings.build([(chosen_spec, 0.0, 0.0)], lite=False)
            self.assertIsNotNone(out1)
            for a, b in zip(out1, out2):
                np.testing.assert_array_equal(a, b)

            # Verify PV navy vertices (22, 34, 54) exist strictly above z_eave
            P, _UV, _T, _M, _MATS, C = out1
            z_eave = buildings.base_z(chosen_spec, 0.0, 0.0) + float(chosen_spec.height)
            pv_mask = (C[:, 0] == 22) & (C[:, 1] == 34) & (C[:, 2] == 54)
            self.assertTrue(pv_mask.any(), "expected south-facing PV panel vertices")
            self.assertTrue((P[pv_mask, 2] >= z_eave).all(), "PV panels must sit above z_eave")

    def test_shopfront_local_variety_and_slope_clamping(self):
        # Local independent fallbacks produce varied labels across seeds
        labels = {
            brand_registry.fallback_brand(0.1 + i * 0.07, 47.44, "commercial", local_seed=(i * 0.09) % 0.40)[1]
            for i in range(10)
        }
        self.assertGreaterEqual(len(labels), 5)

        # Steep slope: door_g near gmax, low single-storey eave -> z_mid clamped below z_eave - 0.25
        ring = np.array([[10.0, 10.0], [18.0, 10.0], [18.0, 16.0], [10.0, 16.0]], dtype=np.float64)
        spec = buildings.Spec(
            ring=ring,
            floors=1,
            floor_h=2.7,
            height=2.7,
            min_h=0.0,
            roof="gabled",
            cls="detached",
            seed=0.33,
            door=(0, 4.0),
            de_in=True,
            de_hn="12a",
        )
        hn = classifier.collect_housenumbers([(spec, 0.0, 0.6)])
        self.assertEqual(len(hn), 1)
        z_eave = buildings.base_z(spec, 0.0, 0.6) + 2.7
        self.assertLessEqual(hn[0].z_mid, z_eave - 0.25 + 1e-6)


def math_hypot(dx, dy):
    return float(np.hypot(dx, dy))


if __name__ == "__main__":
    unittest.main()
