"""Offline unit & integration tests for the Germany (DE) Street-Level Immersion Enhancer."""

import os
os.environ.setdefault(
    "BNE_REGIONAL_DIR",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures", "regional"),
)

from pathlib import Path
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


if __name__ == "__main__":
    unittest.main()
