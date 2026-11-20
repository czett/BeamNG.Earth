"""Geometry placement and `.cdae` / Forest-row builders for DE street immersion.

Handles:
1. Feature A: German street name signs (`destreets.cdae`) mounted on nearby
   street lamps or standalone galvanized posts with junction/sign clearance.
2. Feature B: Illuminated shopfront fascia panels (`deshops.cdae`) attached cleanly
   to street-facing commercial walls above ground-floor shopfronts.
3. Feature C: German residential front-yard hedges and fences (`props` rows using
   `fr_hedge` and `fr_fence_*`) with driveway, door-path, and curb clearances.
"""

from dataclasses import dataclass
import hashlib
import math
import os
import numpy as np

import cdae
import dmath
import dnp
import fast
import fences
import furniture
import germany
import mapgeom
import roads as roadsmod

from . import classifier
from . import texture_atlas


METAL_MATERIAL = "bne_sign_metal"

# Junction/street-sign geometry constants
STREET_IGNORE_CLASSES = frozenset({"service", "track", "footway", "cycleway", "path", "steps", "bridleway", "parking_aisle"})
JUNCTION_POLE_MAX_M = 11.0
JUNCTION_POLE_MIN_M = 1.1
DE_Z_MIN_CLEAR_M = 1.15
ROAD_EDGE_BLADE_CLEAR_M = 0.35
MOUNTABLE_POLES = frozenset({"streetlight", "eu_lamp_steel", "eu_lamp_concrete", "catmast", "catmast_eu", "pole"})
DE_SIGN_PREFIXES = ("de_z", "signal", "stop", "giveway")

PLATE_THICK_M = 0.026
PLATE_HEIGHT_M = 0.175
POST_RADIUS_M = 0.032
BLADE_BASE_Z_M = 2.38
BLADE_STEP_Z_M = 0.21
LAMP_MOUNT_BASE_Z_M = 2.75

# Shop fascia lightbox geometry constants
FASCIA_THICK_M = 0.16

# Residential front-yard hedge & fence constants
DE_YARD_CLEAR_ROAD_M = 0.35
DE_YARD_WALK_OFFSET_M = 0.20
DE_YARD_MIN_CLEAR_WALK_M = 0.35
DE_YARD_HEDGE_MIN_CLEAR_M = 1.05
DE_YARD_HEDGE_WALL_CLEAR_M = 0.85
DE_YARD_FENCE_WALL_CLEAR_M = 0.25
DE_SLIM_FENCE_STYLES = ("iron", "slats", "wood")
DE_YARD_MIN_NO_WALK_M = 0.65
DE_YARD_WALL_OFFSET_M = 0.55
DE_YARD_MAX_DEPTH_M = 18.0
DE_YARD_MAX_LEN_M = 32.0
DE_YARD_GAP_HALF_M = 1.40
DE_DOOR_GAP_HALF_M = 0.70
DE_HEDGE_GROUP = "de_hedge"
DE_HEDGE_STEP_M = 0.75
DE_YARD_MIN_SPAN_M = 0.50
DE_HEDGE_Z_SEAT_M = -0.12
DE_MAX_SLOPE_DEG = 22.0
DE_MAX_SLOPE_TAN = math.tan(math.radians(DE_MAX_SLOPE_DEG))


@dataclass(frozen=True)
class StreetSignPost:
    """Resolved street name sign assembly (post + 1..3 double-sided blades)."""

    xy: np.ndarray              # tile-absolute ENU (2,)
    z_ground: float
    mounted_on_pole: bool
    blades: tuple[tuple[str, np.ndarray, float, str], ...]  # (name, unit_dir_2d, z_mid, variant)


def _hash01(*parts) -> float:
    h = hashlib.blake2b("|".join(str(p) for p in parts).encode("utf-8"), digest_size=8).digest()
    return int.from_bytes(h, "big") / float(1 << 64)


def _finite_2d(pts, min_pts: int = 2) -> np.ndarray | None:
    """Return contiguous `(N, 2)` float64 polyline/ring when non-empty and finite, else None."""
    if pts is None:
        return None
    arr = np.asarray(pts, dtype=np.float64)
    if arr.ndim != 2 or arr.shape[0] < min_pts or arr.shape[1] < 2:
        return None
    xy = np.ascontiguousarray(arr[:, :2], dtype=np.float64)
    if xy.size == 0 or not np.isfinite(xy).all():
        return None
    return xy


def _sample_ground(ground, xs, ys, fallback: float = 0.0) -> np.ndarray:
    """Safely evaluate `ground(xs, ys)` without passing empty or non-finite arrays into native kernels."""
    xa = np.ascontiguousarray(np.asarray(xs, dtype=np.float64).reshape(-1), dtype=np.float64)
    ya = np.ascontiguousarray(np.asarray(ys, dtype=np.float64).reshape(-1), dtype=np.float64)
    n = xa.shape[0]
    if n == 0 or ya.shape[0] != n:
        return np.zeros(0, dtype=np.float64)
    if ground is None or not (np.isfinite(xa).all() and np.isfinite(ya).all()):
        return np.full(n, float(fallback), dtype=np.float64)
    try:
        zs = np.asarray(ground(xa, ya), dtype=np.float64).reshape(-1)
    except Exception:
        return np.full(n, float(fallback), dtype=np.float64)
    if zs.shape[0] != n:
        return np.full(n, float(fallback), dtype=np.float64)
    return np.where(np.isfinite(zs), zs, float(fallback))


def _expand_blocker_segments(
    blockers: list[tuple[np.ndarray, float]] | None,
    extra_hw: float = 0.0,
) -> tuple[np.ndarray, np.ndarray, np.ndarray] | None:
    """Convert `[(polyline, half_width)]` into aligned `(a (M,2), b (M,2), hw (M,))` for Rust FFI."""
    valid: list[tuple[np.ndarray, float]] = []
    for ln, hw in blockers or ():
        xy = _finite_2d(ln, min_pts=2)
        if xy is None:
            continue
        try:
            hw_f = float(hw)
        except (TypeError, ValueError):
            continue
        if not math.isfinite(hw_f):
            continue
        valid.append((xy, hw_f))
    if not valid:
        return None

    segs, starts, half = roadsmod._blocker_segments(valid)
    segs_arr = np.asarray(segs, dtype=np.float64)
    starts_arr = np.asarray(starts, dtype=np.int64).reshape(-1)
    half_arr = np.asarray(half, dtype=np.float64).reshape(-1)
    if (
        segs_arr.ndim != 2
        or segs_arr.shape[0] == 0
        or segs_arr.shape[1] != 4
        or half_arr.shape[0] == 0
        or starts_arr.shape[0] != half_arr.shape[0] + 1
    ):
        return None

    counts = np.diff(starts_arr)
    if (counts < 0).any() or int(counts.sum()) != int(segs_arr.shape[0]):
        return None

    # `roads._blocker_segments` returns one half-width per polyline, whereas `points_near_segments`
    # indexes `hw[k]` once per individual segment! Expand via `np.repeat` to match segment count.
    hw_seg = np.ascontiguousarray(np.repeat(half_arr, counts) + float(extra_hw), dtype=np.float64)
    a = np.ascontiguousarray(segs_arr[:, :2], dtype=np.float64)
    b = np.ascontiguousarray(segs_arr[:, 2:], dtype=np.float64)
    if a.shape[0] == 0 or a.shape[0] != hw_seg.shape[0]:
        return None
    if not (np.isfinite(a).all() and np.isfinite(b).all() and np.isfinite(hw_seg).all()):
        return None
    return a, b, hw_seg


def _points_near_segments_safe(
    pts,
    expanded_blocks: tuple[np.ndarray, np.ndarray, np.ndarray] | None,
) -> bool:
    """Guarded wrapper around `fast._ef.points_near_segments` rejecting empty or misshaped arrays."""
    mask = _points_near_segments_mask(pts, expanded_blocks)
    return bool(mask is not None and mask.any())


def _points_near_segments_mask(
    pts,
    expanded_blocks: tuple[np.ndarray, np.ndarray, np.ndarray] | None,
) -> np.ndarray | None:
    """Return boolean `(N,)` mask from `fast._ef.points_near_segments`, or None when invalid/empty."""
    if expanded_blocks is None:
        return None
    a, b, hw = expanded_blocks
    pts_arr = np.asarray(pts, dtype=np.float64)
    if pts_arr.ndim == 1:
        if pts_arr.shape[0] != 2:
            return None
        pts_arr = pts_arr.reshape(1, 2)
    if pts_arr.ndim != 2 or pts_arr.shape[0] == 0 or pts_arr.shape[1] != 2:
        return None
    if (
        a.ndim != 2
        or b.ndim != 2
        or hw.ndim != 1
        or a.shape[0] == 0
        or a.shape != b.shape
        or a.shape[1] != 2
        or hw.shape[0] != a.shape[0]
    ):
        return None
    pts_c = np.ascontiguousarray(pts_arr, dtype=np.float64)
    if not np.isfinite(pts_c).all():
        return None
    fast.require(0, "points_near_segments")
    return np.asarray(fast._ef.points_near_segments(pts_c, a, b, hw), dtype=bool)


class _MeshBuilder:
    """Split-normal closed solid mesh builder exporting directly via `cdae.write`."""

    def __init__(self, materials: list[str], origin=(0.0, 0.0, 0.0)):
        self.materials = list(materials)
        self.ox = float(origin[0])
        self.oy = float(origin[1])
        self.oz = float(origin[2])
        self.origin = np.array([self.ox, self.oy, self.oz], dtype=np.float64)
        self.pos: list[tuple[float, float, float]] = []
        self.norms: list[tuple[float, float, float]] = []
        self.uvs: list[tuple[float, float]] = []
        self.tris: list[tuple[int, int, int]] = []
        self.tm: list[int] = []

    def add_quad(self, p0, p1, p2, p3, normal, uv_rect, mat_idx: int):
        """Append CCW quad looking along `-normal` (`(p1-p0) x (p2-p0)` aligns with `+normal`)."""
        base = len(self.pos)
        u0, v0, u1, v1 = uv_rect
        n_tup = (float(normal[0]), float(normal[1]), float(normal[2]))
        ox, oy, oz = self.ox, self.oy, self.oz
        self.pos.extend((
            (float(p0[0]) - ox, float(p0[1]) - oy, float(p0[2]) - oz),
            (float(p1[0]) - ox, float(p1[1]) - oy, float(p1[2]) - oz),
            (float(p2[0]) - ox, float(p2[1]) - oy, float(p2[2]) - oz),
            (float(p3[0]) - ox, float(p3[1]) - oy, float(p3[2]) - oz),
        ))
        self.norms.extend((n_tup, n_tup, n_tup, n_tup))
        self.uvs.extend(((u0, v0), (u1, v0), (u1, v1), (u0, v1)))
        self.tris.append((base, base + 1, base + 2))
        self.tris.append((base, base + 2, base + 3))
        self.tm.extend((mat_idx, mat_idx))

    def add_box(
        self,
        center: np.ndarray,
        axis_x: np.ndarray,
        axis_y: np.ndarray,
        axis_z: np.ndarray,
        hx: float,
        hy: float,
        hz: float,
        front_uv: tuple[float, float, float, float] | None,
        back_uv: tuple[float, float, float, float] | None,
        body_mat: int,
        face_mat: int | None = None,
        skip_bottom: bool = False,
    ):
        """Add watertight closed 6-face prism (or 5-face ground-embedded prism) with crisp split normals."""
        cx, cy, cz = float(center[0]), float(center[1]), float(center[2])
        exx, exy, exz = float(axis_x[0]) * hx, float(axis_x[1]) * hx, float(axis_x[2]) * hx
        eyx, eyy, eyz = float(axis_y[0]) * hy, float(axis_y[1]) * hy, float(axis_y[2]) * hy
        ezx, ezy, ezz = float(axis_z[0]) * hz, float(axis_z[1]) * hz, float(axis_z[2]) * hz
        neutral_uv = (0.0, 0.0, 1.0, 1.0)

        f_mat = face_mat if (front_uv is not None and face_mat is not None) else body_mat
        b_mat = face_mat if (back_uv is not None and face_mat is not None) else body_mat

        # +Y (front face toward `axis_y`)
        fcx, fcy, fcz = cx + eyx, cy + eyy, cz + eyz
        self.add_quad(
            (fcx - exx - ezx, fcy - exy - ezy, fcz - exz - ezz),
            (fcx + exx - ezx, fcy + exy - ezy, fcz + exz - ezz),
            (fcx + exx + ezx, fcy + exy + ezy, fcz + exz + ezz),
            (fcx - exx + ezx, fcy - exy + ezy, fcz - exz + ezz),
            axis_y, front_uv or neutral_uv, f_mat,
        )

        # -Y (back face toward `-axis_y`)
        bcx, bcy, bcz = cx - eyx, cy - eyy, cz - eyz
        self.add_quad(
            (bcx + exx - ezx, bcy + exy - ezy, bcz + exz - ezz),
            (bcx - exx - ezx, bcy - exy - ezy, bcz - exz - ezz),
            (bcx - exx + ezx, bcy - exy + ezy, bcz - exz + ezz),
            (bcx + exx + ezx, bcy + exy + ezy, bcz + exz + ezz),
            (-axis_y[0], -axis_y[1], -axis_y[2]), back_uv or neutral_uv, b_mat,
        )

        # +X side
        rcx, rcy, rcz = cx + exx, cy + exy, cz + exz
        self.add_quad(
            (rcx + eyx - ezx, rcy + eyy - ezy, rcz + eyz - ezz),
            (rcx - eyx - ezx, rcy - eyy - ezy, rcz - eyz - ezz),
            (rcx - eyx + ezx, rcy - eyy + ezy, rcz - eyz + ezz),
            (rcx + eyx + ezx, rcy + eyy + ezy, rcz + eyz + ezz),
            axis_x, neutral_uv, body_mat,
        )

        # -X side
        lcx, lcy, lcz = cx - exx, cy - exy, cz - exz
        self.add_quad(
            (lcx - eyx - ezx, lcy - eyy - ezy, lcz - eyz - ezz),
            (lcx + eyx - ezx, lcy + eyy - ezy, lcz + eyz - ezz),
            (lcx + eyx + ezx, lcy + eyy + ezy, lcz + eyz + ezz),
            (lcx - eyx + ezx, lcy - eyy + ezy, lcz - eyz + ezz),
            (-axis_x[0], -axis_x[1], -axis_x[2]), neutral_uv, body_mat,
        )

        # +Z top
        tcx, tcy, tcz = cx + ezx, cy + ezy, cz + ezz
        self.add_quad(
            (tcx - exx + eyx, tcy - exy + eyy, tcz - exz + eyz),
            (tcx + exx + eyx, tcy + exy + eyy, tcz + exz + eyz),
            (tcx + exx - eyx, tcy + exy - eyy, tcz + exz - eyz),
            (tcx - exx - eyx, tcy - exy - eyy, tcz - exz - eyz),
            axis_z, neutral_uv, body_mat,
        )

        # -Z bottom
        if not skip_bottom:
            dcx, dcy, dcz = cx - ezx, cy - ezy, cz - ezz
            self.add_quad(
                (dcx - exx - eyx, dcy - exy - eyy, dcz - exz - eyz),
                (dcx + exx - eyx, dcy + exy - eyy, dcz + exz - eyz),
                (dcx + exx + eyx, dcy + exy + eyy, dcz + exz + eyz),
                (dcx - exx + eyx, dcy - exy + eyy, dcz - exz + eyz),
                (-axis_z[0], -axis_z[1], -axis_z[2]), neutral_uv, body_mat,
            )

    def add_post(self, xy: np.ndarray, z0: float, z1: float, radius: float, mat_idx: int, sides: int = 6):
        """Add closed hexagonal galvanized metal pole prism."""
        px, py = float(xy[0]), float(xy[1])
        ox, oy, oz = self.ox, self.oy, self.oz
        step = 2.0 * math.pi / sides
        ring = [(px + radius * math.cos(step * i), py + radius * math.sin(step * i)) for i in range(sides)]

        # Side quads
        for i in range(sides):
            j = (i + 1) % sides
            rx0, ry0 = ring[i]
            rx1, ry1 = ring[j]
            mx = 0.5 * (rx0 + rx1) - px
            my = 0.5 * (ry0 + ry1) - py
            ml = max(math.hypot(mx, my), 1e-6)
            self.add_quad(
                (rx0, ry0, z0),
                (rx1, ry1, z0),
                (rx1, ry1, z1),
                (rx0, ry0, z1),
                (mx / ml, my / ml, 0.0),
                (0.0, 0.0, 1.0, 1.0),
                mat_idx,
            )

        # Top & bottom triangle caps
        bot_c = len(self.pos)
        self.pos.append((px - ox, py - oy, z0 - oz))
        self.norms.append((0.0, 0.0, -1.0))
        self.uvs.append((0.0, 0.0))
        for rx, ry in ring:
            self.pos.append((rx - ox, ry - oy, z0 - oz))
            self.norms.append((0.0, 0.0, -1.0))
            self.uvs.append((0.0, 0.0))
        for i in range(sides):
            j = (i + 1) % sides
            self.tris.append((bot_c, bot_c + 1 + j, bot_c + 1 + i))
            self.tm.append(mat_idx)

        top_c = len(self.pos)
        self.pos.append((px - ox, py - oy, z1 - oz))
        self.norms.append((0.0, 0.0, 1.0))
        self.uvs.append((0.0, 0.0))
        for rx, ry in ring:
            self.pos.append((rx - ox, ry - oy, z1 - oz))
            self.norms.append((0.0, 0.0, 1.0))
            self.uvs.append((0.0, 0.0))
        for i in range(sides):
            j = (i + 1) % sides
            self.tris.append((top_c, top_c + 1 + i, top_c + 1 + j))
            self.tm.append(mat_idx)

    def empty(self) -> bool:
        return not self.tris

    def bounding_radius(self) -> float:
        if not self.pos:
            return 1.0
        xs = [p[0] for p in self.pos]
        ys = [p[1] for p in self.pos]
        zs = [p[2] for p in self.pos]
        dx = max(xs) - min(xs)
        dy = max(ys) - min(ys)
        dz = max(zs) - min(zs)
        return max(1.0, 0.5 * math.sqrt(dx * dx + dy * dy + dz * dz))

    def _arrays(self):
        if self.empty() or not self.pos:
            raise ValueError("Cannot encode empty DE enhancer mesh")
        pos = np.array(self.pos, dtype=np.float64).reshape(-1, 3)
        tris = np.array(self.tris, dtype=np.int64).reshape(-1, 3)
        norms = np.array(self.norms, dtype=np.float64).reshape(-1, 3)
        uvs = np.array(self.uvs, dtype=np.float64).reshape(-1, 2)
        tm = np.array(self.tm, dtype=np.int64).reshape(-1)
        if pos.shape[0] == 0 or tris.shape[0] == 0 or tm.shape[0] != tris.shape[0]:
            raise ValueError("Invalid mesh array shapes for cdae encoding")
        return pos, tris, norms, uvs, tm

    def _lod_dict(self) -> dict:
        pos, tris, _norms, uvs, tm = self._arrays()
        return {"positions": pos, "tris": tris, "uvs": uvs, "tri_materials": tm}

    def encode(self, lods=None, min_visible_px: float | None = None) -> bytes:
        pos, tris, norms, uvs, tm = self._arrays()
        return cdae.encode(
            pos,
            tris,
            normals=norms,
            uvs=uvs,
            material=self.materials,
            tri_materials=tm,
            close=False,
            lods=lods,
            min_visible_px=min_visible_px,
        )

    def write(self, path: str) -> int:
        pos, tris, norms, uvs, tm = self._arrays()
        os.makedirs(os.path.dirname(path), exist_ok=True)
        return cdae.write(
            path,
            pos,
            tris,
            normals=norms,
            uvs=uvs,
            material=self.materials,
            tri_materials=tm,
            close=False,
        )


def _min_dist_to_segments(pt: np.ndarray, road_lines: list[tuple[float, np.ndarray]]) -> float:
    """Minimum edge-clearance distance from 2D `pt` to any road carriageway boundary."""
    best = float("inf")
    px, py = float(pt[0]), float(pt[1])
    for half_w, line in road_lines:
        if len(line) < 2:
            continue
        a = line[:-1, :2]
        ab = line[1:, :2] - a
        l2 = np.maximum((ab * ab).sum(1), 1e-12)
        t = np.clip(((px - a[:, 0]) * ab[:, 0] + (py - a[:, 1]) * ab[:, 1]) / l2, 0.0, 1.0)
        q = a + t[:, None] * ab
        d = float(np.min(np.hypot(px - q[:, 0], py - q[:, 1]))) - float(half_w)
        if d < best:
            best = d
    return best


def _norm_street(name: str) -> str:
    return " ".join(str(name or "").split()).casefold()


def _blade_width_m(name: str) -> float:
    # Practical German Enzianblau blade width ~0.68 m .. 1.35 m proportional to text length.
    return max(0.68, min(1.38, 0.34 + 0.048 * len(name)))


def _canonical_blade_dir(d: np.ndarray) -> np.ndarray:
    """Ensure street blade horizontal vector always points in `[0, pi)` for readable front/back consistency."""
    vx, vy = float(d[0]), float(d[1])
    if vy < -1e-6 or (abs(vy) <= 1e-6 and vx < 0):
        vx, vy = -vx, -vy
    norm = max(math.hypot(vx, vy), 1e-9)
    return np.array([vx / norm, vy / norm], dtype=np.float64)


def plan_street_signs(
    frame,
    roads: list,
    box: tuple[float, float, float, float],
    street_names: dict[object, str],
    props: list,
    ground,
    rings: list[np.ndarray] | None = None,
    drives: list[dict] | None = None,
    style_variant: str = "blue",
    arms_map: dict | None = None,
    rings_arr: list[np.ndarray] | None = None,
) -> list[StreetSignPost]:
    """Compute collision-safe German street name sign assemblies for junctions inside `box`."""
    if not roads or not street_names:
        return []

    junctions = arms_map if arms_map is not None else furniture._arms(roads)
    if not junctions:
        return []

    road_lines: list[tuple[float, np.ndarray]] = []
    for _, sp, pts, _ in roads:
        xy = _finite_2d(pts, min_pts=2)
        if xy is not None:
            road_lines.append((float(sp.width) / 2.0, xy))
    if not road_lines:
        return []
    drive_lines: list[tuple[float, np.ndarray]] = []
    for d in drives or ():
        xy = _finite_2d(d.get("n"), min_pts=2)
        if xy is not None:
            drive_lines.append((float(d["w"]) / 2.0, xy))

    poles_xy: list[tuple[float, float]] = []
    block_signs_xy: list[tuple[float, float]] = []
    for row in props or ():
        g = str(row[0])
        if g in MOUNTABLE_POLES:
            poles_xy.append((float(row[1]), float(row[2])))
        elif any(g.startswith(pfx) for pfx in DE_SIGN_PREFIXES):
            block_signs_xy.append((float(row[1]), float(row[2])))

    de_checks: list[tuple] = []
    planned: list[StreetSignPost] = []
    used_poles: set[int] = set()

    for _k, arms in junctions.items():
        if len(arms) < 2:
            continue
        p = np.asarray(arms[0][3], dtype=np.float64)
        jx, jy, jz = float(p[0]), float(p[1]), float(p[2])
        if not roadsmod.box_owns(box, jx, jy):
            continue

        # Collect distinct named public streets meeting at this junction.
        by_norm: dict[str, tuple[str, np.ndarray, float]] = {}
        total_arms = len(arms)
        for fid, sp, vec_away, _pt, _start, _length in arms:
            if getattr(sp, "cls", "") in STREET_IGNORE_CLASSES:
                continue
            raw_name = street_names.get(fid) or street_names.get(str(fid)) or ""
            clean = " ".join(str(raw_name).split())
            if not clean:
                continue
            nk = _norm_street(clean)
            if nk not in by_norm:
                by_norm[nk] = (clean, _canonical_blade_dir(np.asarray(vec_away, dtype=np.float64)), float(sp.width))
            else:
                # Keep wider carriageway orientation when deduplicating through-arms of the same street.
                if float(sp.width) > by_norm[nk][2]:
                    by_norm[nk] = (clean, _canonical_blade_dir(np.asarray(vec_away, dtype=np.float64)), float(sp.width))

        # Require at least 2 distinct street names, or a named street joining a >=3-arm T-junction.
        if len(by_norm) < 2 and not (len(by_norm) == 1 and total_arms >= 3):
            continue
        de_checks.append((jx, jy, jz, arms, list(by_norm.values())))

    if not de_checks:
        return []

    check_xs = np.ascontiguousarray([c[0] for c in de_checks], dtype=np.float64)
    check_ys = np.ascontiguousarray([c[1] for c in de_checks], dtype=np.float64)
    if check_xs.size == 0 or not (np.isfinite(check_xs).all() and np.isfinite(check_ys).all()):
        return []
    in_de = germany.de_at(frame, check_xs, check_ys)

    if rings_arr is None:
        rings_arr = [rr for r in (rings or ()) if (rr := _finite_2d(r, min_pts=3)) is not None]

    for (jx, jy, jz, arms, uniq_streets), ok in zip(de_checks, in_de):
        if not ok:
            continue

        blades_meta = sorted(uniq_streets, key=lambda it: it[2], reverse=True)[:3]

        # 1. Try clamping onto an existing nearby street lamp or utility pole cleanly separated from de_z* signs.
        mounted_idx = None
        best_pole_d = JUNCTION_POLE_MAX_M + 1.0
        for p_idx, (px, py) in enumerate(poles_xy):
            if p_idx in used_poles:
                continue
            d = math.hypot(px - jx, py - jy)
            if not (JUNCTION_POLE_MIN_M <= d <= JUNCTION_POLE_MAX_M):
                continue
            if any(math.hypot(px - sx, py - sy) < DE_Z_MIN_CLEAR_M for sx, sy in block_signs_xy):
                continue
            if _min_dist_to_segments(np.array([px, py]), road_lines) < 0.35:
                continue
            if d < best_pole_d:
                best_pole_d = d
                mounted_idx = p_idx

        chosen_xy = None
        mounted = False
        if mounted_idx is not None:
            used_poles.add(mounted_idx)
            chosen_xy = np.array(poles_xy[mounted_idx], dtype=np.float64)
            mounted = True
        else:
            # 2. Pick open corner wedge between arms sorted around the junction.
            angles = sorted(
                [(math.atan2(float(a[2][1]), float(a[2][0])), a) for a in arms],
                key=lambda x: x[0],
            )
            max_w = max(float(a[1].width) for a in arms)
            half_blade_max = max(_blade_width_m(b[0]) * 0.5 for b in blades_meta)

            best_cand = None
            best_score = float("inf")
            for k in range(len(angles)):
                th0, a0 = angles[k]
                th1, a1 = angles[(k + 1) % len(angles)]
                dth = (th1 - th0) % (2.0 * math.pi)
                if dth < 0.35:  # acute wedge < 20 deg: push outward instead
                    bis_th = th0 + dth * 0.5 + math.pi
                    rad = max(max_w * 0.65, 2.2) + half_blade_max + 0.55
                else:
                    bis_th = th0 + dth * 0.5
                    # Acute corner wedge (< 45 deg) pushes farther back so blade tips stay off asphalt.
                    acute_extra = 1.6 if dth < 0.80 else 0.35
                    rad = max(float(a0[1].width), float(a1[1].width)) * 0.5 + half_blade_max + acute_extra

                for extra in (0.0, 0.75, 1.50):
                    cand = np.array([jx + math.cos(bis_th) * (rad + extra), jy + math.sin(bis_th) * (rad + extra)], dtype=np.float64)
                    if not roadsmod.box_owns(box, float(cand[0]), float(cand[1])):
                        continue
                    edge_clear = _min_dist_to_segments(cand, road_lines)
                    if edge_clear < ROAD_EDGE_BLADE_CLEAR_M + half_blade_max * 0.35:
                        continue
                    if drive_lines and _min_dist_to_segments(cand, drive_lines) < 0.65:
                        continue
                    if any(math.hypot(float(cand[0]) - sx, float(cand[1]) - sy) < DE_Z_MIN_CLEAR_M for sx, sy in block_signs_xy):
                        continue
                    # Avoid standing inside building footprints
                    if any(classifier._point_in_ring(cand, rr) for rr in rings_arr):
                        continue
                    score = edge_clear + extra * 0.5
                    if score < best_score:
                        best_score = score
                        best_cand = cand
                        break
            chosen_xy = best_cand

        if chosen_xy is None:
            continue

        # Also validate blade endpoints clear all road carriageways; nudge outward along radial vector if needed.
        radial = chosen_xy - np.array([jx, jy], dtype=np.float64)
        rlen = float(np.linalg.norm(radial))
        r_unit = radial / rlen if rlen > 1e-4 else np.array([1.0, 0.0], dtype=np.float64)
        if not mounted:
            for _step in range(3):
                ok_tips = True
                for b_name, b_dir, _w in blades_meta:
                    hw = _blade_width_m(b_name) * 0.5
                    for sgn in (-1.0, 1.0):
                        tip = chosen_xy + b_dir * (sgn * hw)
                        if _min_dist_to_segments(tip, road_lines) < ROAD_EDGE_BLADE_CLEAR_M:
                            ok_tips = False
                            break
                    if not ok_tips:
                        break
                if ok_tips:
                    break
                chosen_xy = chosen_xy + r_unit * 0.55

        if not np.isfinite(chosen_xy).all() or not roadsmod.box_owns(box, float(chosen_xy[0]), float(chosen_xy[1])):
            continue

        zg = float(_sample_ground(ground, [chosen_xy[0]], [chosen_xy[1]], fallback=jz)[0])

        z0_blade = LAMP_MOUNT_BASE_Z_M if mounted else BLADE_BASE_Z_M
        blade_rows = tuple(
            (b_name, b_dir, zg + z0_blade + i * BLADE_STEP_Z_M, style_variant)
            for i, (b_name, b_dir, _w) in enumerate(blades_meta)
        )
        planned.append(StreetSignPost(xy=chosen_xy, z_ground=zg, mounted_on_pole=mounted, blades=blade_rows))
        block_signs_xy.append((float(chosen_xy[0]), float(chosen_xy[1])))

    return planned


def encode_streets_and_furniture_mesh(
    posts: list[StreetSignPost],
    furn_plan,
    atlas_mat: str,
    uv_map: dict[str, tuple[float, float, float, float]],
    origin: tuple[float, float, float],
    fuel_mat: str | None = None,
) -> bytes | None:
    """Encode batched `destreets.cdae` containing street signs + German transit stops & sidewalk micro-props."""
    from . import furniture_de

    has_furn = furn_plan is not None and furn_plan.has_any
    if (not posts and not has_furn) or not atlas_mat or not uv_map:
        return None
    mats = [METAL_MATERIAL, atlas_mat] + ([fuel_mat] if fuel_mat else [])
    fuel_mat_idx = 2 if fuel_mat else None
    mb = _MeshBuilder(mats, origin=origin)
    axis_z = np.array([0.0, 0.0, 1.0], dtype=np.float64)

    for post in posts or ():
        if not post.blades:
            continue
        top_blade_z = max(b[2] for b in post.blades) + PLATE_HEIGHT_M * 0.5 + 0.06
        if not post.mounted_on_pole:
            mb.add_post(post.xy, post.z_ground - 0.25, top_blade_z, POST_RADIUS_M, mat_idx=0)

        for name, b_dir, z_mid, style_variant in post.blades:
            key = f"street|{style_variant}|{name}"
            uv = uv_map.get(key)
            if uv is None:
                continue
            axis_x = np.array([float(b_dir[0]), float(b_dir[1]), 0.0], dtype=np.float64)
            axis_y = np.array([float(b_dir[1]), -float(b_dir[0]), 0.0], dtype=np.float64)
            offset = (POST_RADIUS_M + 0.08) if post.mounted_on_pole else 0.0
            center = np.array([post.xy[0] + axis_y[0] * offset, post.xy[1] + axis_y[1] * offset, z_mid], dtype=np.float64)
            if post.mounted_on_pole:
                mb.add_post(post.xy, z_mid - 0.06, z_mid + 0.06, 0.085, mat_idx=0, sides=6)

            bw = _blade_width_m(name)
            mb.add_box(
                center=center,
                axis_x=axis_x,
                axis_y=axis_y,
                axis_z=axis_z,
                hx=bw * 0.5,
                hy=PLATE_THICK_M * 0.5,
                hz=PLATE_HEIGHT_M * 0.5,
                front_uv=uv,
                back_uv=uv,
                body_mat=0,
                face_mat=1,
            )

    if has_furn:
        furniture_de.append_furniture_geometry(mb, furn_plan, uv_map, fuel_mat_idx=fuel_mat_idx)

    if mb.empty():
        return None

    lods = None
    min_visible_px = None
    if has_furn and (furn_plan.fuel_pylons or furn_plan.bus_stops):
        macro_mb = _MeshBuilder(mats, origin=origin)
        furniture_de.append_furniture_geometry(macro_mb, furn_plan, uv_map, macro_only=True, fuel_mat_idx=fuel_mat_idx)
        if not macro_mb.empty() and len(macro_mb.tris) < len(mb.tris):
            r_macro = macro_mb.bounding_radius()
            lod_px = max(180.0, min(5000.0, 3500.0 * r_macro / 160.0))
            lods = [(lod_px, macro_mb._lod_dict())]
    else:
        r_all = mb.bounding_radius()
        min_visible_px = max(40.0, min(4500.0, 3500.0 * r_all / 160.0))

    return mb.encode(lods=lods, min_visible_px=min_visible_px)


def encode_street_signs_mesh(
    posts: list[StreetSignPost],
    atlas_mat: str,
    uv_map: dict[str, tuple[float, float, float, float]],
    origin: tuple[float, float, float],
) -> bytes | None:
    """Encode batched multi-material `.cdae` bytes containing posts, collars, and street plates."""
    return encode_streets_and_furniture_mesh(posts, None, atlas_mat, uv_map, origin)


def build_street_signs_mesh(
    posts: list[StreetSignPost],
    atlas_mat: str,
    uv_map: dict[str, tuple[float, float, float, float]],
    origin: tuple[float, float, float],
    cdae_path: str,
) -> bool:
    """Write batched multi-material `.cdae` containing posts, collars, and street plates."""
    blob = encode_street_signs_mesh(posts, atlas_mat, uv_map, origin)
    if blob is None:
        return False
    os.makedirs(os.path.dirname(cdae_path), exist_ok=True)
    with open(cdae_path, "wb") as f:
        f.write(blob)
    return True


def encode_shop_and_housenumbers_mesh(
    targets: list[classifier.ShopTarget],
    hn_targets: list[classifier.HouseNumberTarget] | None,
    atlas_mat: str,
    uv_map: dict[str, tuple[float, float, float, float]],
) -> bytes | None:
    """Encode batched `.cdae` bytes of commercial fascias and 3D German house number plaques relative to tile origin."""
    if (not targets and not hn_targets) or not atlas_mat or not uv_map:
        return None
    mb = _MeshBuilder([METAL_MATERIAL, atlas_mat], origin=(0.0, 0.0, 0.0))
    axis_z = np.array([0.0, 0.0, 1.0], dtype=np.float64)

    for t in targets or ():
        key = f"shop|{t.spec_brand.key}|{t.label}"
        uv = uv_map.get(key)
        if uv is None:
            continue
        axis_x = np.array([float(t.d_along[0]), float(t.d_along[1]), 0.0], dtype=np.float64)
        axis_y = np.array([float(t.out_normal[0]), float(t.out_normal[1]), 0.0], dtype=np.float64)
        z_mid = 0.5 * (t.z_bottom + t.z_top)
        center = np.array([float(t.center_xy[0]), float(t.center_xy[1]), z_mid], dtype=np.float64)
        mb.add_box(
            center=center,
            axis_x=axis_x,
            axis_y=axis_y,
            axis_z=axis_z,
            hx=t.width_m * 0.5,
            hy=FASCIA_THICK_M * 0.5,
            hz=t.height_m * 0.5,
            front_uv=uv,
            back_uv=None,
            body_mat=0,
            face_mat=1,
        )

    for hn in hn_targets or ():
        uv = uv_map.get(f"hn|{hn.number}")
        if uv is None:
            continue
        axis_x = np.array([float(hn.d_along[0]), float(hn.d_along[1]), 0.0], dtype=np.float64)
        axis_y = np.array([float(hn.out_normal[0]), float(hn.out_normal[1]), 0.0], dtype=np.float64)
        center = np.array([float(hn.center_xy[0]), float(hn.center_xy[1]), float(hn.z_mid)], dtype=np.float64)
        mb.add_box(
            center=center,
            axis_x=axis_x,
            axis_y=axis_y,
            axis_z=axis_z,
            hx=0.21,
            hy=0.015,
            hz=0.15,
            front_uv=uv,
            back_uv=None,
            body_mat=0,
            face_mat=1,
        )

    if mb.empty():
        return None

    # Coarse LOD keeps illuminated shop fascias visible down the block while culling sub-meter
    # house-number plaques beyond ~85 m.
    lods = None
    min_visible_px = None
    if targets and hn_targets:
        macro_mb = _MeshBuilder([METAL_MATERIAL, atlas_mat], origin=(0.0, 0.0, 0.0))
        for t in targets:
            uv = uv_map.get(f"shop|{t.spec_brand.key}|{t.label}")
            if uv is None:
                continue
            axis_x = np.array([float(t.d_along[0]), float(t.d_along[1]), 0.0], dtype=np.float64)
            axis_y = np.array([float(t.out_normal[0]), float(t.out_normal[1]), 0.0], dtype=np.float64)
            z_mid = 0.5 * (t.z_bottom + t.z_top)
            center = np.array([float(t.center_xy[0]), float(t.center_xy[1]), z_mid], dtype=np.float64)
            macro_mb.add_box(
                center=center,
                axis_x=axis_x,
                axis_y=axis_y,
                axis_z=axis_z,
                hx=t.width_m * 0.5,
                hy=FASCIA_THICK_M * 0.5,
                hz=t.height_m * 0.5,
                front_uv=uv,
                back_uv=None,
                body_mat=0,
                face_mat=1,
            )
        if not macro_mb.empty() and len(macro_mb.tris) < len(mb.tris):
            r_macro = macro_mb.bounding_radius()
            lod_px = max(260.0, min(9000.0, 3500.0 * r_macro / 85.0))
            lods = [(lod_px, macro_mb._lod_dict())]
    elif not targets and hn_targets:
        r_all = mb.bounding_radius()
        min_visible_px = max(40.0, min(4500.0, 3500.0 * r_all / 85.0))

    return mb.encode(lods=lods, min_visible_px=min_visible_px)


def encode_shop_fascias_mesh(
    targets: list[classifier.ShopTarget],
    atlas_mat: str,
    uv_map: dict[str, tuple[float, float, float, float]],
) -> bytes | None:
    """Encode batched `.cdae` bytes of illuminated commercial fascias relative to tile origin."""
    return encode_shop_and_housenumbers_mesh(targets, None, atlas_mat, uv_map)


def build_shop_fascias_mesh(
    targets: list[classifier.ShopTarget],
    atlas_mat: str,
    uv_map: dict[str, tuple[float, float, float, float]],
    cdae_path: str,
) -> bool:
    """Write batched `.cdae` of illuminated commercial fascias relative to tile origin."""
    blob = encode_shop_fascias_mesh(targets, atlas_mat, uv_map)
    if blob is None:
        return False
    os.makedirs(os.path.dirname(cdae_path), exist_ok=True)
    with open(cdae_path, "wb") as f:
        f.write(blob)
    return True


_BARRIER_CLASSES = ("fence", "wall", "hedge", "retaining_wall", "noise_barrier")


def _infra_barriers(md, frame, box: tuple[float, float, float, float], reach_m: float = 20.0) -> list[np.ndarray]:
    """Load mapped OSM `fence` / `wall` / `hedge` lines inside Germany when Feature C runs."""
    if md is None:
        return []
    cx = 0.5 * (box[0] + box[2])
    cy = 0.5 * (box[1] + box[3])
    half = 0.5 * max(box[2] - box[0], box[3] - box[1]) + reach_m
    lat0, lon0, _ = frame.enu_to_geodetic(cx, cy, 0.0)
    dlat = half / 111320.0
    dlon = half / (111320.0 * max(0.2, math.cos(math.radians(float(lat0)))))
    import mapcells
    out: list[np.ndarray] = []
    seen: set[str] = set()
    for cell_key in mapcells.cells_for_bbox(float(lat0) - dlat, float(lon0) - dlon, float(lat0) + dlat, float(lon0) + dlon):
        try:
            cd = md.cell(cell_key, layers=("infrastructure",), kind="demand")
            feats = cd.layers.get("infrastructure")
        except Exception:
            continue
        if feats is None or not len(feats) or "class" not in feats.attrs:
            continue
        cls_mask = feats.__dict__.get("_de_barrier_mask")
        if cls_mask is None:
            cls_mask = np.isin(feats.attrs["class"], _BARRIER_CLASSES)
            feats.__dict__["_de_barrier_mask"] = cls_mask
        if not cls_mask.any():
            continue
        bounds = feats.boxes(frame)
        bounds_arr = np.asarray(bounds, dtype=np.float64) if bounds is not None else np.empty((0, 4), dtype=np.float64)
        if bounds_arr.ndim != 2 or bounds_arr.shape[0] != len(feats) or bounds_arr.shape[1] < 4:
            continue
        near = (
            (bounds_arr[:, 2] >= box[0] - reach_m)
            & (bounds_arr[:, 0] <= box[2] + reach_m)
            & (bounds_arr[:, 3] >= box[1] - reach_m)
            & (bounds_arr[:, 1] <= box[3] + reach_m)
        )
        for i in np.flatnonzero(near & cls_mask):
            fid = str(feats.ids[i])
            if fid in seen:
                continue
            seen.add(fid)
            for part in feats.parts(i):
                for ring in part:
                    r_arr = _finite_2d(ring, min_pts=2)
                    if r_arr is None:
                        continue
                    e_arr, n_arr = mapgeom.enu_xy(feats, frame, ring)
                    xy = _finite_2d(np.column_stack((e_arr, n_arr)), min_pts=2)
                    if xy is not None:
                        out.append(xy)
    return out


def _driveway_gaps(
    centre: np.ndarray,
    tangent: np.ndarray,
    half_len: float,
    a_edge: np.ndarray,
    d_edge: np.ndarray,
    edge_len: float,
    door: tuple[int, float] | None,
    edge: int,
    access_lines: list[tuple[np.ndarray, float]],
) -> list[tuple[float, float]]:
    """Compute signed offsets along boundary tangent where door path or driveway crosses."""
    gaps: list[tuple[float, float]] = []
    if door is not None and door[0] == edge:
        dp = a_edge + d_edge * float(door[1])
        gaps.append((float(np.dot(dp - centre, tangent)), DE_DOOR_GAP_HALF_M))

    p0 = centre - tangent * half_len
    p1 = centre + tangent * half_len
    seg_vec = p1 - p0
    seg_len2 = float(np.dot(seg_vec, seg_vec))
    if seg_len2 < 1e-6:
        return gaps

    for ln, half_w in access_lines:
        if len(ln) < 2:
            continue
        for u, v in zip(ln[:-1], ln[1:]):
            # Project line segment endpoints onto boundary line & check closest approach to front-yard line.
            for q in (u[:2], v[:2], 0.5 * (u[:2] + v[:2])):
                t_b = float(np.dot(q - centre, tangent))
                if abs(t_b) <= half_len + 1.0:
                    perp = float(np.hypot(*(q - (centre + tangent * t_b))))
                    if perp <= half_w + 1.4:
                        gaps.append((t_b, float(half_w) + 0.9))
    return gaps


def _de_street_front(ring: np.ndarray, streets, door):
    """DE-specific street-facing wall selector supporting narrow German townhouses (>= 2.6 m) and compact yards (>= 0.95 m)."""
    from buildings import _area2

    start, direction, length, half, local = streets
    ends = np.roll(ring, -1, axis=0)
    mid = (ring + ends) / 2.0
    edges = ends - ring
    widths = dnp.norm(edges, axis=1)
    along = edges / np.maximum(widths, 1e-9)[:, None]
    toward = np.c_[along[:, 1], -along[:, 0]] * (1 if _area2(ring) > 0 else -1)
    rel = mid[:, None, :] - start
    station = np.sum(rel * direction, axis=2)
    q = start + np.clip(station, 0.0, length)[..., None] * direction
    delta = mid[:, None, :] - q
    gap = dnp.norm(delta, axis=2)
    setback = gap - half
    faces = np.sum(delta * toward[:, None, :], axis=2) <= -0.57 * gap
    parallel = np.abs(dnp.matmul(along, direction.T)) >= 0.58
    abreast = (station >= -2.5) & (station <= length + 2.5)
    eligible = faces & parallel & abreast & (setback >= DE_YARD_MIN_NO_WALK_M) & (setback <= 22.0) & (widths[:, None] >= 2.6)
    if not eligible.any():
        return None
    rank = np.where(eligible, setback - 0.45 * local, np.inf)
    if door is not None and door[0] < len(ring):
        rank[door[0]] -= 1.1
    edge, road = np.unravel_index(rank.argmin(), rank.shape)
    tangent = direction[road] * (1 if dnp.matmul(direction[road], along[edge]) > 0 else -1)
    return (
        edge,
        mid[edge],
        along[edge],
        widths[edge],
        q[edge, road],
        delta[edge, road] / max(float(gap[edge, road]), 1e-6),
        tangent,
        half[road],
        setback[edge, road],
        local[road],
    )


def place_residential_yards(
    frame,
    box: tuple[float, float, float, float],
    items: list,
    near_roads: list,
    walks: list | None,
    drives: list[dict],
    garage_drives_list: list[dict] | None,
    rings: list[np.ndarray],
    ground,
    md=None,
    rings_arr: list[np.ndarray] | None = None,
    level: str = "medium",
    fast_pass: bool = False,
) -> list[list]:
    """Generate DE residential front-yard hedges & fences respecting driveways and sidewalks."""
    if not items or not near_roads:
        return []

    x0, y0, x1, y1 = box
    houses = classifier.classify_residential_yards(items, frame, x0, y0, tile_size=x1 - x0)
    if not houses:
        return []

    streets = fences._street_segments(near_roads)
    if not len(streets[0]):
        return []

    road_bands: list[tuple[np.ndarray, float]] = []
    for _, sp, pts, _ in near_roads:
        xy = _finite_2d(pts, min_pts=2)
        if xy is not None:
            road_bands.append((xy, float(sp.width) / 2.0))
    if not road_bands:
        return []
    road_blocks = _expand_blocker_segments([(ln, hw) for ln, hw in road_bands], extra_hw=DE_YARD_CLEAR_ROAD_M)

    walk_bands: list[tuple[np.ndarray, float]] = []
    for w in walks or ():
        if "pts" in w:
            xy = _finite_2d(w["pts"], min_pts=2)
            if xy is not None:
                walk_bands.append((xy, float(w.get("w", roadsmod.SIDEWALK["w"])) / 2.0))
    walk_blocks = _expand_blocker_segments([(ln, hw) for ln, hw in walk_bands], extra_hw=0.02)

    import streetfront
    walk_edges: list[np.ndarray] = []
    for walk in walks or ():
        if "pts" in walk or "corner" in walk:
            curb_l, back_l = streetfront._walk_outline(walk)
            for ln in (curb_l, back_l):
                xy = _finite_2d(ln, min_pts=2)
                if xy is not None:
                    walk_edges.append(xy)
    walk_walls = streetfront._walls([], walk_edges) if walk_edges else None
    has_walk_walls = walk_walls is not None and len(getattr(walk_walls, "keys", ())) > 0

    access_lines: list[tuple[np.ndarray, float]] = []
    for _, sp, pts, _ in near_roads:
        if getattr(sp, "cls", "") == "service":
            xy = _finite_2d(pts, min_pts=2)
            if xy is not None:
                access_lines.append((xy, float(sp.width) / 2.0))
    for d in list(drives or ()) + list(garage_drives_list or ()):
        xy = _finite_2d(d.get("n"), min_pts=2)
        if xy is not None:
            access_lines.append((xy, float(d.get("w", 3.0)) / 2.0))

    barriers = _infra_barriers(md, frame, box)
    barrier_blocks = _expand_blocker_segments([(ln, 0.9) for ln in barriers])

    pending: list[tuple] = []

    for spec, ring, style in houses:
        front = _de_street_front(ring, streets, getattr(spec, "door", None))
        if front is None:
            continue
        edge, _mid, along, wall_w, q, out, tangent, half_road, setback, _local = front

        # Probe sidewalk outer back edge along front-wall outward normal (`walk_walls.ray`).
        curb_probe = q + (float(half_road) - 0.15) * out
        first = None
        if (
            has_walk_walls
            and float(setback) > 0.05
            and np.isfinite(curb_probe).all()
            and np.isfinite(out).all()
        ):
            first = walk_walls.ray(curb_probe, out, min(5.5, float(setback)))

        wall_offset = float(half_road) + float(setback)
        if first is not None:
            reach_second = min(4.9, float(setback) - first + 0.1)
            second = (
                walk_walls.ray(curb_probe + (first + 0.04) * out, out, reach_second)
                if reach_second > 0.05 and np.isfinite(first)
                else None
            )
            edge_of_walk = first if second is None else first + 0.04 + second
            walk_back_offset = float(half_road) - 0.15 + edge_of_walk
            clearance = wall_offset - walk_back_offset
            if clearance < DE_YARD_MIN_CLEAR_WALK_M or clearance > DE_YARD_MAX_DEPTH_M:
                continue
            # 0.20 m behind sidewalk back edge when roomy; 0.55 m in front of wall when narrow (never on sidewalk).
            if clearance >= DE_YARD_WALK_OFFSET_M + DE_YARD_WALL_OFFSET_M:
                offset = walk_back_offset + DE_YARD_WALK_OFFSET_M
            else:
                offset = max(walk_back_offset + 0.10, min(walk_back_offset + DE_YARD_WALK_OFFSET_M, wall_offset - DE_YARD_WALL_OFFSET_M))
        else:
            if float(setback) < DE_YARD_MIN_NO_WALK_M or float(setback) > DE_YARD_MAX_DEPTH_M:
                continue
            offset = max(float(half_road) + 0.40, wall_offset - DE_YARD_WALL_OFFSET_M)
            if float(setback) > 3.2:
                offset = min(offset, float(half_road) + 2.20)

        centre = q + offset * out
        yard_style = style
        if yard_style == "hedge":
            if level == "low":
                continue
            if fast_pass:
                cls_low = (getattr(spec, "cls", None) or "").lower()
                if cls_low in classifier.DE_UNTYPED_HOUSE or int(getattr(spec, "floors", 1) or 1) <= 1 or getattr(spec, "door", None) is None:
                    continue
        if yard_style == "hedge" and (
            (first is not None and clearance < DE_YARD_HEDGE_MIN_CLEAR_M)
            or (first is None and (wall_offset - offset) < DE_YARD_HEDGE_WALL_CLEAR_M)
        ):
            idx = int(_hash01(spec.seed, "de_slim_fence") * len(DE_SLIM_FENCE_STYLES)) % len(DE_SLIM_FENCE_STYLES)
            yard_style = DE_SLIM_FENCE_STYLES[idx]
        length = min(wall_w * abs(float(np.dot(along, tangent))), DE_YARD_MAX_LEN_M)
        if length < 1.8:
            continue

        # Skip if existing OSM mapped barrier/fence/hedge already covers this frontage.
        if barrier_blocks is not None:
            probe = np.array([centre - tangent * (length * 0.25), centre, centre + tangent * (length * 0.25)], dtype=np.float64)
            if _points_near_segments_safe(probe, barrier_blocks):
                continue

        a_edge = ring[edge]
        gaps = _driveway_gaps(centre, tangent, length * 0.5, a_edge, along, wall_w, getattr(spec, "door", None), edge, access_lines)

        # Carve out contiguous intervals outside doorway & driveway gaps.
        half_l = length * 0.5
        intervals = [(-half_l, half_l)]
        for g_c, g_hw in gaps:
            cut_lo, cut_hi = g_c - g_hw, g_c + g_hw
            nxt: list[tuple[float, float]] = []
            for s0, s1 in intervals:
                if cut_hi <= s0 or cut_lo >= s1:
                    nxt.append((s0, s1))
                else:
                    if cut_lo - s0 >= DE_YARD_MIN_SPAN_M:
                        nxt.append((s0, cut_lo))
                    if s1 - cut_hi >= DE_YARD_MIN_SPAN_M:
                        nxt.append((cut_hi, s1))
            intervals = nxt

        hedge_step_m = 1.50 if (fast_pass and level == "high") else (1.05 if level == "medium" else DE_HEDGE_STEP_M)
        for s0, s1 in intervals:
            line = np.array([centre + s0 * tangent, centre + s1 * tangent], dtype=np.float64)
            span = float(np.linalg.norm(line[1] - line[0]))
            if yard_style == "hedge":
                # Continuous overlapping German Liguster/Buchsbaum hedge line (1.15-1.40 m tall).
                inset = min(0.28, span * 0.22)
                usable = max(0.0, span - 2.0 * inset)
                n_seg = max(1, int(math.floor(usable / hedge_step_m)) + 1)
                for k in range(n_seg):
                    t_pos = 0.5 if n_seg == 1 else (inset + usable * (k / (n_seg - 1))) / max(span, 1e-6)
                    p = line[0] + (line[1] - line[0]) * t_pos
                    h_val = 1.15 + 0.25 * _hash01(spec.seed, "de_h", k)
                    pending.append((DE_HEDGE_GROUP, float(p[0]), float(p[1]), fences._yaw(*tangent), h_val, DE_HEDGE_Z_SEAT_M))
            else:
                if span < 0.66:
                    mid_p = 0.5 * (line[0] + line[1])
                    pending.append(("fr_fence_" + yard_style, float(mid_p[0]), float(mid_p[1]), fences._yaw(*tangent), fences.FR_HEIGHTS[yard_style], 0.0))
                else:
                    for p, d, panel_len in fences._panels(line, spacing=fences.PANEL_M):
                        row = fences._french_panel_row(yard_style, p, d, panel_len)
                        # Keep fence height upright even on short wing spans.
                        pending.append((row[0], row[1], row[2], row[3], max(float(row[4]), fences.FR_HEIGHTS[yard_style] * 0.85), row[5]))

    if not pending:
        return []

    # Final spatial safety pass against all carriageways, sidewalks, driveways, and buildings.
    drive_blocks = _expand_blocker_segments(access_lines, extra_hw=0.25)
    if rings_arr is None:
        rings_arr = [rr for r in (rings or ()) if (rr := _finite_2d(r, min_pts=3)) is not None]
    closed_rings = [(np.vstack([rr, rr[:1]]), 0.0) for rr in rings_arr]
    hedge_wall_blocks = _expand_blocker_segments(closed_rings, extra_hw=DE_YARD_HEDGE_WALL_CLEAR_M)
    fence_wall_blocks = _expand_blocker_segments(closed_rings, extra_hw=DE_YARD_FENCE_WALL_CLEAR_M)

    cand_rows: list[tuple] = []
    cand_xy: list[tuple[float, float]] = []
    for row in pending:
        px, py = float(row[1]), float(row[2])
        if math.isfinite(px) and math.isfinite(py) and roadsmod.box_owns(box, px, py):
            cand_rows.append(row)
            cand_xy.append((px, py))
    if not cand_rows:
        return []

    pts_all = np.asarray(cand_xy, dtype=np.float64)
    blocked = np.zeros(len(cand_rows), dtype=bool)
    for blk in (road_blocks, walk_blocks, drive_blocks):
        m = _points_near_segments_mask(pts_all, blk)
        if m is not None:
            blocked |= m

    is_hedge = np.array([r[0] == DE_HEDGE_GROUP for r in cand_rows], dtype=bool)
    if is_hedge.any():
        m_hw = _points_near_segments_mask(pts_all[is_hedge], hedge_wall_blocks)
        if m_hw is not None:
            blocked[is_hedge] |= m_hw
    if (~is_hedge).any():
        m_fw = _points_near_segments_mask(pts_all[~is_hedge], fence_wall_blocks)
        if m_fw is not None:
            blocked[~is_hedge] |= m_fw

    ring_bbs = [
        (rr, float(rr[:, 0].min()), float(rr[:, 1].min()), float(rr[:, 0].max()), float(rr[:, 1].max()))
        for rr in rings_arr
    ]
    cleared: list[tuple] = []
    for idx_r, row in enumerate(cand_rows):
        if blocked[idx_r]:
            continue
        px, py = cand_xy[idx_r]
        pt_v = pts_all[idx_r]
        if any(
            rx0 <= px <= rx1 and ry0 <= py <= ry1 and classifier._point_in_ring(pt_v, rr)
            for rr, rx0, ry0, rx1, ry1 in ring_bbs
        ):
            continue
        cleared.append(row)

    if not cleared:
        return []

    xs_list = [float(r[1]) for r in cleared]
    ys_list = [float(r[2]) for r in cleared]
    if not xs_list:
        return []
    n_cleared = len(cleared)
    if ground is not None:
        d_probe = 0.75
        for rx, ry in zip(xs_list[:n_cleared], ys_list[:n_cleared]):
            xs_list.extend((rx - d_probe, rx + d_probe, rx, rx))
            ys_list.extend((ry, ry, ry - d_probe, ry + d_probe))
    xs = np.array(xs_list, dtype=np.float64)
    ys = np.array(ys_list, dtype=np.float64)
    zs_all = _sample_ground(ground, xs, ys, fallback=0.0)
    if ground is not None:
        kept_rows: list[tuple] = []
        kept_zs: list[float] = []
        for idx_c, row in enumerate(cleared):
            p0 = n_cleared + idx_c * 4
            zw, ze, z_s, zn = zs_all[p0], zs_all[p0 + 1], zs_all[p0 + 2], zs_all[p0 + 3]
            if np.isfinite(zw) and np.isfinite(ze) and np.isfinite(z_s) and np.isfinite(zn):
                dz_dx = (float(ze) - float(zw)) / 1.5
                dz_dy = (float(zn) - float(z_s)) / 1.5
                if math.hypot(dz_dx, dz_dy) > DE_MAX_SLOPE_TAN:
                    continue
            kept_rows.append(row)
            kept_zs.append(float(zs_all[idx_c]))
        if not kept_rows:
            return []
        cleared = kept_rows
        zs = np.array(kept_zs, dtype=np.float64)
    else:
        zs = zs_all[:n_cleared]
    return fences._forest_rows(cleared, zs)
