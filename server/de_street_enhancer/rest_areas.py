"""German Autobahn Rest Areas & Parking Areas (`Raststätten & Parkplätze`).

Detects mapped OSM `highway=services` and `highway=rest_area` features (plus
`amenity=parking` / `parking=rest_area` adjacent to `motorway`/`trunk` roads)
inside Germany (`germany.BOX` & `germany.de_at()`).

Places authentic German rest-area props using only Forest groups registered in
`trees.lua` (`picnictable`, `bench`, `bin`, `recyclebin`, `eu_lamp_steel`,
`eu_marker_de`, `de_sign_274_30`, `de_z205`), strictly outside all road
carriageways (`>= 0.65 m` clearance) and outside all building footprints.
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


ROAD_CLEAR_M = 0.65
HIGHWAY_ADJACENT_MAX_M = 120.0
MATCH_ROAD_MAX_M = 85.0
SEARCH_MARGIN_M = 35.0
MIN_PROP_SPACING_M = 1.45
MAX_REST_AREAS_PER_TILE = 3

HIGHWAY_CLASSES = frozenset({"motorway", "trunk", "motorway_link", "trunk_link"})

# Every group below is verified registered in `trees.lua` (with its 1:1 model height in metres).
PROP_HEIGHTS_M: dict[str, float] = {
    "picnictable": 0.85,
    "bench": 0.90,
    "bin": 1.10,
    "recyclebin": 1.48,
    "eu_lamp_steel": 9.00,
    "eu_marker_de": 1.15,
    "de_sign_274_30": 2.47,
    "de_z205": 2.742,
}

# Approximate half-extents (hx, hy) in metres for footprint collision checks.
_PROP_HALF_EXTENTS: dict[str, tuple[float, float]] = {
    "picnictable": (1.05, 0.75),
    "bench": (0.85, 0.35),
    "bin": (0.28, 0.28),
    "recyclebin": (0.45, 0.45),
    "eu_lamp_steel": (0.25, 0.25),
    "eu_marker_de": (0.12, 0.12),
    "de_sign_274_30": (0.25, 0.25),
    "de_z205": (0.25, 0.25),
}

REST_AREA_PROP_GROUPS = frozenset(PROP_HEIGHTS_M.keys())


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


def _extract_layer_rest_areas(feats, cell_key, layer_name: str) -> list[tuple[int, str, str]]:
    """Memoize matching rest-area / motorway-parking feature indices on a layer.

    Returns list of `(feat_idx, fid, kind)` where `kind` is one of:
      - `"services"`: `highway=services` (Autobahn-Raststätte)
      - `"rest_area"`: `highway=rest_area` or `parking=rest_area` (Autobahn-Parkplatz)
      - `"parking"`: `amenity=parking` / `class=parking` (requires motorway/trunk adjacency)
    """
    if feats is None or len(feats) == 0:
        return []
    cache_attr = f"_de_rest_areas_{layer_name}"
    cached = feats.__dict__.get(cache_attr)
    if cached is not None:
        return cached

    cls_arr = feats.attrs.get("class")
    tags_arr = feats.attrs.get("tags")
    ids_arr = getattr(feats, "ids", None)
    out: list[tuple[int, str, str]] = []

    for i in range(len(feats)):
        cls_v = str(cls_arr[i] or "").strip().lower() if cls_arr is not None else ""
        tags = _parse_tags(tags_arr[i] if tags_arr is not None else None)
        hwy = str(tags.get("highway", "")).strip().lower()
        am = str(tags.get("amenity", "")).strip().lower()
        pk = str(tags.get("parking", "")).strip().lower()

        kind = None
        if hwy == "services" or cls_v in ("services", "motorway_services"):
            kind = "services"
        elif hwy == "rest_area" or cls_v == "rest_area" or pk == "rest_area":
            kind = "rest_area"
        elif (am == "parking" or cls_v == "parking") and pk not in ("street_side", "lane", "underground", "multi-storey", "rooftop", "carports", "garage_boxes"):
            kind = "parking"

        if kind is None:
            continue
        fid = str(ids_arr[i]) if ids_arr is not None else f"ra:{layer_name}:{cell_key}:{i}"
        out.append((i, fid, kind))

    feats.__dict__[cache_attr] = out
    return out


def _min_dist_to_highway(pt: np.ndarray, near_roads: list) -> float:
    """Return minimum centerline distance from `pt` to any `motorway`/`trunk` road in `near_roads`."""
    px, py = float(pt[0]), float(pt[1])
    best = float("inf")
    for item in near_roads or ():
        sp = item[1]
        if getattr(sp, "cls", "") not in HIGHWAY_CLASSES:
            continue
        pts = furniture_de._finite_2d(item[2], min_pts=2)
        if pts is None:
            continue
        a = pts[:-1]
        ab = pts[1:] - a
        l2 = np.maximum((ab * ab).sum(1), 1e-12)
        t = np.clip(((px - a[:, 0]) * ab[:, 0] + (py - a[:, 1]) * ab[:, 1]) / l2, 0.0, 1.0)
        q = a + t[:, None] * ab
        d = float(np.min(np.hypot(px - q[:, 0], py - q[:, 1])))
        if d < best:
            best = d
    return best


def _nearest_road_frame(pt: np.ndarray, near_roads: list):
    """Return `(edge_dist, q_on_centerline, tang, away, half_w)` for the nearest road in `near_roads`."""
    px, py = float(pt[0]), float(pt[1])
    best = None
    for item in near_roads or ():
        sp = item[1]
        pts = furniture_de._finite_2d(item[2], min_pts=2)
        if pts is None:
            continue
        hw = float(getattr(sp, "width", 0.0) or 0.0) * 0.5
        a = pts[:-1]
        ab = pts[1:] - a
        l2 = np.maximum((ab * ab).sum(1), 1e-12)
        t = np.clip(((px - a[:, 0]) * ab[:, 0] + (py - a[:, 1]) * ab[:, 1]) / l2, 0.0, 1.0)
        q = a + t[:, None] * ab
        dist = np.hypot(px - q[:, 0], py - q[:, 1])
        k = int(np.argmin(dist))
        d_c = float(dist[k])
        edge_d = d_c - hw
        if best is None or edge_d < best[0]:
            seg = ab[k]
            sl = max(float(np.hypot(seg[0], seg[1])), 1e-9)
            tang = np.array([seg[0] / sl, seg[1] / sl], dtype=np.float64)
            v = np.array([px - float(q[k, 0]), py - float(q[k, 1])], dtype=np.float64)
            vl = float(np.hypot(v[0], v[1]))
            away = (v / vl) if vl > 1e-4 else np.array([tang[1], -tang[0]], dtype=np.float64)
            best = (edge_d, q[k], tang, away, hw)
    if best is None or best[0] > MATCH_ROAD_MAX_M:
        return None
    return best


def extract_osm_rest_areas(
    md,
    frame,
    box: tuple[float, float, float, float],
    near_roads: list,
) -> list[tuple[str, str, np.ndarray, np.ndarray | None]]:
    """Extract OSM rest areas & motorway parking sites near `box` inside `germany.BOX`.

    Returns `[(fid, kind, center_xy, ring_xy_or_None), ...]`.
    """
    if md is None:
        return []
    import mapcells

    cx = 0.5 * (box[0] + box[2])
    cy = 0.5 * (box[1] + box[3])
    half = 0.5 * max(box[2] - box[0], box[3] - box[1]) + SEARCH_MARGIN_M
    lat0, lon0, _ = frame.enu_to_geodetic(cx, cy, 0.0)
    if not bool(germany.in_box(float(lon0), float(lat0))[0]):
        # Double-check box corners against germany.BOX before bailing.
        x0, y0, x1, y1 = box[:4]
        la_c, lo_c, _ = frame.enu_to_geodetic(
            np.array([x0, x1, x0, x1], dtype=np.float64),
            np.array([y0, y0, y1, y1], dtype=np.float64),
            0.0,
        )
        if not germany.touches(lo_c, la_c):
            return []

    dlat = half / 111320.0
    dlon = half / (111320.0 * max(0.2, math.cos(math.radians(float(lat0)))))
    bbox_cells = list(
        mapcells.cells_for_bbox(float(lat0) - dlat, float(lon0) - dlon, float(lat0) + dlat, float(lon0) + dlon)
    )

    seen: set[str] = set()
    raw: list[tuple[str, str, np.ndarray, np.ndarray | None]] = []
    for cell_key in bbox_cells:
        try:
            cd = md.cell(cell_key, layers=("infrastructure", "land_use"), kind="demand")
        except Exception:
            continue
        layers = getattr(cd, "layers", None) or {}
        for layer_name in ("infrastructure", "land_use"):
            feats = layers.get(layer_name)
            for i, fid, kind in _extract_layer_rest_areas(feats, cell_key, layer_name):
                if fid in seen:
                    continue
                seen.add(fid)
                parts = feats.parts(i)
                if not parts or not parts[0] or len(parts[0][0]) < 1:
                    continue
                e, n = mapgeom.enu_xy(feats, frame, np.asarray(parts[0][0], np.float64))
                if len(e) == 0:
                    continue
                xy_pts = np.column_stack((e, n))
                if not np.isfinite(xy_pts).all():
                    continue
                center = np.array([float(np.mean(e)), float(np.mean(n))], dtype=np.float64)
                ring = xy_pts if len(xy_pts) >= 3 else None

                # Quick bounding relevance check to `box` (+ margin).
                if (
                    center[0] < box[0] - SEARCH_MARGIN_M
                    or center[0] > box[2] + SEARCH_MARGIN_M
                    or center[1] < box[1] - SEARCH_MARGIN_M
                    or center[1] > box[3] + SEARCH_MARGIN_M
                ):
                    continue

                # Generic `amenity=parking` must be adjacent to a motorway or trunk road.
                if kind == "parking":
                    if _min_dist_to_highway(center, near_roads) > HIGHWAY_ADJACENT_MAX_M:
                        continue

                raw.append((fid, kind, center, ring))

    # Prefer `services` over `rest_area` over `parking` and deduplicate overlapping sites.
    priority = {"services": 0, "rest_area": 1, "parking": 2}
    raw.sort(key=lambda r: (priority.get(r[1], 9), r[0]))

    deduped: list[tuple[str, str, np.ndarray, np.ndarray | None]] = []
    for fid, kind, center, ring in raw:
        if len(deduped) >= MAX_REST_AREAS_PER_TILE:
            break
        if any(math.hypot(float(center[0] - c[0]), float(center[1] - c[1])) < 28.0 for _, _, c, _ in deduped):
            continue
        deduped.append((fid, kind, center, ring))
    return deduped


def _is_prop_safe(
    xy: np.ndarray,
    along: np.ndarray,
    toward: np.ndarray,
    group: str,
    box: tuple[float, float, float, float],
    all_road_bands: list,
    tram_lines: list[np.ndarray],
    rings_clean: list[np.ndarray],
    placed_xy: list[tuple[float, float]],
    min_spacing_m: float = MIN_PROP_SPACING_M,
) -> bool:
    """Verify prop footprint strictly clears all road carriageways (>= 0.65 m), buildings, trams, and peers."""
    px, py = float(xy[0]), float(xy[1])
    if not (math.isfinite(px) and math.isfinite(py)):
        return False
    if not roadsmod.box_owns(box, px, py):
        return False
    if any(math.hypot(px - ox, py - oy) < min_spacing_m for ox, oy in placed_xy):
        return False
    hx, hy = _PROP_HALF_EXTENTS.get(group, (0.35, 0.35))
    if not furniture_de._is_safe_footprint(
        xy,
        along,
        toward,
        hx,
        hy,
        all_road_bands,
        tram_lines,
        rings_clean,
        extra_clear_m=ROAD_CLEAR_M,
    ):
        return False
    return True


def _plan_site_props(
    fid: str,
    kind: str,
    center: np.ndarray,
    ring: np.ndarray | None,
    box: tuple[float, float, float, float],
    near_roads: list,
    all_road_bands: list,
    tram_lines: list[np.ndarray],
    rings_clean: list[np.ndarray],
    placed_xy: list[tuple[float, float]],
    level: str,
    fast_pass: bool,
) -> list[tuple[str, np.ndarray, float]]:
    """Build candidate rest-area furniture & signs for one site, returning `[(group, xy, yaw_deg), ...]`."""
    hit = _nearest_road_frame(center, near_roads)
    if hit is None:
        return []
    edge_d, q, tang, away, hw = hit
    toward = -away

    # Anchor base point safely off the carriageway if the OSM node sits on/near the road.
    if edge_d < ROAD_CLEAR_M + 2.5:
        anchor = q + away * (hw + ROAD_CLEAR_M + 3.5)
    else:
        anchor = center.copy()

    light_mode = (level == "low") or bool(fast_pass)
    is_services = kind == "services"

    out: list[tuple[str, np.ndarray, float]] = []

    def _try_place(group: str, cand_xy: np.ndarray, yaw_deg: float, min_sp: float = MIN_PROP_SPACING_M) -> bool:
        if not _is_prop_safe(
            cand_xy, tang, toward, group, box, all_road_bands, tram_lines, rings_clean, placed_xy, min_spacing_m=min_sp
        ):
            return False
        out.append((group, cand_xy, round(yaw_deg % 360.0, 2)))
        placed_xy.append((float(cand_xy[0]), float(cand_xy[1])))
        return True

    base_yaw = _yaw_deg(float(tang[0]), float(tang[1]))
    sign_yaw = (base_yaw - 90.0) % 360.0

    # 1. Rest-area 30 km/h speed limit sign (`de_sign_274_30`) on the verge facing approaching traffic.
    for s_along in (-10.0, -6.0, 6.0, 10.0):
        placed_sign = False
        for d_out in (1.15, 1.85, 2.65):
            cand = q + tang * s_along + away * (hw + d_out)
            if _try_place("de_sign_274_30", cand, sign_yaw):
                placed_sign = True
                break
        if placed_sign:
            break

    # 2. Picnic tables & benches + accompanying waste bins.
    # For polygon rest areas, also gather quiet edge points away from the carriageway.
    picnic_slots: list[np.ndarray] = []
    if ring is not None and len(ring) >= 3:
        # Pick vertices farthest from the nearest road centerline (back edge of the rest area).
        dists = np.hypot(ring[:, 0] - q[0], ring[:, 1] - q[1])
        order = np.argsort(-dists)
        for idx in order[:4]:
            v = ring[int(idx)]
            inward = center - v
            il = float(np.hypot(inward[0], inward[1]))
            step_in = (inward / il) * 2.2 if il > 1.0 else np.zeros(2, dtype=np.float64)
            picnic_slots.append(v + step_in)

    # Always include deterministic grid offsets around `anchor` (works for both point & polygon features).
    s_offsets = (-7.0, 0.0, 7.0) if (is_services and not light_mode) else (-4.5, 4.5)
    d_offsets = (0.0, 4.0, 8.0)
    for d_off in d_offsets:
        for s_off in s_offsets:
            picnic_slots.append(anchor + tang * s_off + away * d_off)

    max_tables = 1 if light_mode else (3 if is_services else 2)
    tables_placed = 0
    for slot in picnic_slots:
        if tables_placed >= max_tables:
            break
        jitter = (_hash01(fid, "tbl", tables_placed) - 0.5) * 0.6
        cand = slot + tang * jitter
        if _try_place("picnictable", cand, base_yaw):
            tables_placed += 1
            # Place a waste bin next to the first picnic table.
            if tables_placed == 1:
                for b_off in (2.1, -2.1):
                    if _try_place("bin", cand + tang * b_off, base_yaw, min_sp=1.35):
                        break

    # 3. Benches & bins along the seating edge.
    max_benches = 1 if light_mode else 2
    benches_placed = 0
    for s_off in (-3.5, 3.5, -10.5, 10.5):
        if benches_placed >= max_benches:
            break
        for d_off in (1.5, 5.5):
            cand = anchor + tang * s_off + away * d_off
            if _try_place("bench", cand, base_yaw):
                benches_placed += 1
                break

    if not light_mode:
        # Recycling bin for full Raststätten (`services`) or secondary bin for Parkplätze.
        rec_group = "recyclebin" if is_services else "bin"
        for s_off in (6.5, -6.5, 11.5):
            if _try_place(rec_group, anchor + tang * s_off + away * 2.0, base_yaw):
                break

    # 4. European steel street lamps (`eu_lamp_steel`) lighting the rest area.
    max_lamps = 1 if light_mode else (2 if is_services else 1)
    lamps_placed = 0
    for s_off in (-9.0, 9.0, 0.0):
        if lamps_placed >= max_lamps:
            break
        for d_off in (2.5, 6.5):
            cand = anchor + tang * s_off + away * d_off
            if _try_place("eu_lamp_steel", cand, base_yaw):
                lamps_placed += 1
                break

    # 5. German Leitpfosten (`eu_marker_de`) framing the entrance verge cleanly off the asphalt.
    if not light_mode:
        for s_off in (-14.0, 14.0):
            cand = q + tang * s_off + away * (hw + 0.95)
            _try_place("eu_marker_de", cand, base_yaw, min_sp=1.2)

    return out


def plan_de_rest_areas(
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
) -> list[list]:
    """Plan German Autobahn rest-area & parking-area Forest props inside `box`.

    Returns `prop_rows`: `[[group, x, y, z, yaw_deg, 1.0, height_m, 0.0], ...]`.
    """
    if md is None or not near_roads:
        return []

    sites = extract_osm_rest_areas(md, frame, box, near_roads)
    if not sites:
        return []

    all_road_bands = furniture_de._all_road_bands(near_roads)
    tram_lines = classifier.tram_polylines(md, frame, tx, ty) if md is not None else []
    rings_clean = rings_arr if rings_arr is not None else []

    placed_xy: list[tuple[float, float]] = []
    candidates: list[tuple[str, np.ndarray, float]] = []
    for fid, kind, center, ring in sites:
        candidates.extend(
            _plan_site_props(
                fid,
                kind,
                center,
                ring,
                box,
                near_roads,
                all_road_bands,
                tram_lines,
                rings_clean,
                placed_xy,
                level=level,
                fast_pass=fast_pass,
            )
        )

    if not candidates:
        return []

    xs = np.array([float(p[1][0]) for p in candidates], dtype=np.float64)
    ys = np.array([float(p[1][1]) for p in candidates], dtype=np.float64)
    in_de = germany.de_at(frame, xs, ys)
    zs = np.asarray(ground(xs, ys), dtype=np.float64) if ground is not None else np.zeros(len(xs), dtype=np.float64)

    prop_rows: list[list] = []
    for idx, (group, xy, yaw) in enumerate(candidates):
        if not bool(in_de[idx]):
            continue
        z_val = float(zs[idx])
        if not math.isfinite(z_val):
            continue
        h_m = PROP_HEIGHTS_M[group]
        prop_rows.append([
            group,
            round(float(xy[0]), 3),
            round(float(xy[1]), 3),
            round(z_val, 3),
            round(float(yaw), 2),
            1.0,
            h_m,
            0.0,
        ])

    return prop_rows
