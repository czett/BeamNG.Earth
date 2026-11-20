"""Real OSM speed cameras (`highway=speed_camera`) & deterministic DE mobile radar traps.

Extracts real mapped `highway=speed_camera` / `enforcement=maxspeed` points from Overture/OSM
`infrastructure` (and `places` fallback) plus deterministic mobile radar traps near German
town-entry speed-drop transitions (`BNE_DE_STREET_IMMERSION=on`).

Places visible 3D radar pillars (`de_radar` Forest prop -> `bne_de_radar.dae`) strictly outside
all road carriageways (`>= 0.65 m` clearance) and emits compact client enforcement gates
(`deSpeedCameras` tile JSON array) for `speedCameras.lua`.
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
from . import speed_limits


CARRIAGEWAY_CLEAR_M = 0.65
TRAM_CLEAR_M = 2.20
MATCH_ROAD_MAX_M = 28.0
MIN_CAMERA_SPACING_M = 40.0
MOBILE_MIN_DIST_TO_FIXED_M = 250.0
MOBILE_HASH_THRESHOLD = 0.22
RADAR_PROP_GROUP = "de_radar"
RADAR_PROP_HEIGHT_M = 2.65
RADAR_LENS_Z_M = 2.10

DRIVABLE_CLASSES = {
    "motorway", "trunk", "primary", "secondary", "tertiary",
    "unclassified", "residential", "living_street",
}
MOBILE_CLASSES = {"primary", "secondary", "tertiary"}


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


def _extract_infra_cameras(feats, cell_key) -> list[tuple[int, str, float | None, str]]:
    """Memoize speed-camera feature indices on an `infrastructure` layer."""
    if feats is None or len(feats) == 0:
        return []
    cached = feats.__dict__.get("_de_speed_cameras")
    if cached is not None:
        return cached
    cls_arr = feats.attrs.get("class")
    tags_arr = feats.attrs.get("tags")
    ids_arr = getattr(feats, "ids", None)
    out: list[tuple[int, str, float | None, str]] = []
    for i in range(len(feats)):
        cls_v = str(cls_arr[i] or "").lower() if cls_arr is not None else ""
        tags = _parse_tags(tags_arr[i] if tags_arr is not None else None)
        hwy = str(tags.get("highway", "")).lower()
        enf = str(tags.get("enforcement", "")).lower()
        mm = str(tags.get("man_made", "")).lower()
        is_cam = (
            hwy == "speed_camera"
            or cls_v == "speed_camera"
            or enf in ("maxspeed", "speed")
            or (mm == "monitoring_station" and "maxspeed" in tags)
        )
        if not is_cam:
            continue
        fid = str(ids_arr[i]) if ids_arr is not None else f"cam:{cell_key}:{i}"
        lim = speed_limits.parse_maxspeed_kph(tags.get("maxspeed"), country="DE")
        direction = str(tags.get("direction", "")).strip().lower()
        out.append((i, fid, lim, direction))
    feats.__dict__["_de_speed_cameras"] = out
    return out


def extract_osm_speed_cameras(md, frame, box: tuple[float, float, float, float]) -> list[tuple[str, np.ndarray, float | None, str]]:
    """Extract real OSM `highway=speed_camera` points within `box` (plus small match margin)."""
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
    out: list[tuple[str, np.ndarray, float | None, str]] = []
    for cell_key in bbox_cells:
        try:
            cd = md.cell(cell_key, layers=("infrastructure",), kind="demand")
            feats = cd.layers.get("infrastructure")
        except Exception:
            continue
        for i, fid, lim, direction in _extract_infra_cameras(feats, cell_key):
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
            if not np.isfinite(pt).all():
                continue
            out.append((fid, pt, lim, direction))
    return out


def _match_nearest_road(pt: np.ndarray, near_roads: list):
    """Match camera point `pt` to nearest drivable road in `near_roads` within `MATCH_ROAD_MAX_M`."""
    px, py = float(pt[0]), float(pt[1])
    best = None
    for item in near_roads or ():
        fid, sp, raw_pts = item[0], item[1], item[2]
        cls = getattr(sp, "cls", "")
        if cls not in DRIVABLE_CLASSES or getattr(sp, "link", False):
            continue
        pts = furniture_de._finite_2d(raw_pts, min_pts=2)
        if pts is None:
            continue
        hw = float(getattr(sp, "width", 6.0) or 6.0) * 0.5
        a, b = pts[:-1], pts[1:]
        ab = b - a
        l2 = np.maximum((ab * ab).sum(1), 1e-12)
        t = np.clip(((px - a[:, 0]) * ab[:, 0] + (py - a[:, 1]) * ab[:, 1]) / l2, 0.0, 1.0)
        q = a + t[:, None] * ab
        dist = np.hypot(px - q[:, 0], py - q[:, 1])
        k = int(np.argmin(dist))
        d_c = float(dist[k])
        if d_c > MATCH_ROAD_MAX_M:
            continue
        seg = ab[k]
        sl = max(float(np.hypot(seg[0], seg[1])), 1e-9)
        tang = np.array([seg[0] / sl, seg[1] / sl], dtype=np.float64)
        right = np.array([tang[1], -tang[0]], dtype=np.float64)
        side = float(np.dot(pt - q[k], right))
        if getattr(sp, "oneway", False):
            sense = int(getattr(sp, "dir", 1) or 1)
        else:
            sense = 1 if side >= 0.0 else -1
        if best is None or d_c < best[0]:
            best = (d_c, str(fid), sp, q[k], tang * sense, hw)
    return best


def _find_clear_pillar_spot(
    pt: np.ndarray,
    centre: np.ndarray,
    travel: np.ndarray,
    hw: float,
    all_road_bands: list,
    tram_lines: list[np.ndarray],
    rings_arr: list[np.ndarray],
) -> np.ndarray | None:
    """Return a pillar XY strictly `>= CARRIAGEWAY_CLEAR_M` (0.65 m) outside every road carriageway."""
    right = np.array([travel[1], -travel[0]], dtype=np.float64)
    # 1. If the mapped OSM point itself is already cleanly off the carriageway (and <= 10 m away), keep it.
    if np.hypot(float(pt[0] - centre[0]), float(pt[1] - centre[1])) <= hw + 10.0:
        if furniture_de._is_safe_footprint(
            pt, travel, -right, 0.22, 0.22, all_road_bands, tram_lines, rings_arr, extra_clear_m=CARRIAGEWAY_CLEAR_M
        ):
            return pt

    # 2. Otherwise step outward onto the right verge (then left verge fallback) with >= 0.65 m clearance.
    for side_sign in (1.0, -1.0):
        outward = right * side_sign
        for extra in (0.95, 1.35, 1.85, 2.50, 3.30):
            cand = centre + outward * (hw + extra)
            if furniture_de._is_safe_footprint(
                cand, travel, -outward, 0.22, 0.22, all_road_bands, tram_lines, rings_arr, extra_clear_m=CARRIAGEWAY_CLEAR_M
            ):
                return cand
    return None


def _road_limit_kph(sp) -> float:
    kmh = getattr(sp, "kmh", None)
    if kmh is not None:
        parsed = speed_limits.parse_maxspeed_kph(kmh, country="DE", cls=getattr(sp, "cls", None), urban=bool(getattr(sp, "urban", False)))
        if parsed is not None:
            return parsed
    return speed_limits.de_default_kph(getattr(sp, "cls", None), bool(getattr(sp, "urban", False)))


def _plan_mobile_traps(
    near_roads: list,
    box: tuple[float, float, float, float],
    fixed_xy: list[tuple[float, float]],
) -> list[tuple[str, np.ndarray, object, np.ndarray, np.ndarray, float, float]]:
    """Deterministically pick at most 1 mobile radar trap near DE rural->urban transitions in `box`."""
    # Group road ends to detect rural->urban (or >=20 km/h drop) transitions on primary/secondary/tertiary roads.
    ends: dict[tuple[int, int], list[tuple[str, object, np.ndarray, int, float]]] = {}
    for item in near_roads or ():
        fid, sp, raw_pts = str(item[0]), item[1], item[2]
        if getattr(sp, "cls", "") not in MOBILE_CLASSES or getattr(sp, "link", False):
            continue
        pts = furniture_de._finite_2d(raw_pts, min_pts=2)
        if pts is None:
            continue
        lim = _road_limit_kph(sp)
        for end_i, pt in ((0, pts[0]), (-1, pts[-1])):
            bk = (int(round(float(pt[0]) / 2.0)), int(round(float(pt[1]) / 2.0)))
            ends.setdefault(bk, []).append((fid, sp, pts, end_i, lim))

    cands: list[tuple[float, str, np.ndarray, object, np.ndarray, np.ndarray, float, float]] = []
    for bk, arms in ends.items():
        if len(arms) < 2:
            continue
        urban_arms = [a for a in arms if bool(getattr(a[1], "urban", False)) and 0.0 < a[4] <= 50.0]
        fast_arms = [a for a in arms if (not bool(getattr(a[1], "urban", False))) or a[4] >= 70.0]
        if not urban_arms or not fast_arms:
            continue
        for fid, sp, pts, end_i, lim in urban_arms:
            if not any(f_lim - lim >= 20.0 or (not getattr(f_sp, "urban", False)) for _, f_sp, _, _, f_lim in fast_arms):
                continue
            # Walk 40..55 m into the urban segment from the transition point.
            ordered = pts if end_i == 0 else pts[::-1]
            seg = np.diff(ordered, axis=0)
            seg_l = np.hypot(seg[:, 0], seg[:, 1])
            total = float(seg_l.sum())
            if total < 45.0:
                continue
            h = _hash01("de_mobile_radar", fid, bk[0], bk[1])
            if h > MOBILE_HASH_THRESHOLD:
                continue
            station = min(total - 8.0, 38.0 + _hash01("de_mobile_s", fid) * 18.0)
            cum = np.concatenate(([0.0], np.cumsum(seg_l)))
            idx = max(0, min(len(seg_l) - 1, int(np.searchsorted(cum, station, side="right") - 1)))
            sl = max(float(seg_l[idx]), 1e-9)
            t = (station - float(cum[idx])) / sl
            centre = ordered[idx] + t * seg[idx]
            travel = seg[idx] / sl
            if getattr(sp, "oneway", False):
                d_sign = int(getattr(sp, "dir", 1) or 1)
                if (end_i == -1 and d_sign > 0) or (end_i == 0 and d_sign < 0):
                    continue
            if not roadsmod.box_owns(box, float(centre[0]), float(centre[1])):
                continue
            if any(math.hypot(float(centre[0]) - fx, float(centre[1]) - fy) < MOBILE_MIN_DIST_TO_FIXED_M for fx, fy in fixed_xy):
                continue
            hw = float(getattr(sp, "width", 6.5) or 6.5) * 0.5
            cands.append((h, f"de_mob_{fid}", centre, sp, centre, travel, hw, lim))

    if not cands:
        return []
    cands.sort(key=lambda c: c[0])
    _, cid, pt, sp, centre, travel, hw, lim = cands[0]
    return [(cid, pt, sp, centre, travel, hw, lim)]


def plan_de_speed_cameras(
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
    allow_mobile: bool = True,
) -> tuple[list[list], list[list]]:
    """Plan German 3D radar pillars (`de_radar` Forest rows) and client speed gates (`deSpeedCameras`).

    Returns `(prop_rows, camera_rows)`:
      - `prop_rows`: `[["de_radar", x, y, z, yaw_deg, 1.0, 2.65, 0.0], ...]`
      - `camera_rows`: `[[id, gx, gy, gz, travel_yaw, half_w, limit_kph, cx, cy, cz, urban_int, kind_code], ...]`
        where `kind_code == 0` is a mapped OSM fixed camera and `1` is a deterministic mobile trap.
    """
    if not near_roads:
        return [], []

    all_road_bands = furniture_de._all_road_bands(near_roads)
    tram_lines = classifier.tram_polylines(md, frame, tx, ty) if md is not None else []
    rings_clean = rings_arr if rings_arr is not None else []

    raw_osm = extract_osm_speed_cameras(md, frame, box)
    placed_xy: list[tuple[float, float]] = []
    # (cid, cam_xy, gate_xy, travel, gate_half, limit_kph, urban_int, kind_code)
    staged: list[tuple[str, np.ndarray, np.ndarray, np.ndarray, float, float, int, int]] = []

    for fid, pt, node_lim, _direction in raw_osm:
        match = _match_nearest_road(pt, near_roads)
        if match is None:
            continue
        _d, _rfid, sp, centre, travel, hw = match
        lim = node_lim if node_lim is not None else _road_limit_kph(sp)
        if lim is None or lim <= 0.0:
            continue
        cam_xy = _find_clear_pillar_spot(pt, centre, travel, hw, all_road_bands, tram_lines, rings_clean)
        if cam_xy is None:
            continue
        cx, cy = float(cam_xy[0]), float(cam_xy[1])
        if not roadsmod.box_owns(box, cx, cy):
            continue
        if any(math.hypot(cx - ox, cy - oy) < MIN_CAMERA_SPACING_M for ox, oy in placed_xy):
            continue
        right = np.array([travel[1], -travel[0]], dtype=np.float64)
        half = hw if getattr(sp, "oneway", False) else hw * 0.5
        gate_xy = centre if getattr(sp, "oneway", False) else (centre + right * half)
        staged.append((f"de_cam_{fid}", cam_xy, gate_xy, travel, max(1.5, half - 0.10), float(lim), 1 if getattr(sp, "urban", False) else 0, 0))
        placed_xy.append((cx, cy))

    if allow_mobile and level != "low" and not fast_pass:
        for cid, pt, sp, centre, travel, hw, lim in _plan_mobile_traps(near_roads, box, placed_xy):
            if lim <= 0.0:
                continue
            cam_xy = _find_clear_pillar_spot(pt, centre, travel, hw, all_road_bands, tram_lines, rings_clean)
            if cam_xy is None:
                continue
            cx, cy = float(cam_xy[0]), float(cam_xy[1])
            if not roadsmod.box_owns(box, cx, cy):
                continue
            right = np.array([travel[1], -travel[0]], dtype=np.float64)
            half = hw if getattr(sp, "oneway", False) else hw * 0.5
            gate_xy = centre if getattr(sp, "oneway", False) else (centre + right * half)
            staged.append((cid, cam_xy, gate_xy, travel, max(1.5, half - 0.10), float(lim), 1 if getattr(sp, "urban", False) else 0, 1))
            placed_xy.append((cx, cy))

    if not staged:
        return [], []

    cam_xs = np.array([float(s[1][0]) for s in staged], dtype=np.float64)
    cam_ys = np.array([float(s[1][1]) for s in staged], dtype=np.float64)
    gate_xs = np.array([float(s[2][0]) for s in staged], dtype=np.float64)
    gate_ys = np.array([float(s[2][1]) for s in staged], dtype=np.float64)
    in_de = germany.de_at(frame, cam_xs, cam_ys)

    all_xs = np.concatenate((cam_xs, gate_xs))
    all_ys = np.concatenate((cam_ys, gate_ys))
    zs = np.asarray(ground(all_xs, all_ys), dtype=np.float64) if ground is not None else np.zeros(len(all_xs), dtype=np.float64)
    n = len(staged)

    prop_rows: list[list] = []
    camera_rows: list[list] = []
    for idx, (cid, cam_xy, gate_xy, travel, gate_half, lim, urban_int, kind_code) in enumerate(staged):
        if not in_de[idx]:
            continue
        cz = float(zs[idx])
        gz = float(zs[n + idx])
        if not (math.isfinite(cz) and math.isfinite(gz)):
            continue
        travel_yaw = round(_yaw_deg(float(travel[0]), float(travel[1])), 2)
        # Prop local -Y faces approaching traffic (matching fr_radars convention).
        prop_yaw = round((travel_yaw - 90.0) % 360.0, 2)
        prop_rows.append([
            RADAR_PROP_GROUP,
            round(float(cam_xy[0]), 3),
            round(float(cam_xy[1]), 3),
            round(cz, 3),
            prop_yaw,
            1.0,
            RADAR_PROP_HEIGHT_M,
            0.0,
        ])
        camera_rows.append([
            cid,
            round(float(gate_xy[0]), 3),
            round(float(gate_xy[1]), 3),
            round(gz, 3),
            travel_yaw,
            round(float(gate_half), 3),
            round(float(lim), 1),
            round(float(cam_xy[0]), 3),
            round(float(cam_xy[1]), 3),
            round(cz + RADAR_LENS_Z_M, 3),
            int(urban_int),
            int(kind_code),
        ])

    return prop_rows, camera_rows
