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


@dataclass(frozen=True)
class BusStopItem:
    xy: np.ndarray
    z: float
    along: np.ndarray      # unit vector along street
    toward_road: np.ndarray  # unit vector facing carriageway
    name: str


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
class FurniturePlan:
    bus_stops: tuple[BusStopItem, ...]
    cabinets: tuple[BoxPropItem, ...]
    lockers: tuple[BoxPropItem, ...]
    recyclers: tuple[BoxPropItem, ...]
    bollards: tuple[BollardItem, ...]
    suppressed_recycle_xy: tuple[tuple[float, float], ...]

    @property
    def has_any(self) -> bool:
        return bool(self.bus_stops or self.cabinets or self.lockers or self.recyclers or self.bollards)


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


def _closest_road_edge(pt: np.ndarray, near_roads: list, max_dist: float = 28.0):
    """Return `(edge_dist, q_on_centerline, unit_tangent, toward_road, half_w)` or None."""
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
            if vl > 1e-4:
                away = v_from_road / vl
            else:
                away = np.array([-tang[1], tang[0]], dtype=np.float64)
            best = (edge_d, q[k], tang, -away, hw, away)
    if best is None or best[0] > max_dist:
        return None
    return best


def _snap_to_sidewalk_edge(
    pt: np.ndarray,
    near_roads: list,
    min_clear_m: float,
    rings_arr: list[np.ndarray],
) -> tuple[np.ndarray, np.ndarray, np.ndarray] | None:
    """Snap `pt` outside road carriageways by `min_clear_m`, returning `(xy, along, toward_road)`."""
    hit = _closest_road_edge(pt, near_roads)
    if hit is None:
        return None
    edge_d, q, tang, toward, hw, away = hit
    if edge_d < min_clear_m:
        pos = q + away * (hw + min_clear_m)
    else:
        pos = np.array([float(pt[0]), float(pt[1])], dtype=np.float64)
    # Re-check against all road carriageways so corner placement never intrudes on a crossing road.
    for _, sp, rpts, _ in near_roads or ():
        rxy = _finite_2d(rpts, min_pts=2)
        if rxy is None:
            continue
        rhw = float(getattr(sp, "width", 0.0) or 0.0) * 0.5
        a, b = rxy[:-1], rxy[1:]
        ab = b - a
        l2 = np.maximum((ab * ab).sum(1), 1e-12)
        t = np.clip(((pos[0] - a[:, 0]) * ab[:, 0] + (pos[1] - a[:, 1]) * ab[:, 1]) / l2, 0.0, 1.0)
        c = a + t[:, None] * ab
        if float(np.min(np.hypot(pos[0] - c[:, 0], pos[1] - c[:, 1]))) < rhw + min_clear_m * 0.85:
            return None
    if any(classifier._point_in_ring(pos, rr) for rr in rings_arr):
        return None
    return pos, tang, toward


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
) -> FurniturePlan:
    """Plan German bus stops, Stromkästen, Packstationen, Altglascontainer, and corner bollards."""
    empty = FurniturePlan((), (), (), (), (), ())
    if not near_roads:
        return empty

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

    bus_raw: list[tuple[np.ndarray, np.ndarray, np.ndarray, str]] = []
    cab_raw: list[tuple[np.ndarray, np.ndarray, np.ndarray]] = []
    lock_raw: list[tuple[np.ndarray, np.ndarray, np.ndarray]] = []
    rec_raw: list[tuple[np.ndarray, np.ndarray, np.ndarray]] = []
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
                if not (is_bus or is_cab or is_locker or is_recycle):
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

                if is_bus:
                    if str(tags.get("shelter", "")).lower() in ("no", "none", "false", "0"):
                        # Keep H sign even without shelter; shelter assembly still neat or minimal.
                        pass
                    snapped = _snap_to_sidewalk_edge(pt, near_roads, min_clear_m=1.15, rings_arr=rings_arr)
                    if snapped is not None:
                        s_name = ""
                        if name_arr is not None and name_arr[i]:
                            s_name = str(name_arr[i])
                        if not s_name:
                            s_name = str(tags.get("name") or "Haltestelle")
                        bus_raw.append((*snapped, s_name))
                elif is_cab:
                    snapped = _snap_to_sidewalk_edge(pt, near_roads, min_clear_m=0.85, rings_arr=rings_arr)
                    if snapped is not None:
                        cab_raw.append(snapped)
                elif is_locker:
                    snapped = _snap_to_sidewalk_edge(pt, near_roads, min_clear_m=1.15, rings_arr=rings_arr)
                    if snapped is not None:
                        lock_raw.append(snapped)
                elif is_recycle:
                    snapped = _snap_to_sidewalk_edge(pt, near_roads, min_clear_m=1.15, rings_arr=rings_arr)
                    if snapped is not None:
                        rec_raw.append(snapped)
                        sup_rec_xy.append((float(pt[0]), float(pt[1])))

    # Procedural deterministic sidewalk Stromkästen along urban sidewalks (~1 per 70 m).
    occupied_xy: list[tuple[float, float]] = [(float(p[0]), float(p[1])) for p, _, _, _ in bus_raw]
    occupied_xy.extend((float(p[0]), float(p[1])) for p, _, _ in cab_raw)
    occupied_xy.extend((float(p[0]), float(p[1])) for p, _, _ in lock_raw)
    occupied_xy.extend((float(p[0]), float(p[1])) for p, _, _ in rec_raw)

    for wk in walks or ():
        fid = wk.get("fid")
        pts = _finite_2d(wk.get("pts"), min_pts=2)
        if fid is None or pts is None or wk.get("median"):
            continue
        side = int(wk.get("side", 1))
        wk_w = float(wk.get("w", roadsmod.SIDEWALK["w"]))
        d = pts[1:] - pts[:-1]
        seg_l = np.hypot(d[:, 0], d[:, 1])
        total = float(seg_l.sum())
        if total < 24.0:
            continue
        station = 18.0 + _hash01(fid, side, "strom") * 26.0
        idx = 0
        cum = np.concatenate(([0.0], np.cumsum(seg_l)))
        while station <= total - 12.0:
            while idx + 1 < len(cum) and cum[idx + 1] < station:
                idx += 1
            if idx >= len(seg_l):
                break
            sl = float(seg_l[idx])
            if sl > 1e-4:
                t = (station - float(cum[idx])) / sl
                c_pt = pts[idx] + t * d[idx]
                tang = d[idx] / sl
                left = np.array([-tang[1], tang[0]], dtype=np.float64)
                away = left * float(side)
                # Place near outer back edge of sidewalk.
                pos = c_pt + away * max(0.35, wk_w * 0.5 - 0.25)
                px, py = float(pos[0]), float(pos[1])
                if (
                    roadsmod.box_owns(box, px, py)
                    and not any(math.hypot(px - jx, py - jy) < 6.0 for jx, jy in junc_pts)
                    and not any(math.hypot(px - dx, py - dy) < 2.5 for dx, dy in drive_pts)
                    and not any(math.hypot(px - ox, py - oy) < 8.0 for ox, oy in occupied_xy)
                    and not any(classifier._point_in_ring(pos, rr) for rr in rings_arr)
                ):
                    cab_raw.append((pos, tang, -away))
                    occupied_xy.append((px, py))
            station += 65.0 + _hash01(fid, side, "step", int(station)) * 25.0

    # Corner sidewalk bollards (`Poller`) at urban 3+ arm junctions.
    bollard_raw: list[np.ndarray] = []
    for _k, arms in arms_map.items():
        if len(arms) < 3:
            continue
        eligible_arms = [a for a in arms if getattr(a[1], "cls", "") in ("residential", "tertiary", "secondary", "unclassified")]
        if len(eligible_arms) < 2:
            continue
        p = np.asarray(arms[0][3], dtype=np.float64)
        jx, jy = float(p[0]), float(p[1])
        if not roadsmod.box_owns(box, jx, jy):
            continue
        # Order arms by angle and place 2 bollards around the first two urban corner bisectors.
        ordered = sorted(eligible_arms, key=lambda a: math.atan2(float(a[2][1]), float(a[2][0])))
        for a_idx in range(min(2, len(ordered))):
            a0 = ordered[a_idx]
            a1 = ordered[(a_idx + 1) % len(ordered)]
            v0 = np.asarray(a0[2][:2], dtype=np.float64)
            v1 = np.asarray(a1[2][:2], dtype=np.float64)
            bis = v0 + v1
            bl = float(np.hypot(bis[0], bis[1]))
            if bl < 0.25:
                continue
            bis /= bl
            hw_max = max(float(getattr(a0[1], "width", 6.0) or 6.0), float(getattr(a1[1], "width", 6.0) or 6.0)) * 0.5
            corner_pt = np.array([jx, jy], dtype=np.float64) + bis * (hw_max * 1.414 + 0.65)
            tang_c = np.array([-bis[1], bis[0]], dtype=np.float64)
            for s_off in (-0.95, 0.0, 0.95):
                b_pt = corner_pt + tang_c * s_off
                bx, by = float(b_pt[0]), float(b_pt[1])
                if not roadsmod.box_owns(box, bx, by):
                    continue
                if any(math.hypot(bx - ox, by - oy) < 1.8 for ox, oy in occupied_xy):
                    continue
                if any(math.hypot(bx - dx, by - dy) < 2.2 for dx, dy in drive_pts):
                    continue
                if any(classifier._point_in_ring(b_pt, rr) for rr in rings_arr):
                    continue
                hit = _closest_road_edge(b_pt, near_roads, max_dist=12.0)
                if hit is None or hit[0] < 0.30:
                    continue
                bollard_raw.append(b_pt)

    # Filter all points strictly inside DE and sample ground heights in a single batch.
    all_pts: list[np.ndarray] = (
        [x[0] for x in bus_raw]
        + [x[0] for x in cab_raw]
        + [x[0] for x in lock_raw]
        + [x[0] for x in rec_raw]
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
    for pos, along, toward, nm in bus_raw:
        if in_de[cur] and np.isfinite(zs[cur]):
            bus_out.append(BusStopItem(pos, float(zs[cur]), along, toward, nm))
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

    # 1. German Bus Stops (`Bushaltestellen`: glass/steel shelter + bench + H-sign & timetable post)
    for stop in plan.bus_stops:
        ax = np.array([float(stop.along[0]), float(stop.along[1]), 0.0], dtype=np.float64)
        ay = np.array([float(stop.toward_road[0]), float(stop.toward_road[1]), 0.0], dtype=np.float64)
        z0 = stop.z - 0.12

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

        # Bus stop sign post at right end (+1.75 m along street)
        post_xy = np.array([stop.xy[0] + ax[0] * 1.75, stop.xy[1] + ax[1] * 1.75], dtype=np.float64)
        mb.add_post(post_xy, z0, stop.z + 2.68, radius=0.036, mat_idx=0, sides=6)
        bs_uv = uv_map.get(f"busstop|{stop.name}")
        if bs_uv is not None:
            h_uv = texture_atlas.uv_subrect(bs_uv, 0.01, 0.06, 0.24, 0.94)
            tt_uv = texture_atlas.uv_subrect(bs_uv, 0.26, 0.06, 0.99, 0.94)
            # Yellow/green H badge on top
            mb.add_box(np.array([post_xy[0], post_xy[1], stop.z + 2.38]), ax, ay, axis_z, 0.22, 0.02, 0.22, h_uv, h_uv, body_mat=0, face_mat=1)
            # Green stop name + timetable panel below H badge
            mb.add_box(np.array([post_xy[0], post_xy[1], stop.z + 1.56]), ax, ay, axis_z, 0.24, 0.035, 0.34, tt_uv, tt_uv, body_mat=0, face_mat=1)

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
