"""Germany-specific curbside parked-car cluster placement (`BNE_DE_STREET_IMMERSION=on`).

Replaces the coarse North American 7.0 m minimum width / sidewalk-only curb filter
for tiles inside Germany so residential (`residential`, `living_street`, `unclassified`)
and eligible collector (`tertiary`, `secondary` without trams) streets receive
realistic, collision-safe European curbside car clusters (`[x, y, z, heading, 0, 2.05, 5.2]`).
Mapped `amenity=parking` lot stalls (`r[4] == 1`) and bus bays (`r[4] == 2`) are preserved.
"""

import hashlib
import math
import numpy as np

import dmath
import dnp
import furniture
import germany
import mapgeom
import rails as railsmod
import roads as roadsmod

from . import classifier


DE_PARK_CLASSES = frozenset({"residential", "living_street", "unclassified", "tertiary", "secondary"})
DE_MIN_WIDTH_M = 5.5
DE_TWO_SIDES_WIDTH_M = 8.5
DE_SECONDARY_TWO_WAY_MIN_M = 7.0
DE_SPOT_W_M = 2.05
DE_SPOT_LEN_M = 5.2
DE_PITCH_M = 5.8
DE_CURB_OFF_NARROW_M = 1.00
DE_CURB_OFF_WIDE_M = 1.05
DE_JUNCTION_CLEAR_M = 10.0
DE_BUS_STOP_CLEAR_M = 12.0
DE_DRIVE_CLEAR_M = 4.2
DE_HYDRANT_CLEAR_M = 4.6
DE_TRAM_CLEAR_M = 3.5
DE_BLD_CLEAR_M = 1.15
DE_SPOT_SEP_M = 4.8


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


def _min_dist_to_polylines(pt: np.ndarray, lines: list[np.ndarray]) -> float:
    best = float("inf")
    px, py = float(pt[0]), float(pt[1])
    for ln in lines:
        if len(ln) < 2:
            continue
        a = ln[:-1, :2]
        ab = ln[1:, :2] - a
        l2 = np.maximum((ab * ab).sum(1), 1e-12)
        t = np.clip(((px - a[:, 0]) * ab[:, 0] + (py - a[:, 1]) * ab[:, 1]) / l2, 0.0, 1.0)
        q = a + t[:, None] * ab
        d = float(np.min(np.hypot(px - q[:, 0], py - q[:, 1])))
        if d < best:
            best = d
    return best


def _bus_stop_points(md, frame, box: tuple[float, float, float, float]) -> list[tuple[float, float]]:
    """Collect bus stop / platform XY points near `box` from Overture infrastructure."""
    if md is None:
        return []
    import mapcells

    cx = 0.5 * (box[0] + box[2])
    cy = 0.5 * (box[1] + box[3])
    half = 0.5 * max(box[2] - box[0], box[3] - box[1]) + 25.0
    lat0, lon0, _ = frame.enu_to_geodetic(cx, cy, 0.0)
    dlat = half / 111320.0
    dlon = half / (111320.0 * max(0.2, math.cos(math.radians(float(lat0)))))

    pts: list[tuple[float, float]] = []
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
        tags_arr = feats.attrs.get("tags")
        for i in range(len(feats)):
            fid = str(feats.ids[i]) if getattr(feats, "ids", None) is not None else f"{cell_key}:{i}"
            if fid in seen:
                continue
            cls_v = str(cls_arr[i] or "").lower() if cls_arr is not None else ""
            raw_tags = str(tags_arr[i] or "") if tags_arr is not None else ""
            is_stop = cls_v == "bus_stop" or "bus_stop" in raw_tags or '"platform"' in raw_tags
            if not is_stop:
                continue
            seen.add(fid)
            parts = feats.parts(i)
            if not parts or not parts[0] or len(parts[0][0]) < 1:
                continue
            e, n = mapgeom.enu_xy(feats, frame, np.asarray(parts[0][0], np.float64))
            if len(e) > 0:
                pts.append((float(np.mean(e)), float(np.mean(n))))
    return pts


def _tram_polylines(md, frame, tx: int, ty: int, cells) -> list[np.ndarray]:
    try:
        if cells is None and md is not None:
            keys = roadsmod.cells_of_tile(frame, tx, ty)
            cells = [md.cell(k, layers=("roads",), kind="demand").layers.get("roads") for k in keys]
        if not cells:
            return []
        raw = railsmod.tram_lines(frame, tx, ty, [c for c in cells if c is not None])
        return [xy for line, _hw in raw if (xy := _finite_2d(line, min_pts=2)) is not None]
    except Exception:
        return []


def _offset_polyline(pts: np.ndarray, side: int, dist: float) -> np.ndarray | None:
    """Offset a 2D polyline laterally by `side * dist` (side +1=left, -1=right)."""
    xy = _finite_2d(pts, min_pts=2)
    if xy is None:
        return None
    seg = xy[1:] - xy[:-1]
    seg_len = np.hypot(seg[:, 0], seg[:, 1])
    keep = seg_len > 1e-4
    if not keep.any():
        return None
    # Vertex normals from adjacent segment normals.
    n_seg = np.column_stack((-seg[:, 1], seg[:, 0])) / np.maximum(seg_len[:, None], 1e-9)
    normals = np.zeros_like(xy)
    normals[0] = n_seg[0]
    normals[-1] = n_seg[-1]
    if len(xy) > 2:
        avg = n_seg[:-1] + n_seg[1:]
        avg_l = np.hypot(avg[:, 0], avg[:, 1])
        normals[1:-1] = np.where(avg_l[:, None] > 1e-4, avg / np.maximum(avg_l[:, None], 1e-9), n_seg[:-1])
    return xy + float(side) * float(dist) * normals


def _sample_stations(line_xy: np.ndarray, pitch: float, phase: float) -> list[tuple[np.ndarray, np.ndarray]]:
    """Sample `(point_xy, unit_tangent)` along `line_xy` at regular arc-length `pitch`."""
    d = line_xy[1:] - line_xy[:-1]
    seg_l = np.hypot(d[:, 0], d[:, 1])
    total = float(seg_l.sum())
    if total < pitch * 0.6:
        return []
    cum = np.concatenate(([0.0], np.cumsum(seg_l)))
    out: list[tuple[np.ndarray, np.ndarray]] = []
    s = phase
    idx = 0
    while s <= total - pitch * 0.25:
        while idx + 1 < len(cum) and cum[idx + 1] < s:
            idx += 1
        if idx >= len(seg_l):
            break
        sl = float(seg_l[idx])
        if sl > 1e-6:
            t = (s - float(cum[idx])) / sl
            pt = line_xy[idx] + t * d[idx]
            tang = d[idx] / sl
            out.append((pt, tang))
        s += pitch
    return out


def refine_parking_spots(
    md,
    frame,
    tx: int,
    ty: int,
    box: tuple[float, float, float, float],
    near_roads: list,
    walks: list | None,
    props: list | None,
    drives: list[dict] | None,
    garage_drives: list[dict] | None,
    rings: list[np.ndarray] | None,
    existing_park: list | None,
    ground,
    cells=None,
) -> list:
    """Return updated `park` rows with German residential & collector curbside clusters."""
    base_rows = list(existing_park or ())
    if not near_roads:
        return base_rows

    # Separate preserved non-curb spots (amenity=parking lots [4]==1, bus bays [4]==2) and non-DE curb spots.
    preserved: list = []
    non_de_curb: list = []
    for r in base_rows:
        if len(r) >= 5 and r[4] in (1, 2):
            preserved.append(r)
        else:
            non_de_curb.append(r)

    if non_de_curb:
        cxs = np.array([float(r[0]) for r in non_de_curb], dtype=np.float64)
        cys = np.array([float(r[1]) for r in non_de_curb], dtype=np.float64)
        in_de = germany.de_at(frame, cxs, cys)
        for r, is_de in zip(non_de_curb, in_de):
            if not is_de:
                preserved.append(r)

    # Junction nodes (`>= 10 m` clearance).
    junc_pts: list[tuple[float, float]] = []
    for _k, arms in (furniture._arms(near_roads) or {}).items():
        if len(arms) >= 2:
            p = np.asarray(arms[0][3], dtype=np.float64)
            junc_pts.append((float(p[0]), float(p[1])))

    bus_pts = _bus_stop_points(md, frame, box)
    tram_lines = _tram_polylines(md, frame, tx, ty, cells)

    hydrant_pts: list[tuple[float, float]] = []
    for row in props or ():
        if str(row[0]) in ("hydrant", "hydrant_eu"):
            hydrant_pts.append((float(row[1]), float(row[2])))

    drive_lines: list[np.ndarray] = []
    drive_mouths: list[tuple[float, float]] = []
    for d in list(drives or ()) + list(garage_drives or ()):
        xy = _finite_2d(d.get("n"), min_pts=2)
        if xy is not None:
            drive_lines.append(xy)
            drive_mouths.append((float(xy[-1, 0]), float(xy[-1, 1])))

    rings_arr = [rr for r in (rings or ()) if (rr := _finite_2d(r, min_pts=3)) is not None]

    # Map existing walks by (fid, side).
    walks_by_fid: dict[tuple[object, int], dict] = {}
    for wk in walks or ():
        fid = wk.get("fid")
        side = wk.get("side")
        if fid is not None and side in (1, -1) and "pts" in wk:
            walks_by_fid[(fid, int(side))] = wk

    # Collect existing road segments for overlap protection.
    all_road_bands: list[tuple[float, np.ndarray]] = []
    for _, sp, pts, _ in near_roads:
        xy = _finite_2d(pts, min_pts=2)
        if xy is not None:
            all_road_bands.append((float(getattr(sp, "width", 0.0) or 0.0) * 0.5, xy))

    cand_spots: list[tuple[float, float, float]] = []
    accepted_xy: list[tuple[float, float]] = [(float(r[0]), float(r[1])) for r in preserved]

    for item in near_roads:
        fid, spec, pts = item[0], item[1], item[2]
        cls = getattr(spec, "cls", "")
        if cls not in DE_PARK_CLASSES or getattr(spec, "kind", "") != "paved":
            continue
        if getattr(spec, "link", False) or getattr(spec, "median", False):
            continue
        width = float(getattr(spec, "width", 0.0) or 0.0)
        if width < DE_MIN_WIDTH_M:
            continue
        if cls == "secondary" and (
            (not getattr(spec, "oneway", False) and width < DE_SECONDARY_TWO_WAY_MIN_M)
            or (getattr(spec, "lanes", None) or 0) >= 4
        ):
            continue
        line_xy = _finite_2d(pts, min_pts=2)
        if line_xy is None:
            continue
        if cls in ("secondary", "tertiary") and tram_lines:
            # Skip streetcar-shared collector roads.
            mid_pt = line_xy[len(line_xy) // 2]
            if _min_dist_to_polylines(mid_pt, tram_lines) < DE_TRAM_CLEAR_M + width * 0.5:
                continue

        # Check midpoint inside DE.
        m_pt = line_xy[len(line_xy) // 2]
        if not bool(germany.de_at(frame, np.array([m_pt[0]]), np.array([m_pt[1]]))[0]):
            continue

        sides = (1, -1) if width >= DE_TWO_SIDES_WIDTH_M else (1 if _hash01(fid, "de_pside") < 0.5 else -1,)
        curb_off = DE_CURB_OFF_NARROW_M if width < DE_TWO_SIDES_WIDTH_M else DE_CURB_OFF_WIDE_M
        half_w = width * 0.5

        for side in sides:
            wk = walks_by_fid.get((fid, side))
            if wk is not None and _finite_2d(wk.get("pts"), min_pts=2) is not None:
                wk_pts = _finite_2d(wk["pts"], min_pts=2)
                wk_w = float(wk.get("w", roadsmod.SIDEWALK["w"]))
                # Walk line sits at sidewalk center; inner curb is -side * wk_w / 2.
                park_line = _offset_polyline(wk_pts, -side, wk_w * 0.5 + curb_off)
            else:
                park_line = _offset_polyline(line_xy, side, max(0.4, half_w - curb_off))
            if park_line is None:
                continue

            phase = _hash01(fid, side, "de_pphase") * DE_PITCH_M
            stations = _sample_stations(park_line, DE_PITCH_M, phase)
            if not stations:
                continue

            # Organic German 2..4 car clusters separated by 1..2 slot gaps.
            st_idx = 0
            cluster_i = 0
            while st_idx < len(stations):
                c_len = 2 + int(_hash01(fid, side, "cl", cluster_i) * 3)
                g_len = 1 + int(_hash01(fid, side, "gp", cluster_i) * 2)
                for _k in range(c_len):
                    if st_idx >= len(stations):
                        break
                    pt, tang = stations[st_idx]
                    st_idx += 1
                    px, py = float(pt[0]), float(pt[1])
                    if not roadsmod.box_owns(box, px, py):
                        continue
                    if any(math.hypot(px - jx, py - jy) < DE_JUNCTION_CLEAR_M for jx, jy in junc_pts):
                        continue
                    if any(math.hypot(px - bx, py - by) < DE_BUS_STOP_CLEAR_M for bx, by in bus_pts):
                        continue
                    if any(math.hypot(px - hx, py - hy) < DE_HYDRANT_CLEAR_M for hx, hy in hydrant_pts):
                        continue
                    if any(math.hypot(px - dx, py - dy) < DE_DRIVE_CLEAR_M for dx, dy in drive_mouths):
                        continue
                    if drive_lines and _min_dist_to_polylines(pt, drive_lines) < 2.2:
                        continue
                    if tram_lines and _min_dist_to_polylines(pt, tram_lines) < DE_TRAM_CLEAR_M:
                        continue
                    if any(classifier._point_in_ring(pt, rr) for rr in rings_arr):
                        continue
                    # Ensure spot stays inside its road carriageway & clear of other crossing streets.
                    if any(math.hypot(px - ax, py - ay) < DE_SPOT_SEP_M for ax, ay in accepted_xy):
                        continue

                    # Right-hand traffic heading along curb: side +1 (left) faces -tang, side -1 (right) faces +tang.
                    if getattr(spec, "oneway", False):
                        hx, hy = float(tang[0]), float(tang[1])
                    else:
                        sgn = -1.0 if side > 0 else 1.0
                        hx, hy = sgn * float(tang[0]), sgn * float(tang[1])
                    heading = math.degrees(dmath.atan2(hy, hx)) % 360.0
                    cand_spots.append((px, py, heading))
                    accepted_xy.append((px, py))
                st_idx += g_len
                cluster_i += 1

    if not cand_spots:
        return preserved

    xs = np.array([c[0] for c in cand_spots], dtype=np.float64)
    ys = np.array([c[1] for c in cand_spots], dtype=np.float64)
    in_de = germany.de_at(frame, xs, ys)
    cand_spots = [c for c, ok in zip(cand_spots, in_de) if ok]
    if not cand_spots:
        return preserved

    xs = np.array([c[0] for c in cand_spots], dtype=np.float64)
    ys = np.array([c[1] for c in cand_spots], dtype=np.float64)
    zs = np.asarray(ground(xs, ys), dtype=np.float64) if ground is not None else np.zeros(len(xs), dtype=np.float64)
    out = list(preserved)
    for (px, py, hd), zz in zip(cand_spots, zs):
        z_val = float(zz) if np.isfinite(zz) else 0.0
        out.append([round(px, 2), round(py, 2), round(z_val, 2), round(hd, 1), 0, DE_SPOT_W_M, DE_SPOT_LEN_M])
    return out
