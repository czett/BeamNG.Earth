"""Tests for high-speed highway and bridge streaming (speed > 28 m/s, ROADMAP #13)."""
import asyncio
import math
import os
import sys
import tempfile
import threading
import time
import types
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import areas  # noqa: E402
import blockworker  # noqa: E402
import de_enhancer  # noqa: E402
import deckspans  # noqa: E402
import earthd  # noqa: E402
import geodesy  # noqa: E402
import geotiles  # noqa: E402
import mapcells  # noqa: E402
import pools  # noqa: E402
import reach  # noqa: E402
import revisit  # noqa: E402
import roads  # noqa: E402
import surface  # noqa: E402


class _FakeConn:
    def __init__(self, road_workers=4):
        self.sent = []
        self.s = types.SimpleNamespace(
            out_dir=None,
            pool_shapes=None,
            road_pool=types.SimpleNamespace(workers=road_workers),
        )

    def send(self, m):
        self.sent.append(m)


class _SyncLoop:
    """Minimal loop supporting run_in_executor and call_soon_threadsafe."""
    def __init__(self):
        self.jobs = []
        self.callbacks = []

    def run_in_executor(self, pool, fn, *args):
        from concurrent.futures import Future
        fut = Future()
        self.jobs.append((fut, fn, args))
        getattr(self, "pools", None) is not None and self.pools.append(pool)
        return fut

    def call_soon_threadsafe(self, cb, *args):
        self.callbacks.append((cb, args))

    def drain_callbacks(self):
        while self.callbacks:
            cb, args = self.callbacks.pop(0)
            cb(*args)


class HighwayLookaheadTest(unittest.TestCase):
    def test_geo_wanted_preserves_normal_speed_and_focuses_corridor_at_highway_speed(self):
        frame = geodesy.EnuFrame(47.855, 11.405)
        # Normal speed (20 m/s <= 28 m/s): full SEND_M disc
        low = roads.geo_wanted(frame, 0.0, 0.0, 0.0, -20.0)
        # Highway speed (55 m/s > 28 m/s): shrunk 360-deg disc + extended forward corridor
        high = roads.geo_wanted(frame, 0.0, 0.0, 0.0, -55.0)
        self.assertGreater(len(high), 0)

        def split_tiles(gw):
            fwd = side = behind = 0
            for gx, gy in gw:
                q = geotiles.quad(frame, gx, gy)
                cx, cy = float(q[:, 0].mean()), float(q[:, 1].mean())
                along = -cy  # moving south (-y)
                lat = abs(cx)
                if along < -roads.TILE:
                    behind += 1
                elif lat > 250.0:
                    side += 1
                else:
                    fwd += 1
            return fwd, side, behind

        lf, ls, lb = split_tiles(low)
        hf, hs, hb = split_tiles(high)
        # At 55 m/s, far more forward corridor tiles and far fewer side/behind tiles than 360-deg SEND_M
        self.assertGreater(hf, lf)
        self.assertLess(hs + hb, ls + lb)

    def test_ground_busy_keeps_forward_corridor_and_deck_first_at_highway_speed(self):
        frame = geodesy.EnuFrame(47.855, 11.405)
        tr = roads.GeoTracker()
        conn = _FakeConn(road_workers=4)
        loop = _SyncLoop()
        # Pick a forward tile ~900 m ahead (beyond SEND_M=640 m) and a bridge tile ~1100 m ahead
        fwd_key = geotiles.tile_of(*frame.enu_to_geodetic(0.0, -900.0, 0.0)[:2])
        deck_key = geotiles.tile_of(*frame.enu_to_geodetic(0.0, -1100.0, 0.0)[:2])
        tr.deck_first = {deck_key}
        tr.on_pose(conn, 1, 0.0, 0.0, loop, lambda *a: None, vel=(0.0, -55.0), ground_busy=True, frame=frame)
        queued_keys = {args[1:3] for _, _, args in loop.jobs}
        # First round dispatches up to limit (8), verify deck_key is first and forward corridor >640m is eligible
        self.assertIn(deck_key, queued_keys)
        pending_keys = {j[0] for j in tr._pending[0]}
        self.assertIn(fwd_key, queued_keys | pending_keys)

    def test_continuous_refill_on_built(self):
        frame = geodesy.EnuFrame(47.855, 11.405)
        tr = roads.GeoTracker()
        conn = _FakeConn(road_workers=4)
        loop = _SyncLoop()
        tr.on_pose(conn, 1, 0.0, 0.0, loop, lambda *a: None, vel=(0.0, -55.0), ground_busy=False, frame=frame)
        initial_n = len(loop.jobs)
        self.assertEqual(initial_n, roads.BUILD_PER_POSE_FAST)
        self.assertGreater(len(tr._pending[0]), 0)
        # Complete one job -> _built schedules _dispatch_pending via call_soon_threadsafe
        fut, _, _ = loop.jobs.pop(0)
        fut.set_result(None)
        loop.drain_callbacks()
        self.assertEqual(len(loop.jobs), initial_n)  # refilled back to limit immediately


class ReachOrderingTest(unittest.TestCase):
    def test_horizon_scales_with_highway_speed(self):
        self.assertAlmostEqual(reach.horizon_s(20.0), max(reach.HORIZON_S, reach.HORIZON_MIN_M / 20.0))
        self.assertAlmostEqual(reach.horizon_s(55.0), reach.HORIZON_S_FAST)
        self.assertAlmostEqual(reach.horizon_s(134.0), reach.HORIZON_MAX_M / 134.0)

    def test_order_key_protects_near_forward_tiles_from_late_keep_inversion(self):
        # With elevated build_s=8.0s at 55 m/s, a tile 150m ahead (eta=2.7s) must still beat a 1500m tile (eta=27s)
        near_k = reach.order_key(2.7, 1.0, 10.0, 55.0, 8.0)
        far_k = reach.order_key(27.0, 1.0, 10.0, 55.0, 8.0)
        self.assertLess(near_k, far_k)


class PoolPriorityTest(unittest.TestCase):
    def test_low_cooldown_reserves_half_workers_and_pause_low_blocks(self):
        p = pools.RespawningPool.__new__(pools.RespawningPool)
        p.workers = 4
        p.inflight = 2
        p._low = [1]
        p._low_active = 1
        p._low_pauses = set()
        p._low_cv = threading.Condition()
        p._last_high_at = time.monotonic()
        p.LOW_COOLDOWN_S = 1.0
        # 2 of 4 workers busy and high-priority submit was recent -> reserve half (2) workers
        self.assertFalse(p._low_can_run())
        p.inflight = 1
        self.assertTrue(p._low_can_run())
        p.pause_low("hw")
        self.assertFalse(p._low_can_run())
        p.resume_low("hw")
        self.assertTrue(p._low_can_run())


class Phase2StreamingTest(unittest.TestCase):
    def test_follow_rule_prep_ahead_scales_at_highway_speeds(self):
        rule = earthd.FOLLOW_RULES[1024.0]
        self.assertEqual(rule.prep_ahead(25.0, 0.0), 0.0)
        # 45 m/s (162 km/h): ~14 s edge lead -> > 5 s ahead
        self.assertGreater(rule.prep_ahead(45.0, 0.0), 5.0)
        # 67 m/s (241 km/h): capped at prep_ahead_max_m / speed (~3.82 s)
        self.assertAlmostEqual(rule.prep_ahead(67.0, 0.0), rule.prep_ahead_max_m / 67.0, places=5)

    def test_photo_surface_miss_does_not_taint_grading_revisit_scope(self):
        # Simulate missing photo surface during grading: outer revisit.scope stays clean (persist=True),
        # while _road_specs_kept still detects photo miss via _PHOTO_MISS_TL so partial specs aren't stored.
        with revisit.scope() as b:
            m0 = getattr(roads._PHOTO_MISS_TL, "count", 0)
            with roads.suppress_photo_faults():
                roads._note_photo_miss()
            self.assertEqual(b.n, 0)
            self.assertGreater(getattr(roads._PHOTO_MISS_TL, "count", 0), m0)

    def test_far_limit_throttles_when_highway_terrain_waits(self):
        with tempfile.TemporaryDirectory() as tmp:
            s = earthd.Server(tmp, os.path.join(tmp, "cache"), imagery=None, road_pool=None, tile_workers=3)
            try:
                s.speed = 55.0

                class _Conn:
                    map_view = False
                    map_open = False
                    terrain_wait = 1

                conn = _Conn()
                s.connections.add(conn)
                self.assertEqual(s.far_limit(), 1)
                conn.terrain_wait = 0
                self.assertEqual(s.far_limit(), s.far_drive)
            finally:
                s.hm_pool.shutdown(wait=True)
                s.tile_pool.shutdown(wait=True)

    def test_areas_world_phase_includes_roadsurf_and_plan_when_supported(self):
        class _FakeSrv:
            grading = True
            surface = True
            gas_stations = False
            mapdata = object()
            road_pool = None
            fast_pool = None

            def plan_prebuilt(self, z, x, y):
                return False

            def prebuild_plan(self, z, x, y):
                return True

            def roadsurf_prebuilt(self, z, x, y):
                return False

            def prebuild_roadsurf(self, z, x, y):
                return 1

            def geo_prebuilt(self, gx, gy):
                return None

            def prebuild_geo(self, gx, gy):
                return "k"

        with tempfile.TemporaryDirectory() as tmp:
            a = areas.Areas(tmp, _FakeSrv())
            steps = a.phase_steps("world", (47.74, 11.33, 47.77, 11.36))
            kinds = [st[0] for st in steps]
            self.assertIn("roadsurf", kinds)
            self.assertIn("plan", kinds)
            self.assertLess(kinds.index("roadsurf"), kinds.index("geo"))
            self.assertLess(kinds.index("plan"), kinds.index("geo"))


class WarmRoadsAndDeckSpansTest(unittest.TestCase):
    def test_warm_roads_projects_further_ahead_at_highway_speed(self):
        with tempfile.TemporaryDirectory() as tmp:
            s = earthd.Server(tmp, os.path.join(tmp, "cache"), imagery=None, road_pool=None, grading=True)
            try:
                anchor = s.new_anchor(47.855, 11.405)
                captured = []

                class _FakeQ:
                    def put_nowait(self, item):
                        captured.append(item)

                s.block_pools = [(None, _FakeQ())]
                # Mock grader so no real mapdata/DEM is needed
                fake_grader = types.SimpleNamespace(shared=None, planned=lambda k: False, warm=lambda k: None)
                with mock.patch.object(s, "grader_for", return_value=fake_grader):
                    s.warm_roads(anchor, 0.0, 0.0, 0.0, -55.0)
                self.assertEqual(len(captured), 1)
                keys = captured[0][3]
                # Farthest warmed cell along -y should be ~3.3 km (60 s * 55 m/s) ahead, well past 2.0 km WARM_AROUND
                dists = []
                for k in keys:
                    cla, clo = k.center()
                    cx, cy, _ = anchor.frame.geodetic_to_enu(cla, clo, 0.0)
                    dists.append(-float(cy))
                self.assertGreater(max(dists), 2800.0)
            finally:
                s.hm_pool.shutdown(wait=True)
                s.tile_pool.shutdown(wait=True)

    def test_deckspans_accepts_speed_scaled_radius(self):
        frame = geodesy.EnuFrame(47.855, 11.405)
        import numpy as np
        pieces = [("1", np.array([[0.0, 1500.0], [0.0, 1600.0]]))]
        msg_default = deckspans.message(1, 0.0, 0.0, pieces, radius=deckspans.RADIUS_M)
        msg_fast = deckspans.message(1, 0.0, 0.0, pieces, radius=1800.0)
        self.assertEqual(len(msg_default["spans"]), 0)
        self.assertEqual(len(msg_fast["spans"]), 1)

    def test_far_limit_does_not_bypass_throttle_via_boost_on_at_highway_speed(self):
        with tempfile.TemporaryDirectory() as tmp:
            s = earthd.Server(tmp, os.path.join(tmp, "cache"), imagery=None, road_pool=None, grading=False)
            try:
                s.far_drive = 3
                s.far_max = 8
                s.boost_on = True
                s.speed = earthd.HIGH_SPEED_WARM_V + 10.0
                s.hm_inflight = {("a", 0, 0): object()}
                self.assertEqual(s.far_limit(), 1)
                s.hm_inflight = {}
                self.assertEqual(s.far_limit(), 8)
            finally:
                s.hm_pool.shutdown(wait=True)
                s.tile_pool.shutdown(wait=True)

    def test_base_refresh_skips_at_highway_speed(self):
        s = types.SimpleNamespace(
            base_stale={(1, 0.0, 0.0)},
            imagery=object(),
            near_visual="detail",
            anchors={1: object()},
            layout=types.SimpleNamespace(block=512),
        )
        c = earthd.Connection.__new__(earthd.Connection)
        c.s = s
        c.base_busy = False
        c.vel = (0.0, -44.4)
        c.spawn = mock.Mock()
        c.base_refresh(1)
        c.spawn.assert_not_called()

    def test_quick_elsewhere_keeps_road_paint_at_highway_speed(self):
        with tempfile.TemporaryDirectory() as tmp:
            s = earthd.Server(tmp, os.path.join(tmp, "cache"), imagery=None, road_pool=None, grading=False)
            try:
                anchor = s.new_anchor(47.855, 11.405)
                s.imagery = types.SimpleNamespace(chain=[], tone=None, leaf_on=True, season_mode="auto")
                s.speed = earthd.HIGH_SPEED_WARM_V + 10.0
                captured = {}

                class _FakePool:
                    def submit(self, fn, *args, **kwargs):
                        captured["kwargs"] = kwargs
                        from concurrent.futures import Future
                        f = Future()
                        f.set_result((None, {}, set()))
                        return f

                s.block_pools = [(_FakePool(), None)]
                s._quick_elsewhere(anchor, 0.0, 0.0, 0)
                self.assertFalse(captured["kwargs"]["skip_roads"])
            finally:
                s.hm_pool.shutdown(wait=True)
                s.tile_pool.shutdown(wait=True)


class FastLaneAndGermanyCacheTest(unittest.TestCase):
    def test_geo_content_key_fast_lane_and_de_fast_isolation(self):
        with tempfile.TemporaryDirectory() as tmp:
            blockworker._s = types.SimpleNamespace(
                md=None, cache_dir=tmp, surface=None, widths=None, sea=None,
                airports=None, grading=False, dem=None,
            )
            gx, gy = geotiles.tile_of(48.137, 11.575)
            key = geotiles.key(gx, gy)
            k_full = blockworker._geo_content_key(key, 15, True, False, True, False, 0.0, None, "DE", models_dir=tmp)
            k_fast = blockworker._geo_content_key(key, 15, True, False, True, False, 0.0, None, "DE", models_dir=tmp, fast_lane=True)
            k_de_fast = blockworker._geo_content_key(key, 15, True, False, True, False, 0.0, None, "DE", models_dir=tmp, de_fast=True)
            k_both = blockworker._geo_content_key(key, 15, True, False, True, False, 0.0, None, "DE", models_dir=tmp, fast_lane=True, de_fast=True)
            self.assertNotEqual(k_full, k_fast)
            self.assertNotEqual(k_full, k_de_fast)
            self.assertNotEqual(k_fast, k_de_fast)
            self.assertEqual(k_both, k_fast)

    def test_geo_content_stores_fast_tiles_separately_and_reads_full_cache_first(self):
        import numpy as np
        with tempfile.TemporaryDirectory() as cache, tempfile.TemporaryDirectory() as out:
            blockworker._s = types.SimpleNamespace(
                md=None, cache_dir=cache, surface=None, widths=None, sea=None,
                airports=None, grading=False, dem=None,
            )
            gx, gy = geotiles.tile_of(48.137, 11.575)
            tile = geotiles.geobox(gx, gy)
            names = blockworker.geo_names(tile.key)

            def fake_tile_parts(mark, frame, tile_, zoom, g, buildings, left_hand, mph, gas_stations,
                                buried, lamp_region, country, q, rkey, centre, skin_margin=0.0,
                                walks_raw=None, cache_dir=None, out_dir=None, vfs_dir=None,
                                pole_profile=None, de_junctions=False, towns_on=False, wear=None,
                                de_detail=None, fast_lane=False):
                p = blockworker._Parts()
                p.chunks, p.ctx, p.walks, p.box, p.origin = [], [], [], tile_.box, (0.0, 0.0, 0.0)
                p.custom, p.custom_entries = [], []
                p.bld, p.props, p.wires, p.park, p.fuel, p.fuel_pads = None, [], [], [], [], []
                p.fuel_tried = []
                p.guardrail_rows, p.garage_sound, p.wells = [], (), []
                p.barrier_mesh, p.barrier_chunks = None, ()
                p.dmesh = p.tmesh = p.rmesh = None
                p.signs, p.town_faces, p.speed_traps = None, {}, []
                p.bus_col, p.turbines, p.scene = None, [], None
                p.de_streets = p.de_shops = p.de_faces = None
                p.de_speed_cameras, p.de_roadworks = [], []
                p.walks_raw = walks_raw or []
                return p

            def fake_write_geo(out_d, vfs_d, tile_, P):
                jpath = os.path.join(out_d, names["json"])
                blockworker._write_bytes(jpath, b'{"chunks":[]}')
                blockworker._write_bytes(os.path.join(out_d, names["inputs"]), b"inputs")
                return f"{vfs_d}/{names['json']}", 0, {"h": "fast_h" if calls[-1] else "full_h", "parts": {}}

            calls = []
            with mock.patch.object(de_enhancer, "enabled", return_value=True), \
                    mock.patch.object(de_enhancer, "in_germany", return_value=True), \
                    mock.patch.object(blockworker, "_tile_parts", side_effect=lambda *a, **kw: (calls.append(kw.get("fast_lane", False)), fake_tile_parts(*a, **kw))[1]), \
                    mock.patch.object(blockworker, "_write_geo_content", side_effect=fake_write_geo), \
                    mock.patch.object(revisit, "ON", True):
                # 1. Build with de_detail fast=True & fast_lane=True -> stores under fast key
                r1 = blockworker._geo_content(gx, gy, 15, out, "/v", True, False, True, False, 0.0, None, "DE",
                                              de_detail={"level": "medium", "fast": True}, fast_lane=True)
                self.assertEqual(r1[2]["h"], "fast_h")
                self.assertEqual(calls, [True])

                # 2. Revisit with fast_lane=True -> hits fast cache without rebuilding!
                r2 = blockworker._geo_content(gx, gy, 15, out, "/v", True, False, True, False, 0.0, None, "DE",
                                              de_detail={"level": "medium", "fast": True}, fast_lane=True)
                self.assertEqual(r2[2]["h"], "fast_h")
                self.assertEqual(calls, [True])

                # 3. Build full-detail (fast_lane=False, fast=False) -> does NOT collide with fast key, builds full & stores
                r3 = blockworker._geo_content(gx, gy, 15, out, "/v", True, False, True, False, 0.0, None, "DE",
                                              de_detail="medium", fast_lane=False)
                self.assertEqual(r3[2]["h"], "full_h")
                self.assertEqual(calls, [True, False])

                # 4. Now ask again with fast_lane=True & de_fast=True -> full-detail cache checked first, returns full_h!
                r4 = blockworker._geo_content(gx, gy, 15, out, "/v", True, False, True, False, 0.0, None, "DE",
                                              de_detail={"level": "medium", "fast": True}, fast_lane=True)
                self.assertEqual(r4[2]["h"], "full_h")
                self.assertEqual(calls, [True, False])


class GeoTrackerFastLaneTest(unittest.TestCase):
    def test_fast_lane_above_high_speed_and_deferred_scenery_upgrade(self):
        frame = geodesy.EnuFrame(47.855, 11.405)
        tr = roads.GeoTracker()
        conn = _FakeConn(road_workers=4)
        loop = _SyncLoop()
        recorded = []

        def build(aid, gx, gy, content, skin, exact, fast_lane=False, low_prio=False):
            recorded.append((gx, gy, content, skin, exact, fast_lane, low_prio))
            return {"content": (f"/v/rg_{gx}_{gy}.json", 1, {"h": f"h_{fast_lane}", "parts": {}}, []),
                    "skin": (f"/v/rs_{gx}_{gy}.json", {"h": "s1"}), "exact": {}}

        # High speed (> HIGH_SPEED_MS): new tiles get fast_lane=True, low_prio=False
        tr.on_pose(conn, 1, 0.0, 0.0, loop, build, vel=(0.0, -55.0), ground_busy=False, frame=frame)
        self.assertGreater(len(loop.jobs), 0)
        for _fut, _fn, args in loop.jobs:
            self.assertEqual(len(args), 8)
            self.assertTrue(args[6])   # fast_lane=True
            self.assertFalse(args[7])  # low_prio=False
        # Drain initial and refilled high-speed jobs
        while loop.jobs:
            fut, fn, args = loop.jobs.pop(0)
            self.assertTrue(args[6])   # fast_lane=True
            self.assertFalse(args[7])  # low_prio=False
            fut.set_result(fn(*args))
            loop.drain_callbacks()

        self.assertGreater(len(tr.fast_sent), 0)
        fast_sent_snapshot = set(tr.fast_sent)

        # Slow down (<= HIGH_SPEED_MS): fast_sent tiles within SEND_M get deferred low_prio scenery upgrade
        # (after any newly-wanted 360-deg disc tiles behind/beside the car)
        recorded.clear()
        tr.on_pose(conn, 1, 0.0, 0.0, loop, build, vel=(0.0, -5.0), ground_busy=False, frame=frame)
        self.assertGreater(len(loop.jobs) + len(tr._pending[0]), 0)
        low_prio_seen = False
        upgrade_keys = set()
        while loop.jobs:
            fut, fn, args = loop.jobs.pop(0)
            is_low = args[7]
            if is_low:
                low_prio_seen = True
                self.assertTrue(args[3])            # content=True
                self.assertTrue(args[4])            # skin=True
                self.assertEqual(args[5], "auto")   # exact="auto"
                self.assertFalse(args[6])           # fast_lane=False
                upgrade_keys.add((args[1], args[2]))
            else:
                # High-prio jobs (newly wanted behind/beside tiles) must always precede low_prio upgrades
                self.assertFalse(low_prio_seen)
            fut.set_result(fn(*args))
            loop.drain_callbacks()

        self.assertTrue(low_prio_seen)
        self.assertGreater(len(upgrade_keys & fast_sent_snapshot), 0)
        # Upgraded tiles should be removed from fast_sent
        self.assertEqual(len(upgrade_keys & tr.fast_sent), 0)
        tr.close()

    def test_deferred_upgrade_hash_unchanged_skips_resend_and_hash_changed_resends_skin(self):
        frame = geodesy.EnuFrame(47.855, 11.405)
        tr = roads.GeoTracker()
        conn = _FakeConn(road_workers=4)
        loop = _SyncLoop()
        loop.pools = []
        changed_tiles = set()

        def build(aid, gx, gy, content, skin, exact, fast_lane=False, low_prio=False):
            h = f"h_{gx}_{gy}_full" if (not fast_lane and (gx, gy) in changed_tiles) else f"h_{gx}_{gy}_same"
            return {"content": (f"/v/rg_{gx}_{gy}.json", 1, {"h": h, "parts": {}}, []),
                    "skin": (f"/v/rs_{gx}_{gy}.json", {"h": "s_same"}), "exact": {}}

        # Drive at high speed -> sends fast_lane tiles
        tr.on_pose(conn, 1, 0.0, 0.0, loop, build, vel=(0.0, -55.0), ground_busy=False, frame=frame)
        while loop.jobs:
            fut, fn, args = loop.jobs.pop(0)
            fut.set_result(fn(*args))
            loop.drain_callbacks()

        fast_keys = sorted(tr.fast_sent)
        self.assertGreaterEqual(len(fast_keys), 2)
        changed_key = fast_keys[0]
        unchanged_key = fast_keys[1]
        changed_tiles.add(changed_key)
        # Also mark unchanged_key in redo to confirm redo is discarded when hash matches
        tr.redo.add(unchanged_key)
        conn.sent.clear()
        loop.pools.clear()

        # Slow down -> upgrades fast_sent tiles with skin=True, exact="auto" on low_pool
        tr.on_pose(conn, 1, 0.0, 0.0, loop, build, vel=(0.0, -5.0), ground_busy=False, frame=frame)
        while loop.jobs:
            fut, fn, args = loop.jobs.pop(0)
            pool_used = loop.pools.pop(0)
            if args[7]:
                self.assertIs(pool_used, tr.low_pool)
                self.assertTrue(args[4])
                self.assertEqual(args[5], "auto")
            else:
                self.assertIs(pool_used, tr.pool)
            fut.set_result(fn(*args))
            loop.drain_callbacks()

        changed_gkey = geotiles.key(*changed_key)
        unchanged_gkey = geotiles.key(*unchanged_key)
        changed_msgs = [m["type"] for m in conn.sent if m.get("key") == changed_gkey]
        unchanged_msgs = [m["type"] for m in conn.sent if m.get("key") == unchanged_gkey]
        # Changed tile: roads_tile AND roads_skin MUST be sent even though skin hash "s_same" matched
        self.assertEqual(changed_msgs, ["roads_tile", "roads_skin"])
        # Unchanged tile: neither roads_tile nor roads_skin is resent, and removed from fast_sent & redo
        self.assertEqual(unchanged_msgs, [])
        self.assertNotIn(unchanged_key, tr.fast_sent)
        self.assertNotIn(unchanged_key, tr.redo)
        tr.close()

    def test_low_pool_isolation_prevents_deadlock_with_high_priority_pool(self):
        frame = geodesy.EnuFrame(47.855, 11.405)
        tr = roads.GeoTracker()
        self.assertEqual(tr.pool._max_workers, roads.BUILD_PER_POSE_FAST)
        self.assertEqual(tr.low_pool._max_workers, 2)
        conn = _FakeConn(road_workers=4)
        loop = asyncio.new_event_loop()
        try:
            low_entered = threading.Event()
            release_low = threading.Event()
            hi_done = []

            def build(aid, gx, gy, content, skin, exact, fast_lane=False, low_prio=False):
                if low_prio:
                    low_entered.set()
                    release_low.wait(timeout=5.0)
                else:
                    hi_done.append((gx, gy))
                return {"content": (f"/v/rg_{gx}_{gy}.json", 1, {"h": f"h_{fast_lane}", "parts": {}}, []),
                        "skin": (f"/v/rs_{gx}_{gy}.json", {"h": "s1"}), "exact": {}}

            # Seed fast_sent directly so low_prio upgrade jobs dispatch on low_pool
            near_keys = [k[:2] for k in geotiles.tiles_near(frame, 0.0, 0.0, 300.0)]
            self.assertGreaterEqual(len(near_keys), 3)
            tr.aid = 1
            tr.frame = frame
            tr.frames[1] = frame
            for k in near_keys[:3]:
                tr.sent.add(k)
                tr.skins.add(k)
                tr.fast_sent.add(k)
                tr.info[k] = {"h": "h_True", "parts": {}}

            async def run_test():
                # 1. Start slow pose -> dispatches at most 2 low_prio jobs on low_pool (which block on release_low)
                tr.on_pose(conn, 1, 0.0, 0.0, loop, build, vel=(0.0, -5.0), ground_busy=False, frame=frame)
                await asyncio.to_thread(low_entered.wait, 2.0)
                self.assertEqual(len(tr.building_low), 2)
                # 2. High-speed pose introduces new unbuilt tiles -> must run on self.pool without waiting for low_pool
                tr.on_pose(conn, 1, 0.0, -400.0, loop, build, vel=(0.0, -55.0), ground_busy=False, frame=frame)
                hi_futs = [f for k, f in tr.futs.items() if k not in tr.building_low]
                self.assertGreater(len(hi_futs), 0)
                await asyncio.wait_for(asyncio.gather(*hi_futs), timeout=3.0)
                self.assertGreater(len(hi_done), 0)
                release_low.set()
                remaining = list(tr.futs.values())
                if remaining:
                    await asyncio.wait_for(asyncio.gather(*remaining), timeout=3.0)

            loop.run_until_complete(run_test())
        finally:
            release_low.set()
            tr.close()
            loop.close()

    def test_roads_geo_fast_lane_hitting_full_cache_reuses_full_rskin_entry(self):
        with tempfile.TemporaryDirectory() as cache, tempfile.TemporaryDirectory() as out:
            blockworker._s = types.SimpleNamespace(
                md=None, cache_dir=cache, surface=None, widths=None, sea=None,
                airports=None, grading=False, dem=None,
            )
            gx, gy = geotiles.tile_of(48.137, 11.575)
            tile = geotiles.geobox(gx, gy)
            names = blockworker.geo_names(tile.key)

            def fake_tile_parts(mark, frame, tile_, zoom, g, buildings, left_hand, mph, gas_stations,
                                buried, lamp_region, country, q, rkey, centre, skin_margin=0.0,
                                walks_raw=None, cache_dir=None, out_dir=None, vfs_dir=None,
                                pole_profile=None, de_junctions=False, towns_on=False, wear=None,
                                de_detail=None, fast_lane=False):
                p = blockworker._Parts()
                p.chunks, p.ctx, p.walks, p.box, p.origin = [], [], [], tile_.box, (0.0, 0.0, 0.0)
                p.custom, p.custom_entries = [], []
                p.bld, p.props, p.wires, p.park, p.fuel, p.fuel_pads = None, [], [], [], [], []
                p.fuel_tried = []
                p.guardrail_rows, p.garage_sound, p.wells = [], (), []
                p.barrier_mesh, p.barrier_chunks = None, ()
                p.dmesh = p.tmesh = p.rmesh = None
                p.signs, p.town_faces, p.speed_traps = None, {}, []
                p.bus_col, p.turbines, p.scene = None, [], None
                p.de_streets = p.de_shops = p.de_faces = None
                p.de_speed_cameras, p.de_roadworks = [], []
                p.walks_raw = walks_raw or []
                return p

            def fake_write_geo(out_d, vfs_d, tile_, P):
                blockworker._write_bytes(os.path.join(out_d, names["json"]), b'{"chunks":[]}')
                blockworker._write_bytes(os.path.join(out_d, names["inputs"]), b"inputs")
                return f"{vfs_d}/{names['json']}", 0, {"h": "full_h", "parts": {}}

            skin_ckeys = []
            with mock.patch.object(de_enhancer, "enabled", return_value=True), \
                    mock.patch.object(de_enhancer, "in_germany", return_value=True), \
                    mock.patch.object(blockworker, "_tile_parts", side_effect=fake_tile_parts), \
                    mock.patch.object(blockworker, "_write_geo_content", side_effect=fake_write_geo), \
                    mock.patch.object(blockworker, "_geo_skin", side_effect=lambda *a: (skin_ckeys.append(a[-1]), ("/v/rs.json", {"h": "s1"}))[1]), \
                    mock.patch.object(revisit, "ON", True):
                full_ckey = blockworker._geo_content_key(
                    tile.key, 15, True, False, True, False, 0.0, None, "DE",
                    models_dir=os.path.dirname(out), de_detail="medium", fast_lane=False, de_fast=False,
                )
                # Seed full-detail cache first
                blockworker.roads_geo(
                    1, 48.137, 11.575, 15, gx, gy, 15, out, "/v", True, 0.0, True, False, True, 0.0,
                    False, 0.0, None, "DE", content=True, skin=True, de_detail="medium", fast_lane=False,
                )
                # Fast-lane request hits full-detail roadsg cache -> must pass full_ckey to _geo_skin
                blockworker.roads_geo(
                    1, 48.137, 11.575, 15, gx, gy, 15, out, "/v", True, 0.0, True, False, True, 0.0,
                    False, 0.0, None, "DE", content=True, skin=True,
                    de_detail={"level": "medium", "fast": True}, fast_lane=True,
                )
                self.assertEqual(skin_ckeys, [full_ckey, full_ckey])

    def test_six_arg_build_test_double_remains_compatible(self):
        frame = geodesy.EnuFrame(47.855, 11.405)
        tr = roads.GeoTracker()
        conn = _FakeConn(road_workers=4)
        loop = _SyncLoop()

        def six_arg_build(aid, gx, gy, content, skin, exact):
            return None

        tr.on_pose(conn, 1, 0.0, 0.0, loop, six_arg_build, vel=(0.0, -55.0), ground_busy=False, frame=frame)
        self.assertGreater(len(loop.jobs), 0)
        for fut, fn, args in loop.jobs:
            self.assertEqual(len(args), 6)
            fut.set_result(fn(*args))


class PoolHysteresisAndRoutingTest(unittest.TestCase):
    def test_resume_low_hysteresis_blocks_for_duration(self):
        p = pools.RespawningPool.__new__(pools.RespawningPool)
        p.workers = 4
        p.inflight = 0
        p._low = [1]
        p._low_active = 0
        p._low_pauses = set()
        p._low_resume_at = 0.0
        p._low_cv = threading.Condition()
        p._last_high_at = 0.0
        p.LOW_COOLDOWN_S = 1.0
        self.assertEqual(p.PAUSE_HYSTERESIS_S, 1.5)

        p.pause_low("hw")
        self.assertFalse(p._low_can_run())
        p.resume_low("hw", hysteresis_s=0.25)
        # Immediately after resume_low, hysteresis still blocks _low_can_run
        self.assertFalse(p._low_can_run())
        # Repeated resume_low when already unpaused must NOT extend hysteresis
        prev_resume_at = p._low_resume_at
        p.resume_low("hw", hysteresis_s=5.0)
        self.assertEqual(p._low_resume_at, prev_resume_at)
        time.sleep(0.3)
        self.assertTrue(p._low_can_run())

    def test_is_low_paused_is_thread_safe_and_matches_prefixes(self):
        p = pools.RespawningPool.__new__(pools.RespawningPool)
        p._low_pauses = set()
        p._low_cv = threading.Condition()

        self.assertFalse(p.is_low_paused())
        self.assertFalse(p.is_low_paused("hw"))
        p.pause_low(("hw", 123))
        self.assertTrue(p.is_low_paused())
        self.assertTrue(p.is_low_paused("hw"))
        self.assertFalse(p.is_low_paused("other"))
        p.resume_low(("hw", 123))
        self.assertFalse(p.is_low_paused("hw"))
        p.pause_low("hw")
        self.assertTrue(p.is_low_paused("hw"))

        # Concurrent pause/resume alongside is_low_paused must never raise RuntimeError
        stop = threading.Event()
        errors = []

        def mutator():
            try:
                i = 0
                while not stop.is_set():
                    k = ("hw", i % 16)
                    p.pause_low(k)
                    p.resume_low(k)
                    i += 1
            except Exception as ex:
                errors.append(ex)

        t = threading.Thread(target=mutator, daemon=True)
        t.start()
        try:
            for _ in range(500):
                p.is_low_paused("hw")
        finally:
            stop.set()
            t.join(timeout=2.0)
        self.assertEqual(errors, [])

    def test_road_pool_fast_busy_routes_secondary_work_to_submit_low(self):
        with tempfile.TemporaryDirectory() as tmp:
            s = earthd.Server(tmp, os.path.join(tmp, "cache"), imagery=None, road_pool=None, grading=True)
            try:
                anchor = s.new_anchor(47.855, 11.405)
                s.anchors[anchor.id] = anchor
                s.speed = earthd.HIGH_SPEED_WARM_V + 15.0
                s.mapdata = types.SimpleNamespace(highway_signs=types.SimpleNamespace(version=lambda: 1))
                class _Conn:
                    roads = types.SimpleNamespace(building={(0, 0)}, building_low=set(), deck_first=set())

                conn = _Conn()
                s.connections.add(conn)
                self.assertTrue(s._road_pool_fast_busy())

                class _PoolSpy:
                    def __init__(self, result):
                        self.calls = []
                        self._res = result

                    def submit(self, fn, *args, **kwargs):
                        self.calls.append(("submit", fn, args))
                        from concurrent.futures import Future
                        f = Future()
                        f.set_result(self._res)
                        return f

                    def submit_low(self, fn, *args, **kwargs):
                        self.calls.append(("submit_low", fn, args))
                        from concurrent.futures import Future
                        f = Future()
                        f.set_result(self._res)
                        return f

                s.road_pool = _PoolSpy(("/v/nav.json", 10, 20))
                s.sign_pool = _PoolSpy(None)
                s.far_bld_pool = _PoolSpy(("/v/tr.json", 1, (0.0, 0.0), (0.0, 0.0, 0.0)))

                with mock.patch.object(earthd.navgraphmod, "country_at", return_value="US"), \
                        mock.patch.object(earthd.navgraphmod, "road_rules", return_value={"mph": True, "rightHandDrive": True}):
                    # serial=1 -> high priority submit
                    s.build_navgraph(anchor.id, 0.0, 0.0, 1)
                    self.assertEqual(s.road_pool.calls[-1][0], "submit")
                    # serial=2 -> low priority submit_low when _road_pool_fast_busy is True
                    s.build_navgraph(anchor.id, 0.0, 0.0, 2)
                    self.assertEqual(s.road_pool.calls[-1][0], "submit_low")

                s.build_signs_tile(anchor.id, 0, 0)
                self.assertEqual(s.sign_pool.calls[-1][0], "submit_low")

                s.build_traffic_geo(1, 2, far=False)
                self.assertEqual(s.far_bld_pool.calls[-1][0], "submit_low")

                # warm_roads routes ALL plan_cell jobs to submit_low when _road_pool_fast_busy is True
                s.road_pool.calls.clear()
                fake_shared = types.SimpleNamespace(has=lambda k: False, busy=lambda k: False)
                fake_grader = types.SimpleNamespace(shared=fake_shared, planned=lambda k: False, warm=lambda k: None)
                with mock.patch.object(s, "grader_for", return_value=fake_grader):
                    s.warm_roads(anchor, 0.0, 0.0, 0.0, -55.0)
                plan_calls = [c for c in s.road_pool.calls if c[1] is blockworker.plan_cell]
                self.assertGreater(len(plan_calls), 0)
                self.assertTrue(all(c[0] == "submit_low" for c in plan_calls))
            finally:
                s.hm_pool.shutdown(wait=True)
                s.tile_pool.shutdown(wait=True)


class QuickBaseRoadPaintTest(unittest.TestCase):
    def test_write_quick_base_upscales_and_paints_roads_above_photo_skip_speed(self):
        import numpy as np
        with tempfile.TemporaryDirectory() as tmp:
            s = earthd.Server(tmp, os.path.join(tmp, "cache"), imagery=None, road_pool=None, grading=False)
            try:
                anchor = s.new_anchor(47.855, 11.405)
                s.speed = earthd.PHOTO_SKIP_V + 10.0  # 65 m/s > 55 m/s
                s.base_px = 1024
                s.imagery = types.SimpleNamespace(
                    render=lambda frame, x0, y0, size, px, pending: (np.zeros((px, px, 3), np.uint8), {"usgs": px * px})
                )
                painted_shapes = []

                def fake_paint(rgb, *a, **kw):
                    painted_shapes.append((rgb.shape[:2], kw.get("simple")))
                    return rgb

                with mock.patch.object(earthd.roadsmod, "ROADS_IN_GROUND", True), \
                        mock.patch.object(earthd.surfacemod, "paint_square", side_effect=fake_paint), \
                        mock.patch.object(earthd.terraincache, "base_entry"):
                    name = s.write_quick_base(anchor, 0.0, 0.0)
                self.assertIsNotNone(name)
                self.assertEqual(len(painted_shapes), 1)
                self.assertGreaterEqual(painted_shapes[0][0][0], 1024)
                self.assertGreaterEqual(painted_shapes[0][0][1], 1024)
                self.assertTrue(painted_shapes[0][1])
            finally:
                s.hm_pool.shutdown(wait=True)
                s.tile_pool.shutdown(wait=True)

    def test_base_photo_quick_upscales_before_paint_square(self):
        import numpy as np
        with tempfile.TemporaryDirectory() as tmp, tempfile.TemporaryDirectory() as user:
            blockworker._s = types.SimpleNamespace(surface=None, widths=None, cache_dir=tmp)
            fake_im = types.SimpleNamespace(render=lambda frame, x0, y0, size, px, pending: (np.zeros((px, px, 3), np.uint8), {"usgs": px * px}))
            painted_shapes = []

            def fake_paint(rgb, *a, **kw):
                painted_shapes.append((rgb.shape[:2], kw.get("simple")))
                return rgb

            with mock.patch.object(blockworker, "_imagery", return_value=fake_im), \
                    mock.patch("roads.ROADS_IN_GROUND", True), \
                    mock.patch.object(surface, "paint_square", side_effect=fake_paint), \
                    mock.patch("terraincache.base_entry"):
                res = blockworker.base_photo(
                    47.855, 11.405, -512.0, -512.0, 1024.0, 512,
                    {"chain": ["usgs"], "tone": 1.0, "leaf_on": True, "season_mode": "off"},
                    False, 15, os.path.join(tmp, "q.png"),
                    (user, "/v/q.png", "/v/ao.png", 251),
                    out_px=512, quick=True, skip_roads=False,
                )
            self.assertIsNotNone(res)
            self.assertEqual(len(painted_shapes), 1)
            self.assertEqual(painted_shapes[0], ((1024, 1024), True))
            self.assertEqual(res[0].shape[:2], (512, 512))


if __name__ == "__main__":
    unittest.main()
