"""Offline unit & integration tests for the Germany (DE) Street-Level Immersion Enhancer."""

import os
os.environ.setdefault(
    "BNE_REGIONAL_DIR",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures", "regional"),
)

from pathlib import Path
import math
import sys
import tempfile
import types
import unittest
from unittest import mock

import numpy as np
from PIL import ImageFont

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import borderfixtures  # noqa: E402
import buildings  # noqa: E402
import cdae  # noqa: E402
import de_enhancer  # noqa: E402
import geodesy  # noqa: E402
import germany  # noqa: E402
import imagery  # noqa: E402
import mapgeom  # noqa: E402
import revisit  # noqa: E402
import roads  # noqa: E402
from de_street_enhancer import brand_registry, classifier, placement, texture_atlas  # noqa: E402


MUNICH = (48.1351, 11.5820)
COLOGNE = (50.9375, 6.9603)
PARIS = (48.8566, 2.3522)
SALZBURG = (47.8095, 13.0550)


def setUpModule():
    borderfixtures.require()


def _flat_elev(_la, _lo):
    return np.zeros_like(np.asarray(_la, dtype=np.float64))


def _flat_ground(x, y):
    return np.zeros_like(np.asarray(x, dtype=np.float64))


def _road_spec(cls="residential", width=6.5):
    return roads.Spec(width=width, kind="paved", urban=True, cls=cls, oneway=False, walk=True)


class ToggleAndBorderTest(unittest.TestCase):
    def test_disabled_by_default_and_clean_cache_parts(self):
        frame = geodesy.EnuFrame(*MUNICH)
        box = (0.0, 0.0, 256.0, 256.0)
        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop("BNE_DE_STREET_IMMERSION", None)
            self.assertFalse(de_enhancer.enabled())
            self.assertEqual(de_enhancer.cache_parts(frame, box), ())
            self.assertFalse(de_enhancer.suppress_default_fences(frame, box))
            sf, sb, sup = de_enhancer.prepare_shops(None, frame, 0, 0, [], "/tmp", "/v")
            self.assertIsNone(sf)
            self.assertIsNone(sb)
            self.assertEqual(sup, set())

    def test_border_isolation_france_and_austria_emit_zero_assets(self):
        with mock.patch.dict(os.environ, {"BNE_DE_STREET_IMMERSION": "on"}):
            self.assertTrue(de_enhancer.enabled())
            for lat, lon in (PARIS, SALZBURG):
                frame = geodesy.EnuFrame(lat, lon)
                box = (0.0, 0.0, 256.0, 256.0)
                self.assertFalse(de_enhancer.in_germany(frame, box))
                self.assertFalse(de_enhancer.suppress_default_fences(frame, box))
                with tempfile.TemporaryDirectory() as tmp:
                    sf, s_blob, yard_rows = de_enhancer.finish_streets_and_yards(
                        None, frame, 0, 0, box, [], {}, [], [], [], [], [], [], _flat_ground, tmp, "/temp/vfs"
                    )
                    self.assertIsNone(sf)
                    self.assertIsNone(s_blob)
                    self.assertEqual(yard_rows, [])
                    self.assertEqual(os.listdir(tmp), [])

            frame_de = geodesy.EnuFrame(*MUNICH)
            box = (0.0, 0.0, 256.0, 256.0)
            self.assertTrue(de_enhancer.in_germany(frame_de, box))
            self.assertTrue(de_enhancer.suppress_default_fences(frame_de, box))
            parts = de_enhancer.cache_parts(frame_de, box)
            self.assertGreaterEqual(len(parts), 4)
            self.assertTrue(parts[0])


class BrandAndClassifierTest(unittest.TestCase):
    def test_wikidata_aliases_and_aldi_nord_sued_split(self):
        b_rewe, title_rewe = brand_registry.match_poi("Q16968817", None, None, "supermarket", lat=48.13)
        self.assertEqual(b_rewe.key, "rewe")
        self.assertEqual(title_rewe, "REWE")

        b_south, title_s = brand_registry.match_poi(None, "ALDI", "ALDI Markt", "supermarket", lat=48.13)
        self.assertEqual(b_south.key, "aldi_sued")
        self.assertEqual(title_s, "ALDI SÜD")

        b_north, title_n = brand_registry.match_poi(None, "ALDI", "ALDI Markt", "supermarket", lat=53.55)
        self.assertEqual(b_north.key, "aldi_nord")
        self.assertEqual(title_n, "ALDI")

        b_apo, title_apo = brand_registry.match_poi(None, None, "Löwen-Apotheke", "pharmacy", lat=50.93)
        self.assertEqual(b_apo.key, "apotheke")
        self.assertIn("Apotheke", title_apo)

    def test_places_extraction_ignores_closed_and_matches_street_facade(self):
        frame = geodesy.EnuFrame(*MUNICH)
        # 1 commercial building facing south street (wall 0: (20,20)->(40,20), outward=(0,-1)),
        # plus 1 blocked courtyard wall directly behind it.
        ring1 = np.array([[20.0, 20.0], [40.0, 20.0], [40.0, 35.0], [20.0, 35.0]], dtype=np.float64)
        spec1 = buildings.Spec(
            ring=ring1, floors=3, floor_h=3.2, height=10.5, roof="flat", shop=True,
            cls="retail", seed=0.11, sign=0, front=0, street=(0,), min_h=0.0, windows=True, name="Edeka City",
        )
        # Neighbor blocking wall edge 0 of rear building
        ring_block = np.array([[20.0, 48.0], [40.0, 48.0], [40.0, 56.0], [20.0, 56.0]], dtype=np.float64)
        ring_rear = np.array([[20.0, 57.5], [40.0, 57.5], [40.0, 68.0], [20.0, 68.0]], dtype=np.float64)
        spec_rear = buildings.Spec(
            ring=ring_rear, floors=2, floor_h=3.2, height=7.0, roof="flat", shop=True,
            cls="retail", seed=0.22, sign=0, front=0, street=(0,), min_h=0.0, windows=True,
        )
        spec_high = buildings.Spec(
            ring=ring1.copy(), floors=2, floor_h=3.2, height=6.4, roof="flat", shop=True,
            cls="retail", seed=0.33, sign=0, front=0, street=(0,), min_h=8.0, windows=True,
        )
        items = [(spec1, 0.0, 0.0), (buildings.Spec(ring=ring_block, floors=2, floor_h=3.2, height=6.4, roof="flat", min_h=0.0), 0.0, 0.0), (spec_rear, 0.0, 0.0), (spec_high, 0.0, 0.0)]

        poi_lat, poi_lon, _ = frame.enu_to_geodetic(30.0, 26.0, 0.0)
        closed_lat, closed_lon, _ = frame.enu_to_geodetic(30.0, 60.0, 0.0)
        pois = [
            (
                classifier.RetailCandidate("p1", float(poi_lon), float(poi_lat), "rewe", "REWE City", "supermarket", 0.95),
                np.array([30.0, 26.0]),
            ),
        ]

        # Ensure _extract_cell_pois skips operating_status == 'closed'
        fake_layer = mapgeom.Features(
            layer="places",
            ids=np.array(["open_1", "closed_1"]),
            kind=np.array([mapgeom.POINT, mapgeom.POINT]),
            part_off=np.array([0, 1, 2], np.int64),
            ring_off=np.array([0, 1, 2], np.int64),
            coord_off=np.array([0, 1, 2], np.int64),
            lonlat=np.array([[float(poi_lon), float(poi_lat)], [float(closed_lon), float(closed_lat)]]),
            en=None,
            own=None,
            clipped=None,
            attrs={
                "operating_status": np.array(["open", "closed"]),
                "brand_wikidata": np.array(["Q16968817", "Q701755"]),
                "brand_name": np.array(["REWE", "EDEKA"]),
                "name": np.array(["REWE City", "Closed Store"]),
                "basic_category": np.array(["supermarket", "supermarket"]),
                "taxonomy": np.array(["supermarket", "supermarket"]),
                "confidence": np.array([0.9, 0.9]),
            },
            rules={},
        )
        extracted = classifier._extract_cell_pois(fake_layer)
        self.assertEqual(len(extracted), 1)
        self.assertEqual(extracted[0].poi_id, "open_1")

        targets, suppress = classifier.classify_commercial_buildings(items, pois, frame, 0.0, 0.0)
        self.assertEqual(len(targets), 1)
        self.assertEqual(targets[0].spec_brand.key, "rewe")
        self.assertEqual(targets[0].label, "REWE City")
        self.assertIn(id(spec1), suppress)
        # Rear building blocked by ray check (1.5m gap < COURTYARD_RAY_CLEAR_M), high setback part rejected.
        self.assertNotIn(id(spec_rear), suppress)
        self.assertNotIn(id(spec_high), suppress)


class TextureAtlasAndFontsTest(unittest.TestCase):
    def test_street_and_shop_atlas_dds_encoding_and_fallback(self):
        with tempfile.TemporaryDirectory() as tmp:
            street_items = [
                ("street|blue|Maximilianstraße", ("Maximilianstraße", "blue")),
                ("street|blue|Bürgermeister-von-Schubert-Straße", ("Bürgermeister-von-Schubert-Straße", "blue")),
                ("street|white|Großmehringer Straße", ("Großmehringer Straße", "white")),
            ]
            mat, disk, vfs, uvs, img = texture_atlas.pack_atlas(
                street_items,
                lambda p: texture_atlas.render_street_plate(p[0], variant=p[1]),
                tmp,
                "/temp/test_sess",
                "st",
            )
            self.assertTrue(mat.startswith("bne_de_st_"))
            self.assertTrue(vfs.startswith("/temp/test_sess/de_st_"))
            self.assertTrue(os.path.exists(disk))
            with open(disk, "rb") as f:
                w, h, mips, fourcc, _ = imagery.read_dds_info(f.read())
            self.assertEqual((w, h, fourcc), (1024, 512, b"DXT1"))
            self.assertGreaterEqual(mips, 1)
            for rect in uvs.values():
                self.assertTrue(all(0.0 < v < 1.0 for v in rect))

            # Repeat call reuses exact cached file and hash
            mtime0 = os.stat(disk).st_mtime_ns
            mat2, disk2, _, _, _ = texture_atlas.pack_atlas(
                street_items,
                lambda p: texture_atlas.render_street_plate(p[0], variant=p[1]),
                tmp,
                "/temp/test_sess",
                "st",
            )
            self.assertEqual(mat, mat2)
            self.assertEqual(os.stat(disk2).st_mtime_ns, mtime0)

            # Missing bundled font files gracefully fall back to Pillow default font
            texture_atlas._load_font.cache_clear()
            with mock.patch.object(texture_atlas, "FONT_CANDIDATES_BOLD", ("/nonexistent/bold.otf",)), \
                    mock.patch.object(texture_atlas, "FONT_CANDIDATES_CONDENSED", ("/nonexistent/cond.ttf",)):
                fallback_img = texture_atlas.render_shop_fascia(brand_registry.BY_KEY["apotheke"], "Apotheke")
                self.assertEqual(fallback_img.size, (texture_atlas.SLOT_W, texture_atlas.SLOT_H))
            texture_atlas._load_font.cache_clear()


class GeometrySafetyAndPipelineTest(unittest.TestCase):
    def test_multiway_acute_and_junction_sign_clearance(self):
        frame = geodesy.EnuFrame(*MUNICH)
        box = (0.0, 0.0, 256.0, 256.0)
        # 4-way + acute 32-deg branch meeting at (120, 120), plus duplicate through-street name.
        road_defs = [
            ("r1", _road_spec("tertiary", 7.0), np.array([[40.0, 120.0, 0.0], [120.0, 120.0, 0.0]]), "Leopoldstraße"),
            ("r2", _road_spec("tertiary", 7.0), np.array([[120.0, 120.0, 0.0], [210.0, 120.0, 0.0]]), "Leopoldstraße"),
            ("r3", _road_spec("residential", 6.0), np.array([[120.0, 40.0, 0.0], [120.0, 120.0, 0.0]]), "Georgenstraße"),
            ("r4", _road_spec("residential", 5.5), np.array([[120.0, 120.0, 0.0], [190.0, 163.0, 0.0]]), "Türkenstraße"),  # ~31.5 deg from r2
        ]
        near_roads = [(fid, sp, pts, MUNICH[1]) for fid, sp, pts, _ in road_defs]
        street_names = {fid: nm for fid, _sp, _pts, nm in road_defs}

        # Existing DE junction sign + street lamp near junction
        de_z_spot = (114.5, 114.5)
        lamp_spot = (113.0, 126.5)
        props = [
            ["de_z306", de_z_spot[0], de_z_spot[1], 0.0, 0.0, 1.0, 3.46, 0.0],
            ["eu_lamp_steel", lamp_spot[0], lamp_spot[1], 0.0, 90.0, 1.0, 9.0, 0.0],
        ]

        posts = placement.plan_street_signs(frame, near_roads, box, street_names, props, _flat_ground)
        self.assertEqual(len(posts), 1)
        post = posts[0]
        # Mounted onto eu_lamp_steel because it clears de_z306 by > 1.15m and is near junction
        self.assertTrue(post.mounted_on_pole)
        self.assertGreaterEqual(np.hypot(post.xy[0] - de_z_spot[0], post.xy[1] - de_z_spot[1]), placement.DE_Z_MIN_CLEAR_M)
        # Leopoldstraße deduplicated -> exactly 3 distinct blades
        self.assertEqual(len(post.blades), 3)
        blade_names = [b[0] for b in post.blades]
        self.assertEqual(len(set(blade_names)), 3)
        # Staggered vertical spacing >= 0.18 m
        zs = [b[2] for b in post.blades]
        self.assertGreater(zs[1] - zs[0], 0.18)
        self.assertGreater(zs[2] - zs[1], 0.18)

        # Standalone acute junction post placement (no lamp present)
        posts_standalone = placement.plan_street_signs(frame, near_roads, box, street_names, [props[0]], _flat_ground)
        self.assertEqual(len(posts_standalone), 1)
        self.assertFalse(posts_standalone[0].mounted_on_pole)
        road_lines = [(float(sp.width) / 2.0, pts) for _f, sp, pts, _l in near_roads]
        self.assertGreaterEqual(placement._min_dist_to_segments(posts_standalone[0].xy, road_lines), placement.ROAD_EDGE_BLADE_CLEAR_M)

        # CDAE round-trip decode test
        with tempfile.TemporaryDirectory() as tmp:
            mat, _d, vfs_tex, uv_map, _ = texture_atlas.pack_atlas(
                [(f"street|blue|{b[0]}", (b[0], "blue")) for b in post.blades],
                lambda p: texture_atlas.render_street_plate(p[0], variant=p[1]),
                tmp,
                "/temp/v",
                "st",
            )
            blob = placement.encode_street_signs_mesh(posts, mat, uv_map, (0.0, 0.0, 0.0))
            self.assertIsNotNone(blob)
            decoded = cdae.decode(blob)
            self.assertGreater(len(decoded["meshes"]), 0)
            mat_names = [m["name"] for m in decoded["materials"]]
            self.assertIn(mat, mat_names)
            self.assertIn(placement.METAL_MATERIAL, mat_names)
            arrays = cdae.mesh_arrays(decoded["meshes"][0])
            self.assertGreater(len(arrays["verts"]), 0)
            self.assertGreater(len(arrays["indices"]), 0)

    def test_residential_yard_clears_driveway_and_suppresses_us_fence(self):
        frame = geodesy.EnuFrame(*MUNICH)
        box = (0.0, 0.0, 256.0, 256.0)
        # House centered around (100, 114), facing street at y = 100
        ring = np.array([[92.0, 110.0], [108.0, 110.0], [108.0, 120.0], [92.0, 120.0]], dtype=np.float64)
        spec = buildings.Spec(
            ring=ring, floors=2, floor_h=2.8, height=5.8, roof="gabled", shop=False,
            cls="detached", seed=0.05, door=(0, 4.0), min_h=0.0,
        )
        road_pts = np.array([[40.0, 100.0, 0.0], [160.0, 100.0, 0.0]], dtype=np.float64)
        near_roads = [("r_res", _road_spec("residential", 6.0), road_pts, MUNICH[1])]
        walks = [{"pts": np.array([[40.0, 104.1, 0.0], [160.0, 104.1, 0.0]]), "side": 1, "w": 2.2}]
        # Driveway cutout at x = 104 from house down to road edge
        drives = [{"w": 3.0, "n": [[104.0, 110.0, 0.0], [104.0, 103.0, 0.0]]}]

        with mock.patch.dict(os.environ, {"BNE_DE_STREET_IMMERSION": "on"}):
            rows = placement.place_residential_yards(
                frame, box, [(spec, 0.0, 0.0)], near_roads, walks, drives, None, [ring], _flat_ground, md=None
            )
            wide_walks = [{"pts": np.array([[40.0, 104.6, 0.0], [160.0, 104.6, 0.0]]), "side": 1, "w": 3.2}]
            wide_rows = placement.place_residential_yards(
                frame, box, [(spec, 0.0, 0.0)], near_roads, wide_walks, drives, None, [ring], _flat_ground, md=None
            )
        self.assertGreater(len(rows), 0)
        self.assertGreater(len(wide_rows), 0)
        for row in wide_rows:
            # Sidewalk outer edge is at y = 104.6 + 3.2/2 = 106.2; clearance must exceed outer edge + DE_YARD_WALK_OFFSET_M.
            self.assertGreaterEqual(row[2], 106.2 + placement.DE_YARD_WALK_OFFSET_M - 0.01, f"wide-sidewalk boundary failed to clear outer edge: {row}")
        for row in rows:
            self.assertNotEqual(row[0], "fence", "never emits default US wood fence")
            self.assertTrue(row[0] == "fr_hedge" or str(row[0]).startswith("fr_fence_"))
            # Verify no hedge/fence landed inside doorway (x ~ 96) or driveway gap (x ~ 104)
            self.assertFalse(102.6 <= row[1] <= 105.4, f"row inside driveway gap: {row}")
            self.assertGreaterEqual(row[2], 103.8, f"row encroaches on road/sidewalk: {row}")

    def test_write_tile_and_revisit_shapes_in_capture_de_assets(self):
        frame = geodesy.EnuFrame(*COLOGNE)
        with tempfile.TemporaryDirectory() as tmp:
            vfs = "/temp/beamngEarth/sess"
            de_faces = {
                "bne_de_st_abc123": {"texture": f"{vfs}/de_st_abc123.dds", "emissive": False},
                "bne_de_sh_def456": {"texture": f"{vfs}/de_sh_def456.dds", "emissive": True, "nits": 35, "glowColor": "1 0.94 0.84"},
            }
            # Create dummy encoded CDAE + DDS files cleanly
            shop_target = classifier.ShopTarget(
                building_idx=0,
                center_xy=np.array([25.0, 25.0]),
                d_along=np.array([1.0, 0.0]),
                out_normal=np.array([0.0, -1.0]),
                width_m=4.5,
                height_m=0.7,
                z_bottom=3.1,
                z_top=3.8,
                spec_brand=brand_registry.BY_KEY["rewe"],
                label="REWE",
            )
            blob = placement.encode_shop_fascias_mesh([shop_target], "bne_de_sh_def456", {"shop|rewe|REWE": (0.1, 0.1, 0.9, 0.9)})
            self.assertIsNotNone(blob)
            json_vfs, _ = roads.write_tile(
                tmp, vfs, 1, 0, 0, [], decals=False, de_shops=blob, de_faces=de_faces
            )
            self.assertTrue(json_vfs.endswith("roads_1_0_0.json"))
            text = Path(os.path.join(tmp, "roads_1_0_0.json")).read_text(encoding="utf-8")
            shapes = revisit.shapes_in(text, vfs)
            self.assertIn("deshops_1_0_0.cdae", shapes)
            self.assertIn("de_st_abc123.dds", shapes)
            self.assertIn("de_sh_def456.dds", shapes)

    def test_curved_multivertex_polylines_no_rust_panic(self):
        """Regression: multi-segment roads/walks/barriers (>=3 vertices) must expand half-widths cleanly."""
        frame = geodesy.EnuFrame(*MUNICH)
        box = (0.0, 0.0, 256.0, 256.0)
        xs = np.linspace(30.0, 200.0, 6)
        road_pts = np.column_stack([xs, np.full_like(xs, 100.0), np.zeros_like(xs)])
        near_roads = [("r_curve", _road_spec("residential", 6.0), road_pts, MUNICH[1])]
        walks = [{"pts": np.column_stack([xs, np.full_like(xs, 104.2), np.zeros_like(xs)]), "side": 1, "w": 2.2}]

        ring = np.array([[92.0, 111.0], [108.0, 111.0], [108.0, 121.0], [92.0, 121.0]], dtype=np.float64)
        spec = buildings.Spec(
            ring=ring, floors=2, floor_h=2.8, height=5.8, roof="gabled", shop=False,
            cls="detached", seed=0.05, door=(0, 4.0), min_h=0.0,
        )

        # Fake infrastructure barrier layer with curved 5-vertex polylines (near & far).
        def _mk_barrier_md(barrier_y: float):
            b_xs = np.linspace(80.0, 130.0, 5)
            b_ys = np.full_like(b_xs, barrier_y)
            la, lo, _ = frame.enu_to_geodetic(b_xs, b_ys, 0.0)
            feats = mapgeom.Features(
                layer="infrastructure",
                lonlat=np.column_stack([lo, la]),
                coord_off=np.array([0, len(b_xs)], dtype=np.int64),
                ring_off=np.array([0, 1], dtype=np.int64),
                part_off=np.array([0, 1], dtype=np.int64),
                kind=np.array([2], dtype=np.int8),
                attrs={"class": np.array(["fence"], dtype=object)},
                ids=np.array(["bar_1"], dtype=object),
            )
            fake_cell = types.SimpleNamespace(layers={"infrastructure": feats})
            return types.SimpleNamespace(cell=lambda *a, **kw: fake_cell)

        with mock.patch.dict(os.environ, {"BNE_DE_STREET_IMMERSION": "on"}):
            # Distant barrier (5 vertices): should NOT suppress house yard and must not panic in Rust.
            rows_clear = placement.place_residential_yards(
                frame, box, [(spec, 0.0, 0.0)], near_roads, walks, [], None, [ring], _flat_ground,
                md=_mk_barrier_md(190.0),
            )
            self.assertGreater(len(rows_clear), 0)

            # Nearby barrier along y=106.0 (5 vertices): should skip house frontage cleanly without Rust panic.
            rows_blocked = placement.place_residential_yards(
                frame, box, [(spec, 0.0, 0.0)], near_roads, walks, [], None, [ring], _flat_ground,
                md=_mk_barrier_md(106.0),
            )
            self.assertEqual(rows_blocked, [])

    def test_empty_and_degenerate_tile_inputs_inside_germany_no_rust_panic(self):
        """Regression: empty roads, walks, buildings, and zero-item tiles inside DE must never panic."""
        frame = geodesy.EnuFrame(*MUNICH)
        box = (0.0, 0.0, 256.0, 256.0)
        ground_calls = []

        def _strict_ground(xs, ys):
            xs_arr = np.asarray(xs)
            ground_calls.append(xs_arr.shape)
            if xs_arr.size == 0:
                raise AssertionError("ground callback invoked with empty array")
            return np.zeros(xs_arr.size, dtype=np.float64)

        empty_feats = mapgeom.Features(
            layer="infrastructure",
            lonlat=np.zeros((0, 2), dtype=np.float64),
            coord_off=np.array([0], dtype=np.int64),
            ring_off=np.array([0], dtype=np.int64),
            part_off=np.array([0], dtype=np.int64),
            kind=np.array([], dtype=np.int8),
            attrs={"class": np.array([], dtype=object)},
            ids=np.array([], dtype=object),
        )
        empty_md = types.SimpleNamespace(
            cell=lambda *a, **kw: types.SimpleNamespace(layers={"places": empty_feats, "infrastructure": empty_feats})
        )

        # Direct empty & mismatched array guards for Rust points_near_segments & blocker expansion.
        self.assertIsNone(placement._expand_blocker_segments([]))
        self.assertIsNone(placement._expand_blocker_segments([(np.zeros((0, 2)), 3.0), (np.array([[1.0, 2.0]]), 3.0)]))
        self.assertFalse(placement._points_near_segments_safe(np.zeros((0, 2)), None))
        fake_blocks = (np.zeros((0, 2)), np.zeros((0, 2)), np.zeros((0,)))
        self.assertFalse(placement._points_near_segments_safe(np.array([[10.0, 10.0]]), fake_blocks))
        mismatched = (np.zeros((2, 2)), np.zeros((2, 2)), np.zeros((1,)))
        self.assertFalse(placement._points_near_segments_safe(np.array([[10.0, 10.0]]), mismatched))
        self.assertEqual(len(placement._sample_ground(_strict_ground, [], [])), 0)
        self.assertEqual(ground_calls, [])

        with mock.patch.dict(os.environ, {"BNE_DE_STREET_IMMERSION": "on"}):
            with tempfile.TemporaryDirectory() as tmp:
                # 1. Completely empty roads / walks / buildings / zero-item tile via hooks.
                sf, sb, sup = de_enhancer.prepare_shops(empty_md, frame, 0, 0, [], tmp, "/temp/v")
                self.assertEqual((sf, sb, sup), (None, None, set()))
                sf, sb, sup = de_enhancer.prepare_shops(empty_md, frame, 0, 0, None, tmp, "/temp/v")
                self.assertEqual((sf, sb, sup), (None, None, set()))

                st_f, st_b, y_rows = de_enhancer.finish_streets_and_yards(
                    empty_md, frame, 0, 0, box, [], {}, [], None, None, [], [], [], _strict_ground, tmp, "/temp/v"
                )
                self.assertEqual((st_f, st_b, y_rows), (None, None, []))

                st_f, st_b, y_rows = de_enhancer.finish_streets_and_yards(
                    empty_md, frame, 0, 0, box, [], {}, [], [], [], [], [], [], _strict_ground, tmp, "/temp/v"
                )
                self.assertEqual((st_f, st_b, y_rows), (None, None, []))

                # 2. Empty walks & empty buildings alongside valid roads, plus single-point degenerate inputs.
                road_pts = np.array([[40.0, 100.0, 0.0], [160.0, 100.0, 0.0]], dtype=np.float64)
                degen_road = np.array([[40.0, 100.0, 0.0]], dtype=np.float64)
                empty_road = np.zeros((0, 3), dtype=np.float64)
                self.assertEqual(placement.plan_street_signs(frame, [], box, {"r1": "Hauptstraße"}, [], _strict_ground), [])
                self.assertEqual(
                    placement.plan_street_signs(
                        frame,
                        [("r_empty", _road_spec(), empty_road, MUNICH[1]), ("r_1pt", _road_spec(), degen_road, MUNICH[1])],
                        box,
                        {"r_empty": "Astraße", "r_1pt": "Bstraße"},
                        [],
                        _strict_ground,
                    ),
                    [],
                )

                # Valid roads + empty buildings + None/empty walks.
                self.assertEqual(
                    placement.place_residential_yards(
                        frame, box, [], [("r1", _road_spec(), road_pts, MUNICH[1])], [], [], None, [], _strict_ground, md=empty_md
                    ),
                    [],
                )
                self.assertEqual(
                    placement.place_residential_yards(
                        frame, box, [], [("r1", _road_spec(), road_pts, MUNICH[1])], None, [], None, [], _strict_ground, md=empty_md
                    ),
                    [],
                )

                # Degenerate 0-vertex / 2-vertex building spec must not crash classifiers or shop builder.
                bad_spec = buildings.Spec(
                    ring=np.zeros((0, 2), dtype=np.float64),
                    floors=2, floor_h=2.8, height=5.8, roof="flat", shop=True,
                    cls="retail", seed=0.1, min_h=0.0,
                )
                sf, sb, sup = de_enhancer.prepare_shops(empty_md, frame, 0, 0, [(bad_spec, 0.0, 0.0)], tmp, "/temp/v")
                self.assertEqual((sf, sb, sup), (None, None, set()))
                self.assertEqual(
                    placement.place_residential_yards(
                        frame, box, [(bad_spec, 0.0, 0.0)], [("r1", _road_spec(), road_pts, MUNICH[1])],
                        [], [], None, [], _strict_ground, md=empty_md
                    ),
                    [],
                )
                self.assertEqual(ground_calls, [])


class FacadeRealismAndExpansionTest(unittest.TestCase):
    DORTMUND = (51.5136, 7.4653)

    def test_facade_color_grading_and_regional_bias(self):
        from de_street_enhancer import facade_style

        ring = np.array([[0.0, 0.0], [10.0, 0.0], [10.0, 8.0], [0.0, 8.0]], dtype=np.float64)

        # Disabled inside DE -> never touches spec
        with mock.patch.dict(os.environ, {"BNE_DE_STREET_IMMERSION": "off"}):
            s_off = buildings.plan(ring, {"class": "house", "facade_color": "#ff44cc"}, 0, *MUNICH)
            self.assertFalse(de_enhancer.is_de_spec(s_off))

        # Enabled outside DE (Paris) -> never touches spec
        with mock.patch.dict(os.environ, {"BNE_DE_STREET_IMMERSION": "on"}):
            s_paris = buildings.plan(ring, {"class": "house", "facade_color": "#ff44cc"}, 0, 48.8566, 2.3522)
            self.assertFalse(de_enhancer.is_de_spec(s_paris))

            # Neon OSM facade & roof colors inside DE get clamped into mineral/clay palette
            s_clamp = buildings.plan(
                ring,
                {"class": "house", "facade_color": "#ff44cc", "roof_color": "#00ff88"},
                0,
                *self.DORTMUND,
            )
            self.assertTrue(facade_style.is_de_spec(s_clamp))
            _, f_rgb = buildings.LOOKS[s_clamp.facade]
            _, r_rgb = buildings.LOOKS[s_clamp.roof_mat]
            self.assertLessEqual(max(f_rgb) - min(f_rgb), 0.36)
            self.assertLessEqual(max(r_rgb) - min(r_rgb), 0.34)

            # Alpine wood chalet preserved in Bavaria mountains vs converted to plaster in flatland/Dortmund
            s_alpine = buildings.plan(
                ring,
                {"class": "house", "facade_material": "wood", "_de_in": True, "_de_lat": 47.49, "_de_lon": 11.10, "_de_alpine": True},
                0,
                47.49,
                11.10,
                alpine=True,
            )
            self.assertEqual(buildings.LOOKS[s_alpine.facade][0], buildings.SIDING)

            # Regional clinker bias: Dortmund (north_nw) > Munich (south)
            dort_brick = 0
            munich_brick = 0
            for k in range(50):
                rk = ring + np.array([k * 0.137, k * 0.091])
                sd = buildings.plan(rk, {"class": "house"}, 0, *self.DORTMUND)
                sm = buildings.plan(rk, {"class": "house"}, 0, *MUNICH)
                if sd.band == buildings.BAND_BRICK:
                    dort_brick += 1
                if sm.band == buildings.BAND_BRICK:
                    munich_brick += 1
            self.assertGreater(dort_brick, munich_brick)

    def test_baked_vertex_color_depth_and_option_b_split(self):
        ring = np.array([[0.0, 0.0], [10.0, 0.0], [10.0, 8.0], [0.0, 8.0]], dtype=np.float64)
        with mock.patch.dict(os.environ, {"BNE_DE_STREET_IMMERSION": "on"}):
            spec = buildings.plan(ring, {"class": "house", "roof_shape": "gabled", "floors": 2}, 0, *self.DORTMUND)
            spec.gring = np.zeros(len(ring), dtype=np.float64)

            P_near, _uv, T_near, M_near, mats_near, C_near = buildings.build([(spec, 0.0, 0.0)], lite=False)
            P_lite, _uv_l, T_lite, M_lite, mats_lite, _C_lite = buildings.build([(spec, 0.0, 0.0)], lite=True)

            # Zero extra materials / draw calls
            self.assertEqual(mats_near, buildings.MATERIALS)
            self.assertEqual(mats_lite, buildings.MATERIALS)
            # Option B near quad split adds Sockel + under-eave horizontal bands cleanly vs lite
            self.assertGreater(len(T_near), len(T_lite))

            fac_mi = buildings.MATERIALS.index(buildings.LOOKS[spec.facade][0])
            fac_tris = T_near[M_near == fac_mi]
            tri_zs = P_near[fac_tris, 2].mean(axis=1)
            tri_luma = C_near[fac_tris, :3].astype(np.float64).mean(axis=(1, 2))
            sockel_luma = tri_luma[tri_zs <= 0.55]
            mid_luma = tri_luma[(tri_zs >= 1.8) & (tri_zs <= 3.8)]
            self.assertGreater(len(sockel_luma), 0)
            self.assertGreater(len(mid_luma), 0)
            self.assertLess(sockel_luma.mean(), mid_luma.mean() * 0.90)

            # Verify wall quads explicitly contain a cut around z = 0.75 m
            fac_verts = np.unique(fac_tris.ravel())
            zs = P_near[fac_verts, 2]
            z_cuts = zs[(zs > 0.70) & (zs < 0.80)]
            self.assertGreater(len(z_cuts), 0)

    def test_neighbor_safe_roof_overhangs_box_hf_and_skel(self):
        from de_street_enhancer import facade_style

        with mock.patch.dict(os.environ, {"BNE_DE_STREET_IMMERSION": "on"}):
            # 3 terraced row houses along X: [0..6], [6..12], [12..18] x [0..10]
            rows = []
            for x0 in (0.0, 6.0, 12.0):
                rg = np.array([[x0, 0.0], [x0 + 6.0, 0.0], [x0 + 6.0, 10.0], [x0, 10.0]], dtype=np.float64)
                sp = buildings.plan(rg, {"class": "terrace", "roof_shape": "gabled", "floors": 2}, 1, *self.DORTMUND)
                sp.gring = np.zeros(len(rg), dtype=np.float64)
                rows.append((sp, 0.0, 0.0))

            facade_style.compute_roof_overhangs(rows)
            # Left house has shared +X party wall -> 0.0 overhang on edge (+X), clear overhang on exposed walls
            e0 = rows[0][0].de_eaves
            e1 = rows[1][0].de_eaves
            self.assertIsNotNone(e0)
            self.assertIn(0.0, e0)
            self.assertGreater(max(e0), 0.28)
            # Middle house shares both side walls (two edges == 0.0)
            self.assertEqual(sum(1 for v in e1 if v == 0.0), 2)

            # Built roof mesh of left house must never protrude into middle neighbor x >= 6.05
            P0, _uv, T0, M0, _mats, _C0 = buildings.build([rows[0]], lite=False)
            rm0 = buildings.MATERIALS.index(buildings.LOOKS[rows[0][0].roof_mat][0])
            roof_pts = P0[T0[M0 == rm0].ravel()]
            self.assertLessEqual(float(roof_pts[:, 0].max()), 6.02)

            # Detached L-shaped skel roof + hf half-hipped roof build safely with clear overhangs
            l_ring = np.array([[0.0, 0.0], [12.0, 0.0], [12.0, 5.0], [6.0, 5.0], [6.0, 10.0], [0.0, 10.0]], dtype=np.float64)
            sp_skel = buildings.plan(l_ring, {"class": "house", "roof_shape": "gabled", "floors": 2}, 0, *MUNICH)
            sp_hf = buildings.plan(
                np.array([[25.0, 0.0], [37.0, 0.0], [37.0, 8.0], [25.0, 8.0]], dtype=np.float64),
                {"class": "house", "roof_shape": "half-hipped", "floors": 2},
                0,
                *MUNICH,
            )
            sp_hf.hf = True
            sp_skel.gring = np.zeros(len(l_ring), dtype=np.float64)
            sp_hf.gring = np.zeros(4, dtype=np.float64)
            facade_style.compute_roof_overhangs([(sp_skel, 0.0, 0.0), (sp_hf, 0.0, 0.0)])
            self.assertGreater(min(sp_skel.de_eaves), 0.28)
            self.assertGreater(min(sp_hf.de_eaves), 0.28)
            P_mix, _uv, T_mix, _M, _mats, _C = buildings.build([(sp_skel, 0.0, 0.0), (sp_hf, 0.0, 0.0)], lite=False)
            self.assertTrue(np.isfinite(P_mix).all())
            self.assertGreater(len(T_mix), 0)

    def test_edeka_fascia_cornice_clearance(self):
        frame = geodesy.EnuFrame(*self.DORTMUND)
        ring = np.array([[90.0, 108.0], [112.0, 108.0], [112.0, 126.0], [90.0, 126.0]], dtype=np.float64)
        edeka_spec = buildings.Spec(
            ring=ring, floors=1, floor_h=4.5, height=4.5, roof="flat", plain=False,
            shop=True, windows=False, cls="supermarket", seed=0.33, min_h=0.0, name="EDEKA", sign=0,
        )
        targets, suppress_ids = classifier.classify_commercial_buildings([(edeka_spec, 0.0, 0.0)], [], frame, 0, 0)
        self.assertEqual(len(targets), 1)
        self.assertIn(id(edeka_spec), suppress_ids)
        t = targets[0]
        self.assertEqual(t.spec_brand.key, "edeka")
        # Top of EDEKA sign must sit strictly below CORNICE_DOWN_M (0.45 m) overhang under z_eave = 4.5
        self.assertLessEqual(t.z_top, 4.5 - buildings.CORNICE_DOWN_M - 0.05)
        # Pushed outward by +0.15 m from wall (was +0.11 m)
        self.assertAlmostEqual(float(t.center_xy[1]), 108.0 - 0.15, places=3)

    def test_expanded_feature_c_yards_and_narrow_setback(self):
        frame = geodesy.EnuFrame(*MUNICH)
        box = (0.0, 0.0, 256.0, 256.0)
        road_pts = np.array([[30.0, 100.0, 0.0], [210.0, 100.0, 0.0]], dtype=np.float64)
        near_roads = [("r_sub", _road_spec("residential", 6.0), road_pts, MUNICH[1])]
        # Narrow suburban sidewalk: y = 103.0 .. 104.2 (outer edge y = 104.2), leaving narrow yard y = 104.2 .. 106.0
        walks = [{"pts": np.array([[30.0, 103.6, 0.0], [210.0, 103.6, 0.0]]), "side": 1, "w": 1.2}]

        terrace_ring = np.array([[60.0, 106.0], [67.0, 106.0], [67.0, 114.0], [60.0, 114.0]], dtype=np.float64)
        flat_house_ring = np.array([[85.0, 106.0], [95.0, 106.0], [95.0, 114.0], [85.0, 114.0]], dtype=np.float64)
        apt_ring = np.array([[115.0, 106.0], [137.0, 106.0], [137.0, 126.0], [115.0, 126.0]], dtype=np.float64)
        big_apt_ring = np.array([[155.0, 106.0], [180.0, 106.0], [180.0, 130.0], [155.0, 130.0]], dtype=np.float64)

        specs = [
            (buildings.Spec(ring=terrace_ring, floors=2, floor_h=2.8, height=5.8, roof="gabled", shop=False, cls="terrace", seed=0.05, door=(0, 3.5), min_h=0.0), 0.0, 0.0),
            (buildings.Spec(ring=flat_house_ring, floors=2, floor_h=2.8, height=5.6, roof="flat", shop=False, cls="house", seed=0.05, door=(0, 5.0), min_h=0.0), 0.0, 0.0),
            (buildings.Spec(ring=apt_ring, floors=3, floor_h=2.8, height=8.4, roof="flat", shop=False, cls="apartments", seed=0.05, door=(0, 11.0), min_h=0.0), 0.0, 0.0),
            (buildings.Spec(ring=big_apt_ring, floors=5, floor_h=2.8, height=14.0, roof="flat", shop=False, cls="apartments", seed=0.05, door=(0, 12.0), min_h=0.0), 0.0, 0.0),
        ]
        with mock.patch.dict(os.environ, {"BNE_DE_STREET_IMMERSION": "on"}):
            eligible = classifier.classify_residential_yards(specs, frame, 0, 0)
            self.assertEqual(len(eligible), 3)
            rows = placement.place_residential_yards(frame, box, specs, near_roads, walks, [], None, [s[0].ring for s in specs], _flat_ground, md=None)
        self.assertGreater(len(rows), 0)
        # All 3 narrow-yard houses receive enclosures placed cleanly >= 104.2 + 0.25 - 0.01 (~ 1.45 m from carriageway)
        ys = [float(r[2]) for r in rows]
        self.assertTrue(all(y >= 104.4 for y in ys), f"expected y >= 104.4 behind sidewalk, got {ys}")
        xs = [float(r[1]) for r in rows]
        self.assertTrue(any(60.0 <= x <= 67.0 for x in xs), f"terrace missing front yard: {xs}")
        self.assertTrue(any(85.0 <= x <= 95.0 for x in xs), f"flat-roof house missing front yard: {xs}")
        self.assertTrue(any(115.0 <= x <= 137.0 for x in xs), f"small apartments missing front yard: {xs}")
        self.assertFalse(any(155.0 <= x <= 180.0 for x in xs), f"5-floor apartment should be excluded: {xs}")

    def test_far_geo_cache_key_parity_outside_de(self):
        nyc_frame = geodesy.EnuFrame(40.758, -73.985)
        munich_frame = geodesy.EnuFrame(*MUNICH)
        box = (-1000.0, -1000.0, 1000.0, 1000.0)
        with mock.patch.dict(os.environ, {"BNE_DE_STREET_IMMERSION": "off"}):
            self.assertEqual(de_enhancer.cache_parts(nyc_frame, box), ())
            self.assertEqual(de_enhancer.cache_parts(munich_frame, box), ())
        with mock.patch.dict(os.environ, {"BNE_DE_STREET_IMMERSION": "on"}):
            self.assertEqual(de_enhancer.cache_parts(nyc_frame, box), (True, "outside"))
            self.assertGreater(len(de_enhancer.cache_parts(munich_frame, box)), 2)

    def test_bake_building_depth_20_and_30_vertex_meshes_and_tile_buildings(self):
        """Regression: trailing 3-vertex triangles at len(P)==20 or 30 must not IndexError on P[v0+3]."""
        from de_street_enhancer import facade_style

        frame = geodesy.EnuFrame(*self.DORTMUND)
        with mock.patch.dict(os.environ, {"BNE_DE_STREET_IMMERSION": "on"}):
            # 1. Explicit 20-vertex and 30-vertex Meshes ending in 3-vertex triangles
            for n_quads, n_tris in ((2, 4), (6, 2)):  # 2*4 + 4*3 = 20 verts; 6*4 + 2*3 = 30 verts
                m = buildings.Mesh()
                mat_idx = buildings._Looks(0.25)
                fac_mat = mat_idx["bne_bld_fac_white"]
                for qi in range(n_quads):
                    x = float(qi * 2)
                    m.quad((x, 0.0, 0.0), (x + 2.0, 0.0, 0.0), (x + 2.0, 0.0, 3.0), (x, 0.0, 3.0),
                           (0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0), fac_mat)
                for ti in range(n_tris):
                    x = float(ti * 2)
                    m.tri((x, 0.0, 3.0), (x + 2.0, 0.0, 3.0), (x + 1.0, 0.0, 4.5),
                          (0.0, 0.995), (0.02, 0.995), (0.01, 0.999), fac_mat)
                self.assertEqual(m.n, n_quads * 4 + n_tris * 3)
                sp = buildings.Spec(
                    ring=np.array([[0.0, 0.0], [6.0, 0.0], [6.0, 4.0], [0.0, 4.0]], dtype=np.float64),
                    floors=1, floor_h=3.0, height=3.0, roof="gabled", cls="garage", seed=0.25, min_h=0.0,
                )
                sp.de_in = True
                facade_style.bake_building_depth(m, sp, 0.0, 0.0, 3.0, False, mat_idx)
                P, _uv, T, _M, _C = m.arrays()
                self.assertGreater(len(T), n_quads * 2 + n_tris)
                self.assertTrue(np.isfinite(P).all())

            # 2. Full tile_buildings + build + road_tile with FACADE multi-floor + single-quad STUCCO/PANEL buildings
            r_multi = np.array([[20.0, 20.0], [34.0, 20.0], [34.0, 30.0], [20.0, 30.0]], dtype=np.float64)
            r_stucco = np.array([[50.0, 20.0], [56.0, 20.0], [56.0, 25.0], [50.0, 25.0]], dtype=np.float64)
            r_panel = np.array([[70.0, 20.0], [82.0, 20.0], [82.0, 28.0], [70.0, 28.0]], dtype=np.float64)
            rings = [r_multi, r_stucco, r_panel]
            coords = []
            ring_off = [0]
            part_off = [0]
            for rg in rings:
                la, lo, _ = frame.enu_to_geodetic(rg[:, 0], rg[:, 1], 0.0)
                coords.append(np.column_stack([lo, la]))
                ring_off.append(ring_off[-1] + len(rg))
                part_off.append(part_off[-1] + 1)
            feats = mapgeom.Features(
                layer="building",
                lonlat=np.concatenate(coords),
                coord_off=np.array(ring_off, dtype=np.int64),
                ring_off=np.arange(len(rings) + 1, dtype=np.int64),
                part_off=np.array(part_off, dtype=np.int64),
                kind=np.array([3, 3, 3], dtype=np.int8),
                attrs={
                    "class": np.array(["apartments", "garage", "warehouse"], dtype=object),
                    "roof_shape": np.array(["gabled", "gabled", "flat"], dtype=object),
                    "facade_material": np.array(["plaster", "stucco", "concrete"], dtype=object),
                    "num_floors": np.array([3, 1, 1], dtype=object),
                    "height": np.array([9.0, 3.0, 4.5], dtype=object),
                },
                ids=np.array(["b_multi", "b_stucco", "b_panel"], dtype=object),
            )
            items = buildings.tile_buildings(frame, 0.0, 0.0, 256.0, 256.0, [feats], _flat_elev)
            self.assertEqual(len(items), 3)
            built = buildings.build(items, lite=False)
            self.assertIsNotNone(built)
            P_b, _uv_b, T_b, _M_b, _mats_b, _C_b = built
            self.assertGreater(len(T_b), 0)
            self.assertTrue(np.isfinite(P_b).all())

            proc, custom_entries = buildings.road_tile(
                frame, 0, 0, None, _flat_elev, items=items, custom=[]
            )
            self.assertIsNotNone(proc)
            self.assertEqual(custom_entries, [])
            mesh_parts, _boxes, _col = proc
            self.assertGreater(len(mesh_parts), 0)


class UrbanLifeAndHedgesTest(unittest.TestCase):
    def test_pillar1_high_hedge_coverage_narrow_yards_with_and_without_sidewalk(self):
        frame = geodesy.EnuFrame(*MUNICH)
        box = (0.0, 0.0, 256.0, 256.0)
        # Road 1: residential 6.0 m with sidewalk (outer edge y = 104.2); Road 2: living_street 5.5 m with NO sidewalk.
        road1 = np.array([[10.0, 100.0, 0.0], [246.0, 100.0, 0.0]], dtype=np.float64)
        road2 = np.array([[10.0, 180.0, 0.0], [246.0, 180.0, 0.0]], dtype=np.float64)
        near_roads = [
            ("r_walk", _road_spec("residential", 6.0), road1, MUNICH[1]),
            ("r_nowalk", _road_spec("living_street", 5.5), road2, MUNICH[1]),
        ]
        walks = [{"pts": np.array([[10.0, 103.6, 0.0], [246.0, 103.6, 0.0]]), "side": 1, "w": 1.2}]

        specs = []
        for idx in range(20):
            x_a = 18.0 + idx * 10.5
            # Narrow front yard behind sidewalk: y = 104.7 (0.5 m behind walk_back = 104.2)
            r_w = np.array([[x_a, 104.7], [x_a + 8.0, 104.7], [x_a + 8.0, 113.0], [x_a, 113.0]], dtype=np.float64)
            specs.append((buildings.Spec(ring=r_w, floors=2, floor_h=2.8, height=5.8, roof="gabled", shop=False, cls="terrace", seed=0.03 * (idx + 1), door=(0, 4.0), min_h=0.0), 0.0, 0.0))
        for idx in range(10):
            x_a = 20.0 + idx * 18.0
            # No sidewalk: road edge is at 182.75, wall at 184.0 (1.25 m setback -> >= 0.95 m)
            r_nw = np.array([[x_a, 184.0], [x_a + 9.0, 184.0], [x_a + 9.0, 193.0], [x_a, 193.0]], dtype=np.float64)
            specs.append((buildings.Spec(ring=r_nw, floors=2, floor_h=2.8, height=5.6, roof="flat", shop=False, cls="house", seed=0.05 * (idx + 1), door=(0, 4.5), min_h=0.0), 0.0, 0.0))

        with mock.patch.dict(os.environ, {"BNE_DE_STREET_IMMERSION": "on"}):
            eligible = classifier.classify_residential_yards(specs, frame, 0.0, 0.0)
            self.assertEqual(len(eligible), 30)
            hedge_share = sum(1 for _sp, _rg, st in eligible if st == "hedge") / float(len(eligible))
            self.assertGreaterEqual(hedge_share, 0.50, f"expected >= 50% hedges, got {hedge_share:.2f}")
            rows = placement.place_residential_yards(frame, box, specs, near_roads, walks, [], None, [s[0].ring for s in specs], _flat_ground, md=None)

        self.assertGreaterEqual(len(rows), 60)
        nw_rows = [r for r in rows if float(r[2]) > 180.0]
        self.assertGreater(len(nw_rows), 10, "expected hedges/fences on curbless living_street")
        self.assertTrue(all(float(r[2]) >= 183.15 for r in nw_rows), f"boundary intruded into road: {nw_rows[:5]}")

    def test_pillar2_parked_car_clusters_clearances_and_tram_exclusion(self):
        from de_street_enhancer import parking_de

        frame = geodesy.EnuFrame(*MUNICH)
        box = (0.0, 0.0, 256.0, 256.0)
        # Residential 6.0 m road + crossing road at x=128 + secondary collector with tram track at y=200.
        r_res_w = np.array([[0.0, 100.0, 0.0], [128.0, 100.0, 0.0]], dtype=np.float64)
        r_res_e = np.array([[128.0, 100.0, 0.0], [256.0, 100.0, 0.0]], dtype=np.float64)
        r_cross = np.array([[128.0, 20.0, 0.0], [128.0, 160.0, 0.0]], dtype=np.float64)
        r_tram_sec = np.array([[10.0, 200.0, 0.0], [246.0, 200.0, 0.0]], dtype=np.float64)
        near_roads = [
            ("r_res_w", _road_spec("residential", 6.0), r_res_w, MUNICH[1]),
            ("r_res_e", _road_spec("residential", 6.0), r_res_e, MUNICH[1]),
            ("r_cross", _road_spec("unclassified", 5.5), r_cross, MUNICH[1]),
            ("r_sec_tram", _road_spec("secondary", 8.0), r_tram_sec, MUNICH[1]),
        ]
        walks = [{"fid": "r_res_w", "pts": np.array([[0.0, 103.8, 0.0], [128.0, 103.8, 0.0]]), "side": 1, "w": 1.6}]
        drives = [{"w": 3.0, "n": [[50.0, 112.0, 0.0], [50.0, 103.0, 0.0]]}]
        lot_spot = [[200.0, 50.0, 0.0, 90.0, 1]]

        # Fake infrastructure with a bus_stop at (210, 103) and a tram line along y=200.
        la_bs, lo_bs, _ = frame.enu_to_geodetic(210.0, 103.0, 0.0)
        infra_feats = mapgeom.Features(
            layer="infrastructure",
            lonlat=np.array([[lo_bs, la_bs]], dtype=np.float64),
            coord_off=np.array([0, 1], dtype=np.int64),
            ring_off=np.array([0, 1], dtype=np.int64),
            part_off=np.array([0, 1], dtype=np.int64),
            kind=np.array([1], dtype=np.int8),
            attrs={"class": np.array(["bus_stop"], dtype=object), "tags": np.array(['{"highway":"bus_stop"}'], dtype=object)},
            ids=np.array(["bs1"], dtype=object),
        )
        fake_md = types.SimpleNamespace(
            cell=lambda key, layers=(), kind="demand": types.SimpleNamespace(
                layers={"infrastructure": infra_feats if "infrastructure" in layers else None}
            )
        )
        tram_line = np.array([[10.0, 200.0], [246.0, 200.0]], dtype=np.float64)
        with mock.patch.dict(os.environ, {"BNE_DE_STREET_IMMERSION": "on"}), mock.patch.object(
            parking_de, "_tram_polylines", return_value=[tram_line]
        ):
            out = parking_de.refine_parking_spots(
                fake_md, frame, 0, 0, box, near_roads, walks, [], drives, [], [], lot_spot, _flat_ground
            )

        self.assertIn(lot_spot[0], out)
        curb = [r for r in out if r[4] == 0]
        self.assertGreater(len(curb), 6, f"expected residential curb spots, got {curb}")
        for r in curb:
            x, y = float(r[0]), float(r[1])
            self.assertEqual((r[5], r[6]), (2.05, 5.2))
            self.assertGreaterEqual(math.hypot(x - 128.0, y - 100.0), 10.0 - 1e-6)
            self.assertGreaterEqual(math.hypot(x - 210.0, y - 103.0), 12.0 - 1e-6)
            self.assertGreaterEqual(math.hypot(x - 50.0, y - 103.0), 4.2 - 1e-6)
            self.assertLess(y, 180.0, f"tram-shared secondary collector should have 0 spots: {r}")

    def test_pillar3_bus_stop_micro_props_and_shelter_suppression(self):
        import shelters
        from de_street_enhancer import furniture_de, hooks

        frame = geodesy.EnuFrame(*MUNICH)
        box = (0.0, 0.0, 256.0, 256.0)
        road = np.array([[10.0, 128.0, 0.0], [246.0, 128.0, 0.0]], dtype=np.float64)
        near_roads = [("r_main", _road_spec("tertiary", 7.0), road, MUNICH[1])]
        walks = [{"fid": "r_main", "pts": np.array([[10.0, 132.5, 0.0], [246.0, 132.5, 0.0]]), "side": 1, "w": 2.0}]

        pts_enu = [(80.0, 132.0), (140.0, 133.0), (180.0, 133.0), (210.0, 133.0)]
        lonlat = np.array([frame.enu_to_geodetic(x, y, 0.0)[1::-1] for x, y in pts_enu], dtype=np.float64)
        feats = mapgeom.Features(
            layer="infrastructure",
            lonlat=lonlat,
            coord_off=np.array([0, 1, 2, 3, 4], dtype=np.int64),
            ring_off=np.array([0, 1, 2, 3, 4], dtype=np.int64),
            part_off=np.array([0, 1, 2, 3, 4], dtype=np.int64),
            kind=np.array([1, 1, 1, 1], dtype=np.int8),
            attrs={
                "class": np.array(["bus_stop", "street_cabinet", "parcel_locker", "recycling"], dtype=object),
                "name": np.array(["Rathaus Dortmund", "", "Packstation 112", ""], dtype=object),
                "tags": np.array([
                    '{"highway":"bus_stop","name":"Rathaus Dortmund"}',
                    '{"man_made":"street_cabinet"}',
                    '{"amenity":"parcel_locker"}',
                    '{"amenity":"recycling","recycling_type":"container"}',
                ], dtype=object),
            },
            ids=np.array(["i_bs", "i_cab", "i_lock", "i_rec"], dtype=object),
        )
        fake_md = types.SimpleNamespace(
            cell=lambda key, layers=(), kind="demand": types.SimpleNamespace(
                layers={"infrastructure": feats if "infrastructure" in layers else None}
            )
        )
        with mock.patch.dict(os.environ, {"BNE_DE_STREET_IMMERSION": "on"}):
            # Shelters.rows must suppress duplicate stock busshelter_it inside DE.
            self.assertEqual(shelters.rows(frame, lambda k: feats, box, _flat_elev, near_roads), [])
            props = [["recyclebin", 210.0, 133.0, 0.0, 0.0, 1.0, 1.48, 0.0]]
            with tempfile.TemporaryDirectory() as tmp:
                face, blob, _yards = hooks.build_streets_and_yards(
                    fake_md, frame, 0, 0, box, near_roads, {"r_main": "Gevelsbergstraße"},
                    props, walks, None, [], [], [], _flat_ground, tmp, "/temp/vfs",
                )
                self.assertIsNotNone(face)
                self.assertIsNotNone(blob)
                self.assertEqual(len(face), 1)
                self.assertEqual(props, [], "duplicate generic recyclebin should be replaced by DE Altglascontainer trio")

    def test_pillar4_housenumbers_subslots_canopies_and_balconies(self):
        frame = geodesy.EnuFrame(*MUNICH)
        with mock.patch.dict(os.environ, {"BNE_DE_STREET_IMMERSION": "on"}):
            # Pack 50 unique house numbers in compact 4x2 subslots -> fits in 7 slots (<< 32)
            entries = []
            nums = [f"{i}" for i in range(1, 51)]
            for idx in range(0, len(nums), 8):
                chunk = nums[idx : idx + 8]
                entries.append((f"hngrid|{idx//8}", chunk))
            mat, _dds, _vfs, uv_map, _img = texture_atlas.pack_atlas(
                entries, texture_atlas.render_housenumber_grid, out_dir=None, vfs_dir=None, prefix="sh"
            )
            self.assertIsNotNone(mat)
            self.assertEqual(len(uv_map), 7)

            # Build multi-story residential house with door, canopy, balconies, and explicit addr:housenumber
            ring = np.array([[20.0, 20.0], [32.0, 20.0], [32.0, 30.0], [20.0, 30.0]], dtype=np.float64)
            spec = buildings.Spec(
                ring=ring, floors=3, floor_h=2.9, height=8.7, roof="gabled",
                roof_mat=buildings.ROOF_TILES, facade="bne_bld_fac_white",
                shop=False, cls="apartments", seed=0.25, door=(0, 6.0), min_h=0.0,
                de_in=True, de_hn="48a", de_eaves=(0.45, 0.45, 0.45, 0.45),
            )
            spec.gring = np.zeros(4, dtype=np.float64)
            built = buildings.build([(spec, 0.0, 0.0)], lite=False)
            self.assertIsNotNone(built)
            P, _uv, T, _M, _mats, _C = built
            self.assertTrue(np.isfinite(P).all())
            self.assertGreater(len(T), 0)
            # Canopy/balconies extend beyond y=20.0 outward (-Y on edge 0)
            self.assertLess(float(P[:, 1].min()), 19.3, "expected upper-floor balcony & canopy to extend outward")

            # Residential-only tile with 0 shops still emits deshops.cdae with house numbers (non-emissive)
            with tempfile.TemporaryDirectory() as tmp:
                empty_md = types.SimpleNamespace(cell=lambda k, layers=(), kind="demand": types.SimpleNamespace(layers={}))
                sf, sb, _sup = de_enhancer.prepare_shops(empty_md, frame, 0, 0, [(spec, 0.0, 0.0)], tmp, "/temp/v")
                self.assertIsNotNone(sf)
                self.assertIsNotNone(sb)
                self.assertFalse(next(iter(sf.values()))["emissive"])


if __name__ == "__main__":
    unittest.main()

