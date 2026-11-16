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

PACKAGE_VERSION = 1


def enabled() -> bool:
    """True when `BNE_DE_STREET_IMMERSION` is set to an enabled truthy value."""
    return os.environ.get("BNE_DE_STREET_IMMERSION", "off").strip().lower() in {"1", "on", "true"}


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


def cache_parts(frame, box) -> tuple:
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
    return (True, PACKAGE_VERSION, _package_digest(), germany.signature())


def suppress_default_fences(frame, box) -> bool:
    """Suppress North American `_front_fence` rows on DE enhanced tiles."""
    return enabled() and in_germany(frame, box)


def prepare_shops(md, frame, tx, ty, items, out_dir, vfs_dir):
    """Stage 1 hook (after `buildings.doors`, before `buildings.road_tile`)."""
    if not enabled() or not items:
        return None, None, set()
    import roads as roadsmod
    box = roadsmod.tile_bbox(tx, ty)
    if not in_germany(frame, box):
        return None, None, set()
    try:
        from de_street_enhancer.hooks import prepare_commercial_fascias
        return prepare_commercial_fascias(md, frame, tx, ty, items, out_dir, vfs_dir)
    except Exception as ex:
        log.warning("de_enhancer shops: tile %s_%s: %s: %s", tx, ty, type(ex).__name__, ex)
        return None, None, set()


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
        )
    except Exception as ex:
        log.warning("de_enhancer streets/yards: tile %s_%s: %s: %s", tx, ty, type(ex).__name__, ex)
        return None, None, []
