"""Top-level bridge for the Germany (DE) Street-Level Immersion Enhancer.

Kept at top level (`server/de_enhancer.py`) so `revisit.source_closure` and
`tests/test_experimental.py` automatically discover `BNE_DE_STREET_IMMERSION`
and cache keys update deterministically when the switch or subpackage changes.
"""

import functools
import hashlib
import logging
import os

import numpy as np

import germany

log = logging.getLogger("earthd.de_enhancer")

PACKAGE_VERSION = 3


def enabled() -> bool:
    """True when `BNE_DE_STREET_IMMERSION` is set to an enabled truthy value."""
    return os.environ.get("BNE_DE_STREET_IMMERSION", "off").strip().lower() in {"1", "on", "true"}


def normalize_detail(de_detail) -> tuple[str, bool]:
    """Normalize `de_detail` arg (str, dict, tuple, or None) into `(level, fast_pass)`."""
    if isinstance(de_detail, dict):
        lvl = str(de_detail.get("level") or "medium").strip().lower()
        fast = bool(de_detail.get("fast", False))
    elif isinstance(de_detail, str):
        lvl = de_detail.strip().lower()
        fast = False
    elif isinstance(de_detail, (tuple, list)) and len(de_detail) >= 2:
        lvl = str(de_detail[0] or "medium").strip().lower()
        fast = bool(de_detail[1])
    else:
        lvl = "medium"
        fast = False
    if lvl not in {"low", "medium", "high"}:
        lvl = "medium"
    return lvl, fast


@functools.lru_cache(maxsize=1)
def _package_digest() -> str:
    pkg_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "de_street_enhancer")
    h = hashlib.sha1()
    try:
        names = sorted(n for n in os.listdir(pkg_dir) if n.endswith(".py"))
    except OSError:
        return "missing"
    for name in names:
        try:
            with open(os.path.join(pkg_dir, name), "rb") as fh:
                h.update(name.encode("utf-8") + b"\0" + fh.read())
        except OSError:
            pass
    return h.hexdigest()[:12]


def in_germany(frame, box) -> bool:
    """Fast tile-level check whether any part of `box` intersects Germany."""
    x0, y0, x1, y1 = box[:4]
    cx, cy = 0.5 * (x0 + x1), 0.5 * (y0 + y1)
    xs = np.array([x0, x1, x0, x1, cx], dtype=np.float64)
    ys = np.array([y0, y0, y1, y1, cy], dtype=np.float64)
    if not (np.isfinite(xs).all() and np.isfinite(ys).all()):
        return False
    la, lo, _ = frame.enu_to_geodetic(xs, ys, 0.0)
    if not germany.touches(lo, la):
        return False
    return bool(germany.contains(lo, la).any())


def cache_parts(frame, box, detail_level="medium") -> tuple:
    """Revisit key fragments for DE street enhancements, or `()` when off."""
    if not enabled():
        return ()
    x0, y0, x1, y1 = box[:4]
    xs = np.array([x0, x1], dtype=np.float64)
    ys = np.array([y0, y1], dtype=np.float64)
    if not (np.isfinite(xs).all() and np.isfinite(ys).all()):
        return (True, "outside")
    la, lo, _ = frame.enu_to_geodetic(xs, ys, 0.0)
    if not germany.touches(lo, la):
        return (True, "outside")
    lvl, _ = normalize_detail(detail_level)
    return (True, PACKAGE_VERSION, _package_digest(), germany.signature(), lvl)


def is_de_spec(spec) -> bool:
    """True when the DE enhancer is active and `spec` is tagged inside Germany."""
    return enabled() and bool(getattr(spec, "de_in", False))


def adapt_building(spec, attrs, lat, lon):
    """Apply German facade/roof classification and color grading to `spec` when enabled."""
    if not enabled():
        return spec
    from de_street_enhancer.facade_style import adapt_building as _adapt_building
    return _adapt_building(spec, attrs, lat, lon)


def apply_roof_overhangs(items) -> None:
    """Compute neighbor-safe per-edge roof overhangs across tile building items."""
    if not enabled() or not items:
        return
    from de_street_enhancer.facade_style import compute_roof_overhangs
    compute_roof_overhangs(items)


def offset_ring_safe(ring, edge_oh):
    """Outward polygon offset safe against self-intersections for DE roofs."""
    from de_street_enhancer.facade_style import offset_ring_safe as _offset_ring_safe
    return _offset_ring_safe(ring, edge_oh)


def cornice_look(spec, mat_idx):
    """Return `(mat_id, rgba)` for flat-roof parapets/cornices inside Germany."""
    from de_street_enhancer.facade_style import DE_CORNICE_RGB
    import buildings as bld
    return mat_idx[bld.custom_look(bld.FACADE, DE_CORNICE_RGB)]


def tile_geoms(lo_all, la_all, ends):
    """Return `(clo, cla, in_de_mask)` per building centroid when enabled & touching DE, else `None`."""
    if not enabled() or len(lo_all) == 0 or len(ends) == 0:
        return None
    if not germany.touches(lo_all, la_all):
        return None
    ends_i = np.asarray(ends, np.int64)
    starts = np.concatenate(([0], ends_i[:-1]))
    cnt = np.maximum(ends_i - starts, 1)
    cla = np.add.reduceat(la_all, starts) / cnt
    clo = np.add.reduceat(lo_all, starts) / cnt
    in_de = germany.contains(clo, cla)
    if not in_de.any():
        return None
    return clo, cla, in_de


def bake_building_depth(mesh, spec, gmin, gmax, z_eave, lite, mat_idx, de_detail=None) -> None:
    """Split vertical wall quads (Option B near) and bake Sockel + under-eave AO."""
    if not is_de_spec(spec):
        return
    from de_street_enhancer.facade_style import bake_building_depth as _bake_building_depth
    _bake_building_depth(mesh, spec, gmin, gmax, z_eave, lite, mat_idx, de_detail=de_detail)


def suppress_default_fences(frame, box) -> bool:
    """Suppress North American `_front_fence` rows on DE enhanced tiles."""
    return enabled() and in_germany(frame, box)


def suppress_default_shelters(frame, box) -> bool:
    """Suppress generic `busshelter_it` Forest props inside DE when batched shelters run."""
    return enabled() and in_germany(frame, box)


def prepare_shops(md, frame, tx, ty, items, out_dir, vfs_dir, de_detail=None):
    """Stage 1 hook (after `buildings.doors`, before `buildings.road_tile`)."""
    if not enabled() or not items:
        return None, None, set()
    import roads as roadsmod
    box = roadsmod.tile_bbox(tx, ty)
    if not in_germany(frame, box):
        return None, None, set()
    try:
        from de_street_enhancer.hooks import prepare_commercial_fascias
        return prepare_commercial_fascias(md, frame, tx, ty, items, out_dir, vfs_dir, de_detail=de_detail)
    except Exception as ex:
        log.warning("de_enhancer shops: tile %s_%s: %s: %s", tx, ty, type(ex).__name__, ex)
        return None, None, set()


def build_speed_cameras(
    md,
    frame,
    tx,
    ty,
    box,
    near_roads,
    rings,
    ground,
    de_detail=None,
):
    """Build German OSM speed-camera pillars (`de_radar`) and client enforcement gates (`deSpeedCameras`)."""
    if not enabled() or not near_roads or not in_germany(frame, box):
        return [], []
    try:
        from de_street_enhancer.hooks import build_speed_cameras as _build_speed_cameras
        safe_ground = (
            (lambda x, y: np.zeros(0, np.float64) if np.asarray(x).size == 0 else ground(x, y))
            if ground is not None
            else None
        )
        return _build_speed_cameras(
            md,
            frame,
            tx,
            ty,
            box,
            near_roads,
            rings,
            safe_ground,
            de_detail=de_detail,
        )
    except Exception as ex:
        log.warning("de_enhancer speed_cameras: tile %s_%s: %s: %s", tx, ty, type(ex).__name__, ex)
        return [], []


def finish_streets_and_yards(
    md,
    frame,
    tx,
    ty,
    box,
    near_roads,
    street_names,
    props,
    walks,
    items,
    drives,
    garage_drives,
    rings,
    ground,
    out_dir,
    vfs_dir,
    de_detail=None,
):
    """Stage 2 hook (after road furniture/fences/props, before `roads.write_tile`)."""
    if not enabled() or not in_germany(frame, box):
        return None, None, []
    try:
        from de_street_enhancer.hooks import build_streets_and_yards
        safe_ground = (
            (lambda x, y: np.zeros(0, np.float64) if np.asarray(x).size == 0 else ground(x, y))
            if ground is not None
            else None
        )
        return build_streets_and_yards(
            md,
            frame,
            tx,
            ty,
            box,
            near_roads or [],
            street_names or {},
            props or [],
            walks,
            items,
            drives or [],
            garage_drives or [],
            rings,
            safe_ground,
            out_dir,
            vfs_dir,
            de_detail=de_detail,
        )
    except Exception as ex:
        log.warning("de_enhancer streets/yards: tile %s_%s: %s: %s", tx, ty, type(ex).__name__, ex)
        return None, None, []
