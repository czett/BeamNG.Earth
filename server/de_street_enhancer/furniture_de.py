"""German street furniture & transit stops batched into `destreets.cdae` (`BNE_DE_STREET_IMMERSION=on`).

Places:
- Bus stops (`Bushaltestellen`): cantilevered dark-steel & blue-grey glass shelter + bench +
  galvanized post with yellow/green StVO 224 `H` sign, real OSM stop name, and timetable vitrine.
- Utility cabinets (`Stromkästen`): mapped `man_made=street_cabinet` + deterministic sidewalk cabinets.
- DHL `Packstationen`: mapped `amenity=parcel_locker` stepped yellow/red locker banks.
- Glass recycling trios (`Altglascontainer`): mapped `amenity=recycling` (Weiss/Braun/Grün).
- Corner sidewalk bollards (`Poller`): slim anthracite + red/white reflective corner posts.

Zero extra runtime Materials or draw calls: all textures pack into `de_st_<hash>.dds`.
"""

from dataclasses import dataclass
import hashlib
import json
import math
import numpy as np

import dmath
import furniture
import germany
import mapgeom
import roads as roadsmod

from . import classifier
from . import texture_atlas


FURNITURE_SWATCH_KEY = "swatch|de_furniture"

_SWATCH_COORDS = {
    "stromkasten": (0.004, 0.06, 0.121, 0.94),
    "packstation": (0.129, 0.06, 0.246, 0.94),
    "altglas_w": (0.253, 0.06, 0.289, 0.94),
    "altglas_b": (0.294, 0.06, 0.330, 0.94),
    "altglas_g": (0.335, 0.06, 0.371, 0.94),
    "poller": (0.379, 0.06, 0.496, 0.94),
    "glass": (0.504, 0.06, 0.621, 0.94),
    "steel": (0.629, 0.06, 0.746, 0.94),
    "wood": (0.754, 0.06, 0.871, 0.94),
    "concrete": (0.879, 0.06, 0.996, 0.94),
}


ROAD_CLEAR_M = 0.45
BUS_OUTER_CLEAR_M = 0.50
TRAM_CLEAR_M = 2.20
MIN_ISLAND_WIDTH_M = 3.00
BOLLARD_KERB_CLEAR_M = 0.35
DOOR_CLEAR_M = 2.50
MAX_PROC_CABINETS_PER_TILE = 2


@dataclass(frozen=True)
class BusStopItem:
    xy: np.ndarray
    z: float
    along: np.ndarray      # unit vector along street
    toward_road: np.ndarray  # unit vector facing carriageway
    name: str
    has_shelter: bool = True


@dataclass(frozen=True)
class BoxPropItem:
    kind: str              # "stromkasten" | "packstation" | "altglas"
    xy: np.ndarray
    z: float
    along: np.ndarray
    toward_road: np.ndarray


@dataclass(frozen=True)
class BollardItem:
    xy: np.ndarray
    z: float


@dataclass(frozen=True)
class FuelPylonItem:
    xy: np.ndarray
    z: float
    along: np.ndarray
    toward_road: np.ndarray
    brand_key: str
    brand_label: str
    e10: str
    e5: str
    diesel: str


@dataclass(frozen=True)
class FurniturePlan:
    bus_stops: tuple[BusStopItem, ...]
    cabinets: tuple[BoxPropItem, ...]
    lockers: tuple[BoxPropItem, ...]
    recyclers: tuple[BoxPropItem, ...]
    bollards: tuple[BollardItem, ...]
    suppressed_recycle_xy: tuple[tuple[float, float], ...]
    fuel_pylons: tuple[FuelPylonItem, ...] = ()

    @property
    def has_any(self) -> bool:
        return bool(
            self.bus_stops
            or self.cabinets
            or self.lockers
            or self.recyclers
            or self.bollards
            or self.fuel_pylons
        )


def _hash01(*parts) -> float:
    h = hashlib.blake2b("|".join(str(p) for p in parts).encode("utf-8"), digest_size=8).digest()
    return int.from_bytes(h, "big") / float(1 << 64)


def _finite_2d(pts, min_pts: int = 2) -> np.ndarray | None:
    if pts is None:
        return None
    arr = np.asarray(pts, dtype=np.float64)
    if arr.ndim != 2 or arr.shape[0] < min_pts or arr.shape[1] < 2:
        return None
    xy = np.ascontiguousarray(arr[:, :2], dtype=np.float64)
    return xy if (xy.size > 0 and np.isfinite(xy).all()) else None


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


def _all_road_bands(near_roads: list) -> list[tuple[np.ndarray, float]]:
    """Return `(xy_polyline, half_width)` for EVERY road segment in `near_roads`."""
    bands: list[tuple[np.ndarray, float]] = []
    for item in near_roads or ():
        sp, pts = item[1], _finite_2d(item[2], min_pts=2)
        if pts is not None:
            hw = float(getattr(sp, "width", 0.0) or 0.0) * 0.5
            bands.append((pts, hw))
    return bands


def _road_edge_clearances(pt: np.ndarray, road_bands: list[tuple[np.ndarray, float]]) -> list[tuple[float, np.ndarray]]:
    """Return `(edge_dist, unit_vec_to_road)` for each road band near `pt`."""
    px, py = float(pt[0]), float(pt[1])
    out: list[tuple[float, np.ndarray]] = []
    for pts, hw in road_bands:
        a, b = pts[:-1], pts[1:]
        ab = b - a
        l2 = np.maximum((ab * ab).sum(1), 1e-12)
        t = np.clip(((px - a[:, 0]) * ab[:, 0] + (py - a[:, 1]) * ab[:, 1]) / l2, 0.0, 1.0)
        q = a + t[:, None] * ab
        dist = np.hypot(px - q[:, 0], py - q[:, 1])
        k = int(np.argmin(dist))
        d_c = float(dist[k])
        edge_d = d_c - hw
        vec = np.array([float(q[k, 0]) - px, float(q[k, 1]) - py], dtype=np.float64)
        if d_c > 1e-6:
            vec /= d_c
        else:
            vec = np.array([0.0, 0.0], dtype=np.float64)
        out.append((edge_d, vec))
    return out


def _min_road_edge_dist(pt: np.ndarray, road_bands: list[tuple[np.ndarray, float]]) -> float:
    hits = _road_edge_clearances(pt, road_bands)
    return min((h[0] for h in hits), default=float("inf"))


def _is_narrow_island(pt: np.ndarray, road_bands: list[tuple[np.ndarray, float]], min_width_m: float = MIN_ISLAND_WIDTH_M) -> bool:
    """True when `pt` sits inside a narrow median or traffic island (`< min_width_m` between opposing carriageways)."""
    hits = [h for h in _road_edge_clearances(pt, road_bands) if h[0] < min_width_m + 2.0]
    if any(h[0] < 0.0 for h in hits):
        return True
    for i in range(len(hits)):
        d_i, v_i = hits[i]
        for j in range(i + 1, len(hits)):
            d_j, v_j = hits[j]
            if float(np.dot(v_i, v_j)) < -0.25 and (d_i + d_j) < min_width_m:
                return True
    return False


def _is_safe_footprint(
    center_xy: np.ndarray,
    along: np.ndarray,
    toward: np.ndarray,
    hx: float,
    hy: float,
    all_road_bands: list[tuple[np.ndarray, float]],
    tram_lines: list[np.ndarray],
    rings_arr: list[np.ndarray],
    extra_clear_m: float = ROAD_CLEAR_M,
) -> bool:
    """Verify center + oriented bounding-box corners clear all roads, tram tracks, narrow islands, and buildings."""
    if _is_narrow_island(center_xy, all_road_bands):
        return False
    c2 = np.asarray(center_xy[:2], dtype=np.float64)
    a2 = np.asarray(along[:2], dtype=np.float64)
    t2 = np.asarray(toward[:2], dtype=np.float64)
    pts = [c2]
    if hx > 0.0 or hy > 0.0:
        for sx in (-hx, hx):
            for sy in (-hy, hy):
                pts.append(c2 + a2 * sx + t2 * sy)
        if hx > 0.6:
            pts.append(c2 + t2 * hy)
            pts.append(c2 - t2 * hy)
    for p in pts:
        if not np.isfinite(p).all():
            return False
        if _min_road_edge_dist(p, all_road_bands) < extra_clear_m:
            return False
        if tram_lines and classifier.min_dist_to_polylines(p, tram_lines) < TRAM_CLEAR_M:
            return False
        if any(classifier._point_in_ring(p, rr) for rr in rings_arr):
            return False
    return True


def _outer_walk_polygons(walks: list | None) -> list[tuple[np.ndarray, np.ndarray]]:
    """Extract `(closed_poly_xy, curb_xy)` for all non-median, non-island sidewalk polygons."""
    import sidewalks

    out: list[tuple[np.ndarray, np.ndarray]] = []
    for wk in walks or ():
        if wk.get("median") or wk.get("fid") in ("island", "splitter") or "disc" in wk:
            continue
        if "corner" not in wk and "pts" not in wk:
            continue
        try:
            curb, back = sidewalks._slab_edges(wk)
        except Exception:
            continue
        c_xy = _finite_2d(curb, min_pts=2)
        b_xy = _finite_2d(back, min_pts=2)
        if c_xy is None or b_xy is None:
            continue
        poly = np.vstack((c_xy, b_xy[::-1]))
        if len(poly) >= 3 and np.isfinite(poly).all():
            out.append((poly, c_xy))
    return out


def _point_on_outer_walk(pt: np.ndarray, walk_polys: list[tuple[np.ndarray, np.ndarray]], min_kerb_m: float = 0.0) -> bool:
    for poly, curb in walk_polys:
        if classifier._point_in_ring(pt, poly):
            if min_kerb_m <= 0.0 or classifier.min_dist_to_polylines(pt, [curb]) >= min_kerb_m:
                return True
    return False


def _door_points(items: list | None, box: tuple[float, float, float, float]) -> list[tuple[float, float]]:
    """Collect world XY coordinates of all building `spec.door` entrances."""
    if not items:
        return []
    ox, oy = float(box[0]), float(box[1])
    out: list[tuple[float, float]] = []
    for item in items:
        spec = item[0]
        door = getattr(spec, "door", None)
        if door is None:
            continue
        ring = _finite_2d(getattr(spec, "ring", None), min_pts=3)
        if ring is None:
            continue
        edge_i, along_d = int(door[0]), float(door[1])
        if not (0 <= edge_i < len(ring)):
            continue
        a, b = ring[edge_i], ring[(edge_i + 1) % len(ring)]
        seg_l = float(math.hypot(float(b[0] - a[0]), float(b[1] - a[1])))
        if seg_l < 1e-4:
            continue
        d_along = (b - a) / seg_l
        dp = a + d_along * along_d
        out.append((ox + float(dp[0]), oy + float(dp[1])))
    return out


def _closest_road_edge(pt: np.ndarray, near_roads: list, max_dist: float = 28.0):
    """Return `(edge_dist, q_on_centerline, unit_tangent, toward_road, half_w, away)` or None."""
    px, py = float(pt[0]), float(pt[1])
    best = None
    for item in near_roads or ():
        sp, pts = item[1], _finite_2d(item[2], min_pts=2)
        if pts is None:
            continue
        cls = getattr(sp, "cls", "")
        if cls in ("service", "track", "footway", "cycleway", "path", "steps"):
            continue
        hw = float(getattr(sp, "width", 0.0) or 0.0) * 0.5
        a, b = pts[:-1], pts[1:]
        ab = b - a
        l2 = np.maximum((ab * ab).sum(1), 1e-12)
        t = np.clip(((px - a[:, 0]) * ab[:, 0] + (py - a[:, 1]) * ab[:, 1]) / l2, 0.0, 1.0)
        q = a + t[:, None] * ab
        dist = np.hypot(px - q[:, 0], py - q[:, 1])
        k = int(np.argmin(dist))
        edge_d = float(dist[k]) - hw
        if best is None or edge_d < best[0]:
            seg = ab[k]
            sl = max(float(np.hypot(seg[0], seg[1])), 1e-9)
            tang = np.array([seg[0] / sl, seg[1] / sl], dtype=np.float64)
            v_from_road = np.array([px - float(q[k, 0]), py - float(q[k, 1])], dtype=np.float64)
            vl = float(np.hypot(v_from_road[0], v_from_road[1]))
            away = (v_from_road / vl) if vl > 1e-4 else np.array([-tang[1], tang[0]], dtype=np.float64)
            best = (edge_d, q[k], tang, -away, hw, away)
    if best is None or best[0] > max_dist:
        return None
    return best


def _snap_to_outer_sidewalk(
    pt: np.ndarray,
    near_roads: list,
    all_road_bands: list[tuple[np.ndarray, float]],
    tram_lines: list[np.ndarray],
    walk_polys: list[tuple[np.ndarray, np.ndarray]],
    rings_arr: list[np.ndarray],
    min_front_clear_m: float,
    hx: float,
    hy: float,
    is_bus_stop: bool = False,
) -> tuple[np.ndarray, np.ndarray, np.ndarray] | None:
    """Snap `pt` strictly to the outer sidewalk edge clearing all carriageways, trams, and narrow islands."""
    hit = _closest_road_edge(pt, near_roads)
    if hit is None:
        return None
    _edge_d, q, tang, _toward, hw, orig_away = hit
    left = np.array([-tang[1], tang[0]], dtype=np.float64)
    orig_side_sign = float(np.dot(pt - q, left))

    best_score = -float("inf")
    best_res = None
    target_center_offset = hw + min_front_clear_m + hy

    for sgn in (1.0, -1.0):
        away = left * sgn
        toward = -away
        along = tang * sgn  # keeps right-hand orientation consistent
        # If pt is already cleanly past target_center_offset on this side, preserve its lateral depth up to 6 m.
        lat_d = float(np.dot(pt - q, away))
        if abs(orig_side_sign) >= 0.4 and (lat_d >= target_center_offset) and (lat_d <= hw + 6.0):
            pos = np.array([float(pt[0]), float(pt[1])], dtype=np.float64)
        else:
            pos = q + away * target_center_offset

        if not _is_safe_footprint(pos, along, toward, hx, hy, all_road_bands, tram_lines, rings_arr, extra_clear_m=ROAD_CLEAR_M):
            continue
        if is_bus_stop and hx >= 1.0:
            # Also check the H-sign pole at +1.75 m along the street.
            post_xy = pos + along * 1.75
            if not _is_safe_footprint(post_xy, along, toward, 0.23, 0.05, all_road_bands, tram_lines, rings_arr, extra_clear_m=BUS_OUTER_CLEAR_M):
                continue

        score = 0.0
        if _point_on_outer_walk(pos, walk_polys):
            score += 10.0
        if tram_lines:
            score += min(10.0, classifier.min_dist_to_polylines(pos, tram_lines))
        if float(np.dot(away, orig_away)) > 0.5 and abs(orig_side_sign) >= 0.4:
            score += 2.5
        if score > best_score:
            best_score = score
            best_res = (pos, along, toward)

    return best_res


_FUEL_BRAND_MAP = {
    "aral": ("aral", "ARAL"),
    "shell": ("shell", "SHELL"),
    "esso": ("esso", "ESSO"),
    "jet": ("jet", "JET"),
    "total": ("totalenergies", "TOTAL"),
    "totalenergies": ("totalenergies", "TOTAL"),
    "avia": ("avia", "AVIA"),
    "bft": ("bft", "bft"),
    "star": ("star", "STAR"),
}


def _match_fuel_brand(name_str: str) -> tuple[str, str]:
    low = (name_str or "").strip().lower()
    for token, pair in _FUEL_BRAND_MAP.items():
        if token in low:
            return pair
    return ("fuel_generic", "TANKSTELLE")


def _fuel_prices_for(seed_parts: tuple) -> tuple[str, str, str]:
    step = int(_hash01(*seed_parts, "fuel_e10") * 12)
    e10_c = 171 + step
    e5_c = e10_c + 6
    diesel_c = e10_c - 8
    return f"{e10_c / 100.0:.2f}9", f"{e5_c / 100.0:.2f}9", f"{diesel_c / 100.0:.2f}9"


def plan_de_street_furniture(
    md,
    frame,
    box: tuple[float, float, float, float],
    near_roads: list,
    walks: list | None,
    props: list | None,
    drives: list[dict] | None,
    garage_drives: list[dict] | None,
    rings: list[np.ndarray] | None,
    ground,
    items: list | None = None,
    tx: int | None = None,
    ty: int | None = None,
) -> FurniturePlan:
    """Plan German bus stops, Stromkästen, Packstationen, Altglascontainer, and corner bollards."""
    empty = FurniturePlan((), (), (), (), (), ())
    if not near_roads:
        return empty

    all_road_bands = _all_road_bands(near_roads)
    tram_lines = classifier.tram_polylines(md, frame, tx, ty)
    walk_polys = _outer_walk_polygons(walks)
    door_pts = _door_points(items, box)
    rings_arr = [rr for r in (rings or ()) if (rr := _finite_2d(r, min_pts=3)) is not None]
    drive_pts: list[tuple[float, float]] = []
    for d in list(drives or ()) + list(garage_drives or ()):
        xy = _finite_2d(d.get("n"), min_pts=2)
        if xy is not None:
            drive_pts.append((float(xy[-1, 0]), float(xy[-1, 1])))

    junc_pts: list[tuple[float, float]] = []
    arms_map = furniture._arms(near_roads) or {}
    for _k, arms in arms_map.items():
        if len(arms) >= 2:
            p = np.asarray(arms[0][3], dtype=np.float64)
            junc_pts.append((float(p[0]), float(p[1])))

    bus_raw: list[tuple[np.ndarray, np.ndarray, np.ndarray, str, bool]] = []
    cab_raw: list[tuple[np.ndarray, np.ndarray, np.ndarray]] = []
    lock_raw: list[tuple[np.ndarray, np.ndarray, np.ndarray]] = []
    rec_raw: list[tuple[np.ndarray, np.ndarray, np.ndarray]] = []
    fuel_cands: list[tuple[np.ndarray, str, str]] = []
    sup_rec_xy: list[tuple[float, float]] = []

    if md is not None:
        import mapcells

        cx = 0.5 * (box[0] + box[2])
        cy = 0.5 * (box[1] + box[3])
        half = 0.5 * max(box[2] - box[0], box[3] - box[1]) + 20.0
        lat0, lon0, _ = frame.enu_to_geodetic(cx, cy, 0.0)
        dlat = half / 111320.0
        dlon = half / (111320.0 * max(0.2, math.cos(math.radians(float(lat0)))))
        seen: set[str] = set()
        for cell_key in mapcells.cells_for_bbox(float(lat0) - dlat, float(lon0) - dlon, float(lat0) + dlat, float(lon0) + dlon):
            try:
                cd = md.cell(cell_key, layers=("infrastructure",), kind="demand")
                feats = cd.layers.get("infrastructure")
            except Exception:
                continue
            if feats is None or len(feats) == 0:
                continue
            cls_arr = feats.attrs.get("class")
            name_arr = feats.attrs.get("name")
            tags_arr = feats.attrs.get("tags")
            for i in range(len(feats)):
                fid = str(feats.ids[i]) if getattr(feats, "ids", None) is not None else f"{cell_key}:{i}"
                if fid in seen:
                    continue
                cls_v = str(cls_arr[i] or "").lower() if cls_arr is not None else ""
                tags = _parse_tags(tags_arr[i] if tags_arr is not None else None)
                hwy = str(tags.get("highway", "")).lower()
                pt_tag = str(tags.get("public_transport", "")).lower()
                am = str(tags.get("amenity", "")).lower()
                mm = str(tags.get("man_made", "")).lower()

                is_bus = cls_v == "bus_stop" or hwy == "bus_stop" or am == "bus_stop" or pt_tag == "platform"
                is_cab = mm == "street_cabinet" or cls_v == "street_cabinet"
                is_locker = am == "parcel_locker" or cls_v == "parcel_locker"
                is_recycle = (am == "recycling" or cls_v == "recycling") and str(tags.get("recycling_type", "")).lower() != "centre"
                is_fuel = am == "fuel" or cls_v == "fuel"
                if not (is_bus or is_cab or is_locker or is_recycle or is_fuel):
                    continue
                seen.add(fid)
                parts = feats.parts(i)
                if not parts or not parts[0] or len(parts[0][0]) < 1:
                    continue
                e, n = mapgeom.enu_xy(feats, frame, np.asarray(parts[0][0], np.float64))
                if len(e) == 0:
                    continue
                pt = np.array([float(np.mean(e)), float(np.mean(n))], dtype=np.float64)
                if not roadsmod.box_owns(box, float(pt[0]), float(pt[1])):
                    continue

                if is_fuel:
                    f_name = ""
                    if name_arr is not None and name_arr[i]:
                        f_name = str(name_arr[i])
                    if not f_name:
                        f_name = str(tags.get("brand") or tags.get("name") or "")
                    fuel_cands.append((pt, fid, f_name))
                elif is_bus:
                    no_shelter = str(tags.get("shelter", "")).lower() in ("no", "none", "false", "0") or (
                        pt_tag == "stop_position" and str(tags.get("shelter", "")).lower() != "yes"
                    )
                    snapped = None
                    has_shelter = False
                    if not no_shelter:
                        snapped = _snap_to_outer_sidewalk(
                            pt, near_roads, all_road_bands, tram_lines, walk_polys, rings_arr,
                            min_front_clear_m=BUS_OUTER_CLEAR_M, hx=1.45, hy=0.72, is_bus_stop=True,
                        )
                        has_shelter = snapped is not None
                    if snapped is None:
                        snapped = _snap_to_outer_sidewalk(
                            pt, near_roads, all_road_bands, tram_lines, walk_polys, rings_arr,
                            min_front_clear_m=BUS_OUTER_CLEAR_M, hx=0.23, hy=0.05, is_bus_stop=False,
                        )
                        has_shelter = False
                    if snapped is not None:
                        s_name = ""
                        if name_arr is not None and name_arr[i]:
                            s_name = str(name_arr[i])
                        if not s_name:
                            s_name = str(tags.get("name") or "Haltestelle")
                        bus_raw.append((*snapped, s_name, has_shelter))
                elif is_cab:
                    snapped = _snap_to_outer_sidewalk(
                        pt, near_roads, all_road_bands, tram_lines, walk_polys, rings_arr,
                        min_front_clear_m=ROAD_CLEAR_M, hx=0.48, hy=0.22,
                    )
                    if snapped is not None:
                        pos, _, _ = snapped
                        if not any(math.hypot(float(pos[0]) - dx, float(pos[1]) - dy) < DOOR_CLEAR_M for dx, dy in door_pts):
                            cab_raw.append(snapped)
                elif is_locker:
                    snapped = _snap_to_outer_sidewalk(
                        pt, near_roads, all_road_bands, tram_lines, walk_polys, rings_arr,
                        min_front_clear_m=ROAD_CLEAR_M, hx=1.24, hy=0.38,
                    )
                    if snapped is not None:
                        lock_raw.append(snapped)
                elif is_recycle:
                    snapped = _snap_to_outer_sidewalk(
                        pt, near_roads, all_road_bands, tram_lines, walk_polys, rings_arr,
                        min_front_clear_m=ROAD_CLEAR_M, hx=1.36, hy=0.44,
                    )
                    if snapped is not None:
                        rec_raw.append(snapped)
                        sup_rec_xy.append((float(pt[0]), float(pt[1])))

        # Also scan Overture `places` for fuel stations when `infrastructure` had none at that site.
        for cell_key in mapcells.cells_for_bbox(float(lat0) - dlat, float(lon0) - dlon, float(lat0) + dlat, float(lon0) + dlon):
            try:
                cd = md.cell(cell_key, layers=("places",), kind="demand")
                p_feats = cd.layers.get("places")
            except Exception:
                continue
            if p_feats is None or len(p_feats) == 0:
                continue
            for cand, xy_local in classifier.load_tile_pois(md, frame, [(cell_key, p_feats)], 0.0, 0.0):
                cat = (cand.category or "").lower()
                if cat not in ("gas_station", "fueling_station"):
                    continue
                if not roadsmod.box_owns(box, float(xy_local[0]), float(xy_local[1])):
                    continue
                if any(math.hypot(float(xy_local[0]) - float(fp[0]), float(xy_local[1]) - float(fp[1])) < 35.0 for fp, _, _ in fuel_cands):
                    continue
                fuel_cands.append((xy_local, cand.fid, cand.brand or cand.name or ""))

    fuel_raw: list[tuple[np.ndarray, np.ndarray, np.ndarray, str, str, str, str, str]] = []
    placed_fuel_xy: list[tuple[float, float]] = []
    for f_pt, f_id, f_name in fuel_cands:
        if any(math.hypot(float(f_pt[0]) - px, float(f_pt[1]) - py) < 35.0 for px, py in placed_fuel_xy):
            continue
        snapped = _snap_to_outer_sidewalk(
            f_pt, near_roads, all_road_bands, tram_lines, walk_polys, rings_arr,
            min_front_clear_m=0.55, hx=0.62, hy=0.18,
        )
        if snapped is None:
            continue
        pos, along, toward = snapped
        px, py = float(pos[0]), float(pos[1])
        if not roadsmod.box_owns(box, px, py):
            continue
        if any(math.hypot(px - dx, py - dy) < 1.50 for dx, dy in drive_pts):
            continue
        if any(math.hypot(px - dx, py - dy) < 1.50 for dx, dy in door_pts):
            continue
        b_key, b_lbl = _match_fuel_brand(f_name)
        e10, e5, diesel = _fuel_prices_for((f_id, round(px, 1), round(py, 1)))
        fuel_raw.append((pos, along, toward, b_key, b_lbl, e10, e5, diesel))
        placed_fuel_xy.append((px, py))

    # Procedural deterministic Stromkästen (max 1-2 per 256m tile at street corners, flush on outer walk back edge).
    occupied_xy: list[tuple[float, float]] = [(float(p[0]), float(p[1])) for p, _, _, _, _ in bus_raw]
    occupied_xy.extend((float(p[0]), float(p[1])) for p, _, _ in cab_raw)
    occupied_xy.extend((float(p[0]), float(p[1])) for p, _, _ in lock_raw)
    occupied_xy.extend((float(p[0]), float(p[1])) for p, _, _ in rec_raw)

    proc_cab_cands: list[tuple[float, np.ndarray, np.ndarray, np.ndarray]] = []
    for wk in walks or ():
        fid = wk.get("fid")
        pts = _finite_2d(wk.get("pts"), min_pts=2)
        if fid is None or pts is None or wk.get("median") or fid in ("island", "splitter"):
            continue
        side = int(wk.get("side", 1))
        wk_w = float(wk.get("w", roadsmod.SIDEWALK["w"]))
        d = pts[1:] - pts[:-1]
        seg_l = np.hypot(d[:, 0], d[:, 1])
        total = float(seg_l.sum())
        if total < 14.0:
            continue
        cum = np.concatenate(([0.0], np.cumsum(seg_l)))
        for station in (8.5 + _hash01(fid, side, "strom0") * 6.0, total - 8.5 - _hash01(fid, side, "strom1") * 6.0):
            if station < 4.0 or station > total - 4.0:
                continue
            idx = max(0, min(len(seg_l) - 1, int(np.searchsorted(cum, station, side="right") - 1)))
            sl = float(seg_l[idx])
            if sl <= 1e-4:
                continue
            t = (station - float(cum[idx])) / sl
            c_pt = pts[idx] + t * d[idx]
            tang = d[idx] / sl
            left = np.array([-tang[1], tang[0]], dtype=np.float64)
            away = left * float(side)
            pos = c_pt + away * max(0.35, wk_w * 0.5 - 0.16)
            px, py = float(pos[0]), float(pos[1])
            if not roadsmod.box_owns(box, px, py):
                continue
            j_dists = [math.hypot(px - jx, py - jy) for jx, jy in junc_pts]
            min_j = min(j_dists) if j_dists else 18.0
            if min_j < 6.0 or (j_dists and min_j > 26.0):
                continue
            if any(math.hypot(px - dx, py - dy) < 2.5 for dx, dy in drive_pts):
                continue
            if any(math.hypot(px - dx, py - dy) < DOOR_CLEAR_M for dx, dy in door_pts):
                continue
            if any(math.hypot(px - ox, py - oy) < 10.0 for ox, oy in occupied_xy):
                continue
            if not _is_safe_footprint(pos, tang, -away, 0.48, 0.22, all_road_bands, tram_lines, rings_arr, extra_clear_m=ROAD_CLEAR_M):
                continue
            proc_cab_cands.append((min_j + _hash01(fid, side, int(station)), pos, tang, -away))

    proc_cab_cands.sort(key=lambda c: c[0])
    proc_added = 0
    for _sc, pos, tang, toward in proc_cab_cands:
        if proc_added >= MAX_PROC_CABINETS_PER_TILE:
            break
        px, py = float(pos[0]), float(pos[1])
        if any(math.hypot(px - ox, py - oy) < 10.0 for ox, oy in occupied_xy):
            continue
        cab_raw.append((pos, tang, toward))
        occupied_xy.append((px, py))
        proc_added += 1

    # Corner sidewalk bollards (`Poller`) placed ONLY on real outer sidewalk polygons >= 0.35 m behind kerb.
    bollard_raw: list[np.ndarray] = []
    ax_default = np.array([1.0, 0.0, 0.0], dtype=np.float64)
    ay_default = np.array([0.0, 1.0, 0.0], dtype=np.float64)

    def _try_add_bollard(b_pt: np.ndarray) -> bool:
        bx, by = float(b_pt[0]), float(b_pt[1])
        if not roadsmod.box_owns(box, bx, by):
            return False
        if not _point_on_outer_walk(b_pt, walk_polys, min_kerb_m=BOLLARD_KERB_CLEAR_M):
            return False
        if any(math.hypot(bx - ox, by - oy) < 1.8 for ox, oy in occupied_xy):
            return False
        if any(math.hypot(bx - dx, by - dy) < 2.2 for dx, dy in drive_pts):
            return False
        if any(math.hypot(bx - bx2, by - by2) < 0.75 for bx2, by2 in ((float(p[0]), float(p[1])) for p in bollard_raw)):
            return False
        if not _is_safe_footprint(b_pt, ax_default, ay_default, 0.08, 0.08, all_road_bands, tram_lines, rings_arr, extra_clear_m=ROAD_CLEAR_M):
            return False
        bollard_raw.append(b_pt)
        return True

    # 1. Prefer explicit `corner` curb-return sidewalk polygons from `walks`.
    for wk in walks or ():
        if "corner" not in wk or wk.get("median"):
            continue
        c = wk["corner"]
        arc = _finite_2d(c.get("arc"), min_pts=2)
        inward = _finite_2d(c.get("inward"), min_pts=2)
        if arc is None or inward is None or len(arc) != len(inward):
            continue
        mid_i = len(arc) // 2
        if not any(math.hypot(float(arc[mid_i, 0]) - jx, float(arc[mid_i, 1]) - jy) < 22.0 for jx, jy in junc_pts):
            continue
        for idx_c in sorted({max(0, mid_i - 1), mid_i, min(len(arc) - 1, mid_i + 1)}):
            in_v = inward[idx_c]
            in_l = float(np.hypot(in_v[0], in_v[1]))
            if in_l < 1e-4:
                continue
            _try_add_bollard(arc[idx_c] + (in_v / in_l) * 0.55)

    # 2. Fallback for 3+ arm junctions with `pts` sidewalks (sort ALL arms so reflex/primary arms are never skipped).
    if not bollard_raw:
        for _k, arms in arms_map.items():
            if len(arms) < 3:
                continue
            if sum(1 for a in arms if getattr(a[1], "cls", "") in ("residential", "tertiary", "secondary", "unclassified")) < 2:
                continue
            p = np.asarray(arms[0][3], dtype=np.float64)
            jx, jy = float(p[0]), float(p[1])
            if not roadsmod.box_owns(box, jx, jy):
                continue
            ordered = sorted(arms, key=lambda a: math.atan2(float(a[2][1]), float(a[2][0])))
            placed_at_j = 0
            for a_idx in range(len(ordered)):
                if placed_at_j >= 4:
                    break
                a0 = ordered[a_idx]
                a1 = ordered[(a_idx + 1) % len(ordered)]
                th0 = math.atan2(float(a0[2][1]), float(a0[2][0]))
                th1 = math.atan2(float(a1[2][1]), float(a1[2][0]))
                dth = (th1 - th0) % (2.0 * math.pi)
                if dth < 0.35 or dth > math.pi - 0.15:
                    continue
                bis_th = th0 + dth * 0.5
                bis = np.array([math.cos(bis_th), math.sin(bis_th)], dtype=np.float64)
                hw_max = max(float(getattr(a0[1], "width", 6.0) or 6.0), float(getattr(a1[1], "width", 6.0) or 6.0)) * 0.5
                corner_pt = np.array([jx, jy], dtype=np.float64) + bis * (hw_max * 1.414 + 0.75)
                tang_c = np.array([-bis[1], bis[0]], dtype=np.float64)
                for s_off in (-0.95, 0.0, 0.95):
                    if _try_add_bollard(corner_pt + tang_c * s_off):
                        placed_at_j += 1

    # Filter all points strictly inside DE and sample ground heights in a single batch.
    all_pts: list[np.ndarray] = (
        [x[0] for x in bus_raw]
        + [x[0] for x in cab_raw]
        + [x[0] for x in lock_raw]
        + [x[0] for x in rec_raw]
        + [x[0] for x in fuel_raw]
        + bollard_raw
    )
    if not all_pts:
        return empty
    xs = np.array([float(p[0]) for p in all_pts], dtype=np.float64)
    ys = np.array([float(p[1]) for p in all_pts], dtype=np.float64)
    in_de = germany.de_at(frame, xs, ys)
    zs = np.asarray(ground(xs, ys), dtype=np.float64) if ground is not None else np.zeros(len(xs), dtype=np.float64)

    cur = 0
    bus_out: list[BusStopItem] = []
    for pos, along, toward, nm, has_sh in bus_raw:
        if in_de[cur] and np.isfinite(zs[cur]):
            bus_out.append(BusStopItem(pos, float(zs[cur]), along, toward, nm, has_shelter=has_sh))
        cur += 1
    cab_out: list[BoxPropItem] = []
    for pos, along, toward in cab_raw:
        if in_de[cur] and np.isfinite(zs[cur]):
            cab_out.append(BoxPropItem("stromkasten", pos, float(zs[cur]), along, toward))
        cur += 1
    lock_out: list[BoxPropItem] = []
    for pos, along, toward in lock_raw:
        if in_de[cur] and np.isfinite(zs[cur]):
            lock_out.append(BoxPropItem("packstation", pos, float(zs[cur]), along, toward))
        cur += 1
    rec_out: list[BoxPropItem] = []
    for pos, along, toward in rec_raw:
        if in_de[cur] and np.isfinite(zs[cur]):
            rec_out.append(BoxPropItem("altglas", pos, float(zs[cur]), along, toward))
        cur += 1
    fuel_out: list[FuelPylonItem] = []
    for pos, along, toward, b_key, b_lbl, e10, e5, diesel in fuel_raw:
        if in_de[cur] and np.isfinite(zs[cur]):
            fuel_out.append(FuelPylonItem(pos, float(zs[cur]), along, toward, b_key, b_lbl, e10, e5, diesel))
        cur += 1
    bollard_out: list[BollardItem] = []
    for pos in bollard_raw:
        if in_de[cur] and np.isfinite(zs[cur]):
            bollard_out.append(BollardItem(pos, float(zs[cur])))
        cur += 1

    return FurniturePlan(
        bus_stops=tuple(bus_out),
        cabinets=tuple(cab_out),
        lockers=tuple(lock_out),
        recyclers=tuple(rec_out),
        bollards=tuple(bollard_out),
        suppressed_recycle_xy=tuple(sup_rec_xy),
        fuel_pylons=tuple(fuel_out),
    )


def append_furniture_geometry(mb, plan: FurniturePlan, uv_map: dict[str, tuple[float, float, float, float]]) -> None:
    """Append watertight closed prisms & posts for all planned German street furniture into `_MeshBuilder`."""
    if not plan.has_any:
        return
    axis_z = np.array([0.0, 0.0, 1.0], dtype=np.float64)
    sw_uv = uv_map.get(FURNITURE_SWATCH_KEY)
    if sw_uv is None:
        return

    def sw(key: str):
        return texture_atlas.uv_subrect(sw_uv, *_SWATCH_COORDS[key])

    steel_uv = sw("steel")
    glass_uv = sw("glass")
    wood_uv = sw("wood")
    conc_uv = sw("concrete")

    # 1. German Bus Stops (`Bushaltestellen`: optional glass/steel shelter + slim H-sign & timetable post)
    for stop in plan.bus_stops:
        ax = np.array([float(stop.along[0]), float(stop.along[1]), 0.0], dtype=np.float64)
        ay = np.array([float(stop.toward_road[0]), float(stop.toward_road[1]), 0.0], dtype=np.float64)
        z0 = stop.z - 0.12

        if stop.has_shelter:
            # Concrete pad base
            mb.add_box(np.array([stop.xy[0], stop.xy[1], z0 + 0.06]), ax, ay, axis_z, 1.45, 0.72, 0.08, conc_uv, conc_uv, body_mat=1, face_mat=1)
            # 3 anthracite rear steel uprights (back edge -0.58 m away from road)
            for sx in (-1.28, 0.0, 1.28):
                c_post = np.array([stop.xy[0] + ax[0] * sx - ay[0] * 0.56, stop.xy[1] + ax[1] * sx - ay[1] * 0.56, stop.z + 1.15])
                mb.add_box(c_post, ax, ay, axis_z, 0.04, 0.04, 1.25, steel_uv, steel_uv, body_mat=1, face_mat=1)
            # Back & side tempered blue-grey glass panels
            c_back = np.array([stop.xy[0] - ay[0] * 0.54, stop.xy[1] - ay[1] * 0.54, stop.z + 1.12])
            mb.add_box(c_back, ax, ay, axis_z, 1.26, 0.015, 0.96, glass_uv, glass_uv, body_mat=1, face_mat=1)
            for sx in (-1.30, 1.30):
                c_side = np.array([stop.xy[0] + ax[0] * sx - ay[0] * 0.08, stop.xy[1] + ax[1] * sx - ay[1] * 0.08, stop.z + 1.12])
                mb.add_box(c_side, ax, ay, axis_z, 0.015, 0.48, 0.96, glass_uv, glass_uv, body_mat=1, face_mat=1)
            # Cantilevered steel roof rim + glass canopy roof
            c_roof = np.array([stop.xy[0] - ay[0] * 0.02, stop.xy[1] - ay[1] * 0.02, stop.z + 2.34])
            mb.add_box(c_roof, ax, ay, axis_z, 1.44, 0.68, 0.045, steel_uv, steel_uv, body_mat=1, face_mat=1)
            mb.add_box(c_roof + axis_z * 0.03, ax, ay, axis_z, 1.38, 0.62, 0.02, glass_uv, glass_uv, body_mat=1, face_mat=1)
            # Wooden passenger bench inside shelter
            c_bench = np.array([stop.xy[0] - ay[0] * 0.34, stop.xy[1] - ay[1] * 0.34, stop.z + 0.46])
            mb.add_box(c_bench, ax, ay, axis_z, 0.85, 0.18, 0.035, wood_uv, wood_uv, body_mat=1, face_mat=1)
            post_xy = np.array([stop.xy[0] + ax[0] * 1.75, stop.xy[1] + ax[1] * 1.75], dtype=np.float64)
        else:
            post_xy = np.array([stop.xy[0], stop.xy[1]], dtype=np.float64)

        # Clean slim H-sign pole + 0.45 m x 0.45 m plaque + slim timetable panel
        mb.add_post(post_xy, z0, stop.z + 2.68, radius=0.030, mat_idx=0, sides=6)
        bs_uv = uv_map.get(f"busstop|{stop.name}")
        if bs_uv is not None:
            h_uv = texture_atlas.uv_subrect(bs_uv, 0.01, 0.06, 0.24, 0.94)
            tt_uv = texture_atlas.uv_subrect(bs_uv, 0.26, 0.06, 0.99, 0.94)
            # Yellow/green 0.45 m x 0.45 m H plaque on top
            mb.add_box(np.array([post_xy[0], post_xy[1], stop.z + 2.38]), ax, ay, axis_z, 0.225, 0.014, 0.225, h_uv, h_uv, body_mat=0, face_mat=1)
            # Slim green stop name + timetable panel below H badge
            mb.add_box(np.array([post_xy[0], post_xy[1], stop.z + 1.56]), ax, ay, axis_z, 0.14, 0.018, 0.21, tt_uv, tt_uv, body_mat=0, face_mat=1)

    # 2. Utility Cabinets (`Stromkästen`)
    cab_uv = sw("stromkasten")
    for cab in plan.cabinets:
        ax = np.array([float(cab.along[0]), float(cab.along[1]), 0.0], dtype=np.float64)
        ay = np.array([float(cab.toward_road[0]), float(cab.toward_road[1]), 0.0], dtype=np.float64)
        mb.add_box(np.array([cab.xy[0], cab.xy[1], cab.z + 0.04]), ax, ay, axis_z, 0.48, 0.22, 0.14, conc_uv, conc_uv, body_mat=1, face_mat=1)
        mb.add_box(np.array([cab.xy[0], cab.xy[1], cab.z + 0.68]), ax, ay, axis_z, 0.46, 0.20, 0.56, cab_uv, cab_uv, body_mat=1, face_mat=1)

    # 3. DHL `Packstationen`
    lock_uv = sw("packstation")
    for lk in plan.lockers:
        ax = np.array([float(lk.along[0]), float(lk.along[1]), 0.0], dtype=np.float64)
        ay = np.array([float(lk.toward_road[0]), float(lk.toward_road[1]), 0.0], dtype=np.float64)
        mb.add_box(np.array([lk.xy[0], lk.xy[1], lk.z + 1.02]), ax, ay, axis_z, 1.20, 0.34, 1.08, lock_uv, lock_uv, body_mat=1, face_mat=1)
        mb.add_box(np.array([lk.xy[0], lk.xy[1], lk.z + 2.12]), ax, ay, axis_z, 1.24, 0.38, 0.04, steel_uv, steel_uv, body_mat=1, face_mat=1)

    # 4. `Altglascontainer` Trio (Weiss / Braun / Grün)
    alt_uvs = (sw("altglas_w"), sw("altglas_b"), sw("altglas_g"))
    for rc in plan.recyclers:
        ax = np.array([float(rc.along[0]), float(rc.along[1]), 0.0], dtype=np.float64)
        ay = np.array([float(rc.toward_road[0]), float(rc.toward_road[1]), 0.0], dtype=np.float64)
        for idx_b, b_off in enumerate((-0.92, 0.0, 0.92)):
            c_bin = np.array([rc.xy[0] + ax[0] * b_off, rc.xy[1] + ax[1] * b_off, rc.z + 0.72])
            mb.add_box(c_bin, ax, ay, axis_z, 0.40, 0.44, 0.76, alt_uvs[idx_b], alt_uvs[idx_b], body_mat=1, face_mat=1)

    # 5. Corner Sidewalk `Poller`
    pol_uv = sw("poller")
    ax_default = np.array([1.0, 0.0, 0.0], dtype=np.float64)
    ay_default = np.array([0.0, 1.0, 0.0], dtype=np.float64)
    for bol in plan.bollards:
        mb.add_box(np.array([bol.xy[0], bol.xy[1], bol.z + 0.40]), ax_default, ay_default, axis_z, 0.055, 0.055, 0.48, pol_uv, pol_uv, body_mat=1, face_mat=1)

    # 6. Fuel Station Price Pylons (`Preistafel`, ~1.20 m x 0.25 m x 3.80 m)
    for fp in plan.fuel_pylons:
        fp_key = f"fuel|{fp.brand_key}|{fp.e10}|{fp.e5}|{fp.diesel}"
        fp_uv = uv_map.get(fp_key)
        if fp_uv is None:
            continue
        ax = np.array([float(fp.along[0]), float(fp.along[1]), 0.0], dtype=np.float64)
        ay = np.array([float(fp.toward_road[0]), float(fp.toward_road[1]), 0.0], dtype=np.float64)
        # Concrete footing plinth + main price totem
        mb.add_box(np.array([fp.xy[0], fp.xy[1], fp.z + 0.02]), ax, ay, axis_z, 0.64, 0.16, 0.14, conc_uv, conc_uv, body_mat=1, face_mat=1)
        mb.add_box(np.array([fp.xy[0], fp.xy[1], fp.z + 1.90]), ax, ay, axis_z, 0.60, 0.125, 1.90, fp_uv, fp_uv, body_mat=0, face_mat=1)
