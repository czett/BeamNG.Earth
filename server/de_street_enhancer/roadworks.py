"""Dynamic German roadworks (`Baustellen`): real OSM construction tags + deterministic work zones.

Detects real mapped OSM `construction` / `roadworks` tags in `infrastructure` (within Germany)
plus deterministic procedural work zones (~13.5% per eligible tile on `primary`/`secondary`/`tertiary`
segments >= 90 m long, max 1 per tile, strictly inside `germany.BOX` & `germany.de_at`).

Emits:
  - `prop_rows`: `de_barrier` (along one lane edge for 35-55 m, leaving >= 3.4 m clear drivable
    carriageway width), `de_sign_123` (StVO 123 warning), and `de_sign_274_30` / `de_sign_274_50`.
  - `roadwork_rows`: compact `[id, x0, y0, x1, y1, halfW, workLimitKph]` corridors for
    `speedCameras.lua` temporary work-zone speed enforcement.
"""

from __future__ import annotations

import hashlib
import json
import math
import numpy as np

import dmath
import germany
import mapgeom
import roads as roadsmod

from . import classifier
from . import furniture_de


MIN_CLEAR_WIDTH_M = 3.40
MIN_ROAD_WIDTH_M = 5.00
MIN_SEGMENT_LEN_M = 90.0
MIN_ZONE_LEN_M = 35.0
MAX_ZONE_LEN_M = 55.0
BARRIER_STEP_M = 4.0
SIGN_VERGE_CLEAR_M = 0.65
PROC_HASH_THRESHOLD = 0.135
MATCH_ROAD_MAX_M = 28.0

ELIGIBLE_CLASSES = frozenset({"primary", "secondary", "tertiary"})
DRIVABLE_CLASSES = frozenset({"trunk", "primary", "secondary", "tertiary", "unclassified", "residential"})

BARRIER_PROP_GROUP = "de_barrier"
SIGN_123_GROUP = "de_sign_123"
SIGN_274_30_GROUP = "de_sign_274_30"
SIGN_274_50_GROUP = "de_sign_274_50"

BARRIER_HEIGHT_M = 1.15
SIGN_123_HEIGHT_M = 2.45
SIGN_274_HEIGHT_M = 2.47


def _hash01(*parts) -> float:
    h = hashlib.blake2b("|".join(str(p) for p in parts).encode("utf-8"), digest_size=8).digest()
    return int.from_bytes(h, "big") / float(1 << 64)


def _parse_tags(raw) -> dict:
    if isinstance(raw, dict):
        return raw
    if not raw:
        return {}
    try:
        got = json.loads(str(raw))
        return got if isinstance(got, dict) else {}
    except Exception:
        return {}


def _yaw_deg(dx: float, dy: float) -> float:
    return math.degrees(dmath.atan2(float(dy), float(dx))) % 360.0


def _extract_infra_roadworks(feats, cell_key) -> list[tuple[int, str]]:
    """Memoize OSM `construction`/`roadworks` feature indices on an `infrastructure` layer."""
    if feats is None or len(feats) == 0:
        return []
    cached = feats.__dict__.get("_de_roadworks")
    if cached is not None:
        return cached
    cls_arr = feats.attrs.get("class")
    tags_arr = feats.attrs.get("tags")
    ids_arr = getattr(feats, "ids", None)
    out: list[tuple[int, str]] = []
    for i in range(len(feats)):
        cls_v = str(cls_arr[i] or "").lower() if cls_arr is not None else ""
        tags = _parse_tags(tags_arr[i] if tags_arr is not None else None)
        hwy = str(tags.get("highway", "")).lower()
        haz = str(tags.get("hazard", "")).lower()
        rw = str(tags.get("roadworks", "")).lower()
        con = str(tags.get("construction", "")).lower()
        is_rw = (
            cls_v in ("construction", "roadworks")
            or hwy == "construction"
            or haz == "roadworks"
            or rw in ("yes", "true", "1")
            or bool(con and con not in ("no", "none", "false", "0"))
        )
        if not is_rw:
            continue
        fid = str(ids_arr[i]) if ids_arr is not None else f"rw:{cell_key}:{i}"
        out.append((i, fid))
    feats.__dict__["_de_roadworks"] = out
    return out


def extract_osm_roadworks(md, frame, box: tuple[float, float, float, float]) -> list[tuple[str, np.ndarray]]:
    """Extract real OSM `construction`/`roadworks` points within `box` (+ match margin)."""
    if md is None:
        return []
    import mapcells

    cx = 0.5 * (box[0] + box[2])
    cy = 0.5 * (box[1] + box[3])
    half = 0.5 * max(box[2] - box[0], box[3] - box[1]) + MATCH_ROAD_MAX_M
    lat0, lon0, _ = frame.enu_to_geodetic(cx, cy, 0.0)
    dlat = half / 111320.0
    dlon = half / (111320.0 * max(0.2, math.cos(math.radians(float(lat0)))))
    bbox_cells = list(mapcells.cells_for_bbox(float(lat0) - dlat, float(lon0) - dlon, float(lat0) + dlat, float(lon0) + dlon))

    seen: set[str] = set()
    out: list[tuple[str, np.ndarray]] = []
    for cell_key in bbox_cells:
        try:
            cd = md.cell(cell_key, layers=("infrastructure",), kind="demand")
            feats = cd.layers.get("infrastructure")
        except Exception:
            continue
        for i, fid in _extract_infra_roadworks(feats, cell_key):
            if fid in seen:
                continue
            seen.add(fid)
            parts = feats.parts(i)
            if not parts or not parts[0] or len(parts[0][0]) < 1:
                continue
            e, n = mapgeom.enu_xy(feats, frame, np.asarray(parts[0][0], np.float64))
            if len(e) == 0:
                continue
            pt = np.array([float(np.mean(e)), float(np.mean(n))], dtype=np.float64)
            if np.isfinite(pt).all():
                out.append((fid, pt))
    return out


def _polyline_metrics(pts: np.ndarray) -> tuple[np.ndarray, np.ndarray, np.ndarray, float]:
    seg = np.diff(pts, axis=0)
    seg_l = np.hypot(seg[:, 0], seg[:, 1])
    cum = np.concatenate(([0.0], np.cumsum(seg_l)))
    return seg, seg_l, cum, float(cum[-1])


def _sample_along(pts: np.ndarray, seg: np.ndarray, seg_l: np.ndarray, cum: np.ndarray, s: float) -> tuple[np.ndarray, np.ndarray]:
    total = float(cum[-1])
    sc = max(0.0, min(total, float(s)))
    idx = max(0, min(len(seg_l) - 1, int(np.searchsorted(cum, sc, side="right") - 1)))
    sl = max(float(seg_l[idx]), 1e-9)
    t = (sc - float(cum[idx])) / sl
    pos = pts[idx] + t * seg[idx]
    tang = seg[idx] / sl
    return pos, tang


def _match_nearest_drivable(pt: np.ndarray, near_roads: list):
    """Return `(fid, sp, pts, s_hit)` for the nearest eligible drivable road within `MATCH_ROAD_MAX_M`."""
    px, py = float(pt[0]), float(pt[1])
    best = None
    for item in near_roads or ():
        fid, sp, raw_pts = str(item[0]), item[1], item[2]
        cls = getattr(sp, "cls", "")
        if cls not in DRIVABLE_CLASSES or getattr(sp, "link", False):
            continue
        if getattr(sp, "bridge", False) or getattr(sp, "tunnel", False):
            continue
        width = float(getattr(sp, "width", 0.0) or 0.0)
        if width < MIN_ROAD_WIDTH_M:
            continue
        pts = furniture_de._finite_2d(raw_pts, min_pts=2)
        if pts is None:
            continue
        seg, seg_l, cum, total = _polyline_metrics(pts)
        if total < MIN_ZONE_LEN_M + 10.0:
            continue
        a = pts[:-1]
        l2 = np.maximum((seg * seg).sum(1), 1e-12)
        t = np.clip(((px - a[:, 0]) * seg[:, 0] + (py - a[:, 1]) * seg[:, 1]) / l2, 0.0, 1.0)
        q = a + t[:, None] * seg
        dist = np.hypot(px - q[:, 0], py - q[:, 1])
        k = int(np.argmin(dist))
        d_c = float(dist[k])
        if d_c > MATCH_ROAD_MAX_M:
            continue
        s_hit = float(cum[k]) + float(t[k]) * float(seg_l[k])
        if best is None or d_c < best[0]:
            best = (d_c, fid, sp, pts, s_hit, total)
    return best


def _build_zone_geometry(
    zone_id: str,
    sp,
    pts: np.ndarray,
    s_center: float,
    zone_len: float,
    box: tuple[float, float, float, float],
    all_road_bands: list,
    tram_lines: list[np.ndarray],
    rings_clean: list[np.ndarray],
):
    """Compute barrier/sign coordinates & corridor tuple for one roadwork zone, or None if unsafe."""
    width = float(getattr(sp, "width", 0.0) or 0.0)
    if width < MIN_ROAD_WIDTH_M:
        return None
    half_w = width * 0.5
    # Leave at least MIN_CLEAR_WIDTH_M (3.40 m) of clear drivable carriageway width.
    max_incursion = width - MIN_CLEAR_WIDTH_M
    if max_incursion < 1.15:
        return None
    incursion = min(1.50, max_incursion)
    # Center barriers inside the closed outer edge strip (inner face clears remaining >= 3.4 m).
    barrier_offset = half_w - incursion * 0.45

    seg, seg_l, cum, total = _polyline_metrics(pts)
    s0 = max(8.0, min(total - zone_len - 8.0, s_center - zone_len * 0.5))
    s1 = s0 + zone_len
    if s1 > total - 6.0 or s1 - s0 < MIN_ZONE_LEN_M:
        return None

    p0, t0 = _sample_along(pts, seg, seg_l, cum, s0)
    p1, _t1 = _sample_along(pts, seg, seg_l, cum, s1)
    if not (roadsmod.box_owns(box, float(p0[0]), float(p0[1])) or roadsmod.box_owns(box, float(p1[0]), float(p1[1]))):
        return None

    # Barrier run along right-hand edge (relative to segment travel direction).
    barriers: list[tuple[np.ndarray, float]] = []
    n_steps = max(2, int(math.floor(zone_len / BARRIER_STEP_M)) + 1)
    for k in range(n_steps):
        sk = s0 + (zone_len * k) / max(1, n_steps - 1)
        pos, tang = _sample_along(pts, seg, seg_l, cum, sk)
        right = np.array([tang[1], -tang[0]], dtype=np.float64)
        b_xy = pos + right * barrier_offset
        if not roadsmod.box_owns(box, float(b_xy[0]), float(b_xy[1])):
            continue
        if any(classifier._point_in_ring(b_xy, rr) for rr in rings_clean):
            continue
        if tram_lines and classifier.min_dist_to_polylines(b_xy, tram_lines) < 1.60:
            continue
        barriers.append((b_xy, _yaw_deg(float(tang[0]), float(tang[1]))))

    if len(barriers) < 4:
        return None

    # Temporary speed limit: 30 km/h urban/narrow, 50 km/h rural primary/secondary.
    is_urban = bool(getattr(sp, "urban", False))
    work_limit = 30.0 if (is_urban or width < 6.8) else 50.0
    sign_274 = SIGN_274_30_GROUP if work_limit <= 30.0 else SIGN_274_50_GROUP

    # Upstream lead-in signs (18 m & 8 m before s0) strictly off the carriageway on the right verge.
    signs: list[tuple[str, np.ndarray, float]] = []
    for s_lead, grp in ((max(2.0, s0 - 16.0), SIGN_123_GROUP), (max(2.0, s0 - 7.0), sign_274)):
        pos, tang = _sample_along(pts, seg, seg_l, cum, s_lead)
        right = np.array([tang[1], -tang[0]], dtype=np.float64)
        for extra in (0.75, 1.25, 1.85):
            s_xy = pos + right * (half_w + extra)
            if not roadsmod.box_owns(box, float(s_xy[0]), float(s_xy[1])):
                continue
            if furniture_de._is_safe_footprint(
                s_xy, tang, -right, 0.25, 0.25, all_road_bands, tram_lines, rings_clean, extra_clear_m=SIGN_VERGE_CLEAR_M
            ):
                # Local -Y faces approaching traffic (matching de_radar convention).
                signs.append((grp, s_xy, round((_yaw_deg(float(tang[0]), float(tang[1])) - 90.0) % 360.0, 2)))
                break

    corridor = (zone_id, p0, p1, half_w + 0.5, work_limit)
    return barriers, signs, corridor


def plan_de_roadworks(
    md,
    frame,
    box: tuple[float, float, float, float],
    near_roads: list,
    rings_arr: list[np.ndarray] | None,
    ground,
    tx: int | None = None,
    ty: int | None = None,
    level: str = "medium",
    fast_pass: bool = False,
) -> tuple[list[list], list[list]]:
    """Plan German roadwork barrier/sign Forest props and `deRoadworks` enforcement corridors.

    Returns `(prop_rows, roadwork_rows)`:
      - `prop_rows`: `[[group, x, y, z, yaw_deg, 1.0, height_m, 0.0], ...]`
      - `roadwork_rows`: `[[id, x0, y0, x1, y1, halfW, workLimitKph], ...]`
    """
    if not near_roads:
        return [], []

    all_road_bands = furniture_de._all_road_bands(near_roads)
    tram_lines = classifier.tram_polylines(md, frame, tx, ty) if md is not None else []
    rings_clean = rings_arr if rings_arr is not None else []

    planned_zones = []
    # 1. Real OSM construction/roadworks tags in Germany.
    for fid, pt in extract_osm_roadworks(md, frame, box):
        match = _match_nearest_drivable(pt, near_roads)
        if match is None:
            continue
        _d, rfid, sp, pts, s_hit, total = match
        z_len = min(MAX_ZONE_LEN_M, max(MIN_ZONE_LEN_M, 42.0))
        if total < z_len + 16.0:
            continue
        built = _build_zone_geometry(
            f"de_rw_osm_{fid}", sp, pts, s_hit, z_len, box, all_road_bands, tram_lines, rings_clean
        )
        if built is not None:
            planned_zones.append(built)
            break  # Max 1 roadwork zone per tile

    # 2. Deterministic procedural roadworks (~13.5% of eligible tiles, max 1 per tile).
    if not planned_zones and level != "low" and not fast_pass:
        cands = []
        for item in near_roads:
            fid, sp, raw_pts = str(item[0]), item[1], item[2]
            if getattr(sp, "cls", "") not in ELIGIBLE_CLASSES or getattr(sp, "link", False):
                continue
            if getattr(sp, "bridge", False) or getattr(sp, "tunnel", False):
                continue
            if float(getattr(sp, "width", 0.0) or 0.0) < MIN_ROAD_WIDTH_M:
                continue
            pts = furniture_de._finite_2d(raw_pts, min_pts=2)
            if pts is None:
                continue
            _seg, _segl, _cum, total = _polyline_metrics(pts)
            if total < MIN_SEGMENT_LEN_M:
                continue
            h = _hash01("de_roadwork", tx, ty, fid)
            if h < PROC_HASH_THRESHOLD:
                cands.append((h, fid, sp, pts, total))
        cands.sort(key=lambda c: c[0])
        for h, fid, sp, pts, total in cands:
            z_len = MIN_ZONE_LEN_M + _hash01("de_rw_len", tx, ty, fid) * (MAX_ZONE_LEN_M - MIN_ZONE_LEN_M)
            s_center = total * (0.35 + 0.30 * _hash01("de_rw_pos", tx, ty, fid))
            built = _build_zone_geometry(
                f"de_rw_{tx}_{ty}_{fid}", sp, pts, s_center, z_len, box, all_road_bands, tram_lines, rings_clean
            )
            if built is not None:
                planned_zones.append(built)
                break

    if not planned_zones:
        return [], []

    # Verify strict Germany border membership before emitting props/corridors.
    barriers, signs, corridor = planned_zones[0]
    zid, p0, p1, half_w, work_limit = corridor
    mid_xy = 0.5 * (p0 + p1)
    if not bool(germany.de_at(frame, np.array([float(mid_xy[0])]), np.array([float(mid_xy[1])]))[0]):
        return [], []

    all_xy = [b[0] for b in barriers] + [s[1] for s in signs]
    xs = np.array([float(p[0]) for p in all_xy], dtype=np.float64)
    ys = np.array([float(p[1]) for p in all_xy], dtype=np.float64)
    zs = np.asarray(ground(xs, ys), dtype=np.float64) if ground is not None else np.zeros(len(xs), dtype=np.float64)

    prop_rows: list[list] = []
    nb = len(barriers)
    for idx, (b_xy, yaw) in enumerate(barriers):
        bz = float(zs[idx])
        if not math.isfinite(bz):
            continue
        prop_rows.append([
            BARRIER_PROP_GROUP,
            round(float(b_xy[0]), 3),
            round(float(b_xy[1]), 3),
            round(bz, 3),
            round(yaw, 2),
            1.0,
            BARRIER_HEIGHT_M,
            0.0,
        ])
    for s_idx, (grp, s_xy, yaw) in enumerate(signs):
        sz = float(zs[nb + s_idx])
        if not math.isfinite(sz):
            continue
        h_m = SIGN_123_HEIGHT_M if grp == SIGN_123_GROUP else SIGN_274_HEIGHT_M
        prop_rows.append([
            grp,
            round(float(s_xy[0]), 3),
            round(float(s_xy[1]), 3),
            round(sz, 3),
            round(yaw, 2),
            1.0,
            h_m,
            0.0,
        ])

    if not prop_rows:
        return [], []

    roadwork_rows = [[
        zid,
        round(float(p0[0]), 3),
        round(float(p0[1]), 3),
        round(float(p1[0]), 3),
        round(float(p1[1]), 3),
        round(float(half_w), 2),
        round(float(work_limit), 1),
    ]]
    return prop_rows, roadwork_rows
