"""Spatial classification and POI-to-building matching for Germany (`DE`).

Reads Overture `places` attributes on demand only when enabled inside Germany,
identifies true street-facing commercial `shopfront` walls, and selects
eligible residential houses for German front-yard hedges and fences.
"""

from dataclasses import dataclass
import hashlib
import math
import numpy as np

import dnp
import germany
import mapgeom

from . import brand_registry


RETAIL_CATEGORIES = frozenset({
    "supermarket",
    "grocery",
    "convenience_store",
    "discount_store",
    "bakery",
    "pastry_shop",
    "pharmacy",
    "chemist",
    "drugstore",
    "bank",
    "financial_service",
    "post_office",
    "hardware_store",
    "home_improvement",
    "cafe",
    "restaurant",
    "fast_food",
    "kebab_shop",
    "department_store",
    "retail",
    "shop",
    "commercial",
    "butcher",
    "bookshop",
    "florist",
    "optician",
    "hair_salon",
})

COMMERCIAL_SHOP_ASSIGN_SHARE = 0.78
MAX_POI_MATCH_M = 5.5
COURTYARD_RAY_CLEAR_M = 2.6
MIN_SHOP_WALL_M = 3.2
MIN_SHOP_HEIGHT_M = 3.1

DE_HOUSE_CLASSES = frozenset({
    "house",
    "detached",
    "semidetached_house",
    "terrace",
    "apartments",
    "residential",
    "bungalow",
    "villa",
    "farm",
    "farmhouse",
    "cabin",
})
DE_UNTYPED_HOUSE = frozenset({"", "building", "yes"})
DE_SKIP_CLASSES = frozenset({
    "church",
    "chapel",
    "cathedral",
    "shed",
    "garage",
    "garages",
    "carport",
    "roof",
    "greenhouse",
    "glasshouse",
    "storage_tank",
    "silo",
    "industrial",
    "warehouse",
    "factory",
    "hangar",
    "bridge_structure",
    "bridge_part",
    "bridge_pier",
    "mast",
    "pyramid",
    "toll_booth",
})

# Weighted front-yard style mix for suburban/residential German properties (~65% hedges, ~35% fences).
DE_YARD_STYLES = (
    ("hedge", 0.65),
    ("iron", 0.14),
    ("slats", 0.11),
    ("wood", 0.10),
)


@dataclass(frozen=True)
class RetailCandidate:
    """Compact per-POI tuple cached per cell for street-level matching."""

    poi_id: str
    lon: float
    lat: float
    brand_key: str
    display_name: str
    category: str
    confidence: float


@dataclass(frozen=True)
class ShopTarget:
    """Resolved commercial fascia placement rectangle on a street-facing wall."""

    building_idx: int
    center_xy: np.ndarray       # tile-local (2,)
    d_along: np.ndarray         # unit vector (2,)
    out_normal: np.ndarray      # outward wall unit vector (2,)
    width_m: float
    height_m: float
    z_bottom: float
    z_top: float
    spec_brand: brand_registry.BrandSpec
    label: str


@dataclass(frozen=True)
class HouseNumberTarget:
    """Resolved German enamel house number plaque placement beside `spec.door`."""

    center_xy: np.ndarray       # tile-local (2,)
    d_along: np.ndarray         # unit vector (2,)
    out_normal: np.ndarray      # outward wall unit vector (2,)
    z_mid: float
    number: str


def _hash01(*parts) -> float:
    h = hashlib.blake2b("|".join(str(p) for p in parts).encode("utf-8"), digest_size=8).digest()
    return int.from_bytes(h, "big") / float(1 << 64)


def _point_in_ring(pt: np.ndarray, ring: np.ndarray) -> bool:
    """Even-odd ray casting test for a 2D point inside a closed ring."""
    ring_arr = np.asarray(ring, dtype=np.float64)
    if ring_arr.ndim != 2 or ring_arr.shape[0] < 3 or ring_arr.shape[1] < 2:
        return False
    px, py = float(pt[0]), float(pt[1])
    if not (math.isfinite(px) and math.isfinite(py)):
        return False
    x = ring_arr[:, 0]
    y = ring_arr[:, 1]
    x_next = np.roll(x, -1)
    y_next = np.roll(y, -1)
    cond = (y > py) != (y_next > py)
    with np.errstate(divide="ignore", invalid="ignore"):
        x_int = (x_next - x) * (py - y) / np.where(cond, y_next - y, 1.0) + x
    crossings = cond & (px < x_int)
    return bool(np.count_nonzero(crossings) & 1)


def _ray_hits_building(origin: np.ndarray, direction: np.ndarray, max_dist: float, other_rings: list[np.ndarray]) -> bool:
    """Return True if a short outward ray intersects another building footprint."""
    ox, oy = float(origin[0]), float(origin[1])
    dx, dy = float(direction[0]), float(direction[1])
    for r in other_rings:
        if len(r) < 3:
            continue
        x0, y0 = r[:, 0].min(), r[:, 1].min()
        x1, y1 = r[:, 0].max(), r[:, 1].max()
        ex = ox + dx * max_dist
        ey = oy + dy * max_dist
        if max(ox, ex) < x0 or min(ox, ex) > x1 or max(oy, ey) < y0 or min(oy, ey) > y1:
            continue
        a = r
        b = np.roll(r, -1, axis=0)
        ab = b - a
        denom = dx * ab[:, 1] - dy * ab[:, 0]
        valid = np.abs(denom) > 1e-8
        if not valid.any():
            continue
        ap = np.column_stack((a[:, 0] - ox, a[:, 1] - oy))
        with np.errstate(divide="ignore", invalid="ignore"):
            t = (ap[:, 0] * ab[:, 1] - ap[:, 1] * ab[:, 0]) / np.where(valid, denom, 1.0)
            u = (ap[:, 0] * dy - ap[:, 1] * dx) / np.where(valid, denom, 1.0)
        if (valid & (t >= 0.0) & (t <= max_dist) & (u >= 0.0) & (u <= 1.0)).any():
            return True
    return False


def _extract_cell_pois(f) -> list[RetailCandidate]:
    """Memoize recognized DE retail POIs on a `places` layer without altering `places_slim`."""
    if f is None or not len(f):
        return []
    cached = f.__dict__.get("_de_retail_pois")
    if cached is not None:
        return cached
    attrs = getattr(f, "attrs", {}) or {}
    if "name" not in attrs and "brand_name" not in attrs and "taxonomy" not in attrs:
        f.__dict__["_de_retail_pois"] = []
        return []

    n = len(f.kind)
    part_off = np.asarray(f.part_off, np.int64)
    ring_off = np.asarray(f.ring_off, np.int64)
    coord_off = np.asarray(f.coord_off, np.int64)
    lonlat = np.asarray(f.lonlat, np.float64)
    ids = getattr(f, "ids", None)

    op_status = attrs.get("operating_status")
    brand_qid = attrs.get("brand_wikidata")
    brand_names = attrs.get("brand_name")
    names = attrs.get("name")
    basic_cats = attrs.get("basic_category")
    taxonomies = attrs.get("taxonomy")
    confs = attrs.get("confidence")

    out: list[RetailCandidate] = []
    for i in range(n):
        if op_status is not None and str(op_status[i] or "").strip().lower() in ("closed", "permanently_closed"):
            continue
        p0 = int(part_off[i])
        if p0 >= int(part_off[i + 1]):
            continue
        r0 = int(ring_off[p0])
        if r0 >= int(ring_off[p0 + 1]):
            continue
        c0 = int(coord_off[r0])
        if c0 >= int(coord_off[r0 + 1]):
            continue
        lon, lat = float(lonlat[c0, 0]), float(lonlat[c0, 1])
        cat = str((taxonomies[i] if taxonomies is not None else None)
                  or (basic_cats[i] if basic_cats is not None else None) or "").strip().lower()
        qid = brand_qid[i] if brand_qid is not None else None
        bname = brand_names[i] if brand_names is not None else None
        pname = names[i] if names is not None else None

        brand_spec, label = brand_registry.match_poi(qid, bname, pname, cat, lat=lat)
        if brand_spec is None or not label:
            continue
        if brand_spec.key == "local_shop" and cat and cat not in RETAIL_CATEGORIES:
            # Skip non-retail POIs like benches/trees/peaks unless clearly shop-like.
            if not any(tok in cat for tok in ("shop", "store", "market", "cafe", "bakery", "bank", "restaurant")):
                continue
        conf = float(confs[i]) if (confs is not None and confs[i] is not None and np.isfinite(confs[i])) else 0.7
        pid = str(ids[i]) if ids is not None else f"poi_{i}"
        out.append(RetailCandidate(pid, lon, lat, brand_spec.key, label, cat, conf))

    f.__dict__["_de_retail_pois"] = out
    return out


def load_tile_pois(md, frame, tile_cells, x0: float, y0: float) -> list[tuple[RetailCandidate, np.ndarray]]:
    """Fetch and project DE retail POIs near the tile into tile-local ENU metres."""
    if md is None:
        return []
    out: list[tuple[RetailCandidate, np.ndarray]] = []
    seen_ids: set[str] = set()
    cands: list[RetailCandidate] = []
    for key in tile_cells:
        try:
            cd = md.cell(key, layers=("places",), kind="demand")
            layer = cd.layers.get("places")
        except Exception:
            continue
        for poi in _extract_cell_pois(layer):
            if poi.poi_id in seen_ids:
                continue
            seen_ids.add(poi.poi_id)
            cands.append(poi)

    if not cands:
        return []

    lons = np.ascontiguousarray([c.lon for c in cands], dtype=np.float64)
    lats = np.ascontiguousarray([c.lat for c in cands], dtype=np.float64)
    if lons.size == 0 or lons.shape != lats.shape or not (np.isfinite(lons).all() and np.isfinite(lats).all()):
        return []
    in_de = germany.contains(lons, lats)
    if not np.any(in_de):
        return []

    e, n, _ = frame.geodetic_to_enu(lats, lons, np.zeros(len(cands), dtype=np.float64))
    for i, poi in enumerate(cands):
        if in_de[i]:
            xy = np.array([float(e[i]) - x0, float(n[i]) - y0], dtype=np.float64)
            if -25.0 <= xy[0] <= 281.0 and -25.0 <= xy[1] <= 281.0:
                out.append((poi, xy))
    return out


def _pick_street_edge(spec, ring: np.ndarray, other_rings: list[np.ndarray]) -> int | None:
    """Select the visible street-facing wall edge index for shop fascia placement."""
    candidates: list[int] = []
    if getattr(spec, "sign", None) is not None:
        candidates.append(int(spec.sign))
    if getattr(spec, "front", None) is not None and int(spec.front) not in candidates:
        candidates.append(int(spec.front))
    for e in getattr(spec, "street", None) or ():
        if int(e) not in candidates:
            candidates.append(int(e))

    n = len(ring)
    for edge in candidates:
        if edge < 0 or edge >= n:
            continue
        a, b = ring[edge], ring[(edge + 1) % n]
        vec = b - a
        L = float(np.hypot(vec[0], vec[1]))
        if L < MIN_SHOP_WALL_M:
            continue
        d = vec / L
        out = np.array([d[1], -d[0]], dtype=np.float64)
        mid = 0.5 * (a + b)
        if _ray_hits_building(mid + out * 0.25, out, COURTYARD_RAY_CLEAR_M, other_rings):
            continue
        return edge
    return None


def classify_commercial_buildings(
    items: list,
    tile_pois: list[tuple[RetailCandidate, np.ndarray]],
    frame,
    x0: float,
    y0: float,
    tile_size: float = 256.0,
) -> tuple[list[ShopTarget], set[int]]:
    """Classify eligible German commercial facades into `ShopTarget` placements.

    Returns `(targets, suppress_sign_spec_ids)` where `suppress_sign_spec_ids` marks
    buildings whose generic flat `buildings._signs()` boxes should be suppressed.
    """
    import buildings

    if not items:
        return [], set()

    targets: list[ShopTarget] = []
    suppress_ids: set[int] = set()
    used_pois: set[int] = set()
    rings = []
    for spec, _, _ in items:
        if (spec.min_h or 0.0) <= 0.5:
            arr = np.asarray(spec.ring, dtype=np.float64)
            if arr.ndim == 2 and arr.shape[0] >= 3 and arr.shape[1] >= 2 and np.isfinite(arr[:, :2]).all():
                rings.append(arr[:, :2])

    for idx, (spec, gmin, gmax) in enumerate(items):
        if (spec.min_h or 0.0) > 0.5 or getattr(spec, "portal", False) or getattr(spec, "deck", False) or getattr(spec, "ship", False):
            continue
        cls = (getattr(spec, "cls", None) or "").lower()
        if cls in DE_SKIP_CLASSES:
            continue
        is_shop = bool(getattr(spec, "shop", False)) or cls in buildings.SHOP_CLASSES
        if not is_shop:
            continue
        if float(getattr(spec, "height", 0.0) or 0.0) < MIN_SHOP_HEIGHT_M:
            continue
        # Require a pitched building to explicitly be flagged as street-facing shopfront.
        if getattr(spec, "roof", "flat") != "flat" and not getattr(spec, "shop", False):
            continue

        ring = np.asarray(spec.ring, dtype=np.float64)
        if ring.ndim != 2 or ring.shape[0] < 3 or ring.shape[1] < 2 or not np.isfinite(ring[:, :2]).all():
            continue
        others = [r for r in rings if r is not ring and not np.array_equal(r, ring)]
        edge = _pick_street_edge(spec, ring, others)
        if edge is None:
            continue

        a, b = ring[edge], ring[(edge + 1) % len(ring)]
        L = float(np.hypot(b[0] - a[0], b[1] - a[1]))
        d = (b - a) / L
        out = np.array([d[1], -d[0]], dtype=np.float64)
        mid = 0.5 * (a + b)

        # Enforce strict half-open tile ownership on fascia midpoint to avoid duplicates across borders.
        if not (0.0 <= float(mid[0]) < tile_size and 0.0 <= float(mid[1]) < tile_size):
            continue

        lat_m, lon_m, _ = frame.enu_to_geodetic(float(mid[0]) + x0, float(mid[1]) + y0, 0.0)
        lat_f, lon_f = float(lat_m), float(lon_m)
        if not germany.contains(lon_f, lat_f)[0]:
            continue

        # Vertical placement directly above ground-floor shopfront windows without exceeding parapet/eaves.
        z_base = float(gmax if getattr(spec, "windows", True) is False else gmin)
        z_eave = buildings.base_z(spec, gmin, gmax) + float(spec.min_h or 0.0) + float(spec.height)
        if getattr(spec, "windows", True) is False:
            z_band_top = min(float(gmax) + buildings.GROUND_FLOOR_SHOP_M + 1.15, z_eave)
        elif (spec.floors or 1) > 1:
            z_band_top = z_eave - (spec.floors - 1) * float(spec.floor_h or buildings.FLOOR_M)
        else:
            z_band_top = z_eave

        fascia_h = 0.64 if L < 10.0 else 0.78
        # Lower Z by ~0.12 m and stay cleanly below overhanging flat cornices (0.45 m down) or pitched eaves.
        has_cornice = (
            getattr(spec, "roof", "flat") == "flat"
            and not getattr(spec, "plain", False)
            and (spec.floors or 1) <= 6
        )
        cornice_clear = (buildings.CORNICE_DOWN_M + 0.06) if has_cornice else 0.0
        if getattr(spec, "roof", "flat") != "flat":
            oh_max = max(getattr(spec, "de_eaves", None) or (buildings.EAVE_M,))
            eave_clear = max(0.26, oh_max * math.tan(math.radians(buildings.roof_pitch(spec))) + 0.08)
        else:
            eave_clear = 0.26
        z_top = min(z_band_top - 0.22, z_eave - max(cornice_clear, eave_clear))
        z_bot = max(float(gmax) + 2.28, z_top - fascia_h)
        if z_top - z_bot < 0.42:
            continue

        fascia_w = min(L - 0.65, max(2.6, L * 0.72, 4.8))
        fascia_w = min(fascia_w, L - 0.40)
        if fascia_w < 2.2:
            continue

        # 1. Try spatial match with Overture `places` POI inside building or adjacent to street facade.
        best_poi_idx = None
        best_score = MAX_POI_MATCH_M + 1.0
        for p_idx, (poi, p_xy) in enumerate(tile_pois):
            if p_idx in used_pois:
                continue
            inside = _point_in_ring(p_xy, ring)
            # Perpendicular/segment distance to street wall.
            t_seg = float(np.clip(np.dot(p_xy - a, d) / max(L, 1e-6), 0.0, 1.0))
            dist_wall = float(np.hypot(*(p_xy - (a + d * (t_seg * L)))))
            if inside or dist_wall <= MAX_POI_MATCH_M:
                score = (0.0 if inside else dist_wall) - 0.25 * poi.confidence
                if score < best_score:
                    best_score = score
                    best_poi_idx = p_idx

        if best_poi_idx is not None:
            used_pois.add(best_poi_idx)
            poi, _ = tile_pois[best_poi_idx]
            spec_brand = brand_registry.BY_KEY[poi.brand_key]
            label = poi.display_name
        else:
            bname = getattr(spec, "name", None)
            if bname:
                bmatch, blabel = brand_registry.match_poi(None, bname, bname, cls, lat=lat_f)
                if bmatch is not None and blabel:
                    spec_brand, label = bmatch, blabel
                else:
                    spec_brand, label = brand_registry.fallback_brand(_hash01(spec.seed, "de_brand"), lat_f, cls)
            else:
                # Deterministic branded coverage (~78%) so commercial streets keep natural variety.
                if _hash01(spec.seed, "de_shop_on") >= COMMERCIAL_SHOP_ASSIGN_SHARE:
                    continue
                spec_brand, label = brand_registry.fallback_brand(_hash01(spec.seed, "de_brand"), lat_f, cls)

        center = mid + out * 0.15  # Push outward (+0.04 m) past flat cornices/window frames without z-fighting
        targets.append(
            ShopTarget(
                building_idx=idx,
                center_xy=center,
                d_along=d,
                out_normal=out,
                width_m=fascia_w,
                height_m=z_top - z_bot,
                z_bottom=z_bot,
                z_top=z_top,
                spec_brand=spec_brand,
                label=label,
            )
        )
        suppress_ids.add(id(spec))

    return targets, suppress_ids


def _pick_yard_style(seed: float) -> str:
    acc = 0.0
    s = max(0.0, min(0.999999, float(seed)))
    for name, w in DE_YARD_STYLES:
        acc += w
        if s <= acc:
            return name
    return DE_YARD_STYLES[0][0]


def classify_residential_yards(
    items: list,
    frame,
    x0: float,
    y0: float,
    tile_size: float = 256.0,
) -> list[tuple[object, np.ndarray, str]]:
    """Return eligible German residential houses `[(spec, world_ring, style)]`."""
    import buildings

    if not items:
        return []
    origin = np.array([x0, y0], dtype=np.float64)
    cands: list[tuple[object, np.ndarray, str, float, float]] = []

    for spec, _, _ in items:
        if (spec.min_h or 0.0) > 0.5 or getattr(spec, "portal", False) or getattr(spec, "deck", False) or getattr(spec, "ship", False):
            continue
        if getattr(spec, "shop", False):
            continue
        cls = (getattr(spec, "cls", None) or "").lower()
        if cls in DE_SKIP_CLASSES or (cls not in DE_HOUSE_CLASSES and cls not in DE_UNTYPED_HOUSE):
            continue
        # Guard only against obviously windowless/plain industrial sheds on untyped footprints.
        if cls in DE_UNTYPED_HOUSE and getattr(spec, "roof", "flat") == "flat":
            if getattr(spec, "plain", False) and getattr(spec, "windows", True) is False:
                continue
        if (getattr(spec, "floors", 1) or 1) > 3:
            continue

        ring = np.asarray(spec.ring, dtype=np.float64) + origin
        if ring.ndim != 2 or ring.shape[0] < 3 or ring.shape[1] < 2 or not np.isfinite(ring[:, :2]).all():
            continue
        area = abs(buildings._area2(ring)) / 2.0
        min_area = 34.0 if cls in DE_UNTYPED_HOUSE and (spec.floors or 1) == 1 else 24.0
        if not (min_area <= area <= 650.0):
            continue
        c = ring.mean(axis=0)
        if not (x0 <= float(c[0]) < x0 + tile_size and y0 <= float(c[1]) < y0 + tile_size):
            continue
        style = _pick_yard_style(_hash01(spec.seed, "de_yard_style"))
        cands.append((spec, ring, style, float(c[0]), float(c[1])))

    if not cands:
        return []

    xs = np.ascontiguousarray([c[3] for c in cands], dtype=np.float64)
    ys = np.ascontiguousarray([c[4] for c in cands], dtype=np.float64)
    if xs.size == 0 or not (np.isfinite(xs).all() and np.isfinite(ys).all()):
        return []
    inside = germany.de_at(frame, xs, ys)
    return [(spec, ring, style) for (spec, ring, style, _, _), ok in zip(cands, inside) if ok]


def collect_housenumbers(items: list, suppress_ids: set[int] | frozenset[int] = frozenset()) -> list[HouseNumberTarget]:
    """Collect 3D German house number plaques beside `spec.door` (explicit `addr:housenumber` or deterministic fallback)."""
    import buildings

    if not items:
        return []
    targets: list[HouseNumberTarget] = []
    for spec, _gmin, gmax in items:
        if id(spec) in suppress_ids or getattr(spec, "shop", False) or getattr(spec, "plain", False):
            continue
        if (getattr(spec, "min_h", 0.0) or 0.0) > 0.5 or getattr(spec, "portal", False) or getattr(spec, "deck", False) or getattr(spec, "ship", False):
            continue
        cls = (getattr(spec, "cls", None) or "").lower()
        if cls in DE_SKIP_CLASSES:
            continue
        door = getattr(spec, "door", None)
        if door is None:
            continue
        ring = buildings.drawn_ring(spec)
        if ring is None or len(ring) < 3:
            continue
        edge_i, along_d = int(door[0]), float(door[1])
        if not (0 <= edge_i < len(ring)):
            continue
        a, b = ring[edge_i], ring[(edge_i + 1) % len(ring)]
        L = float(math.hypot(*(b - a)))
        if L < 2.2:
            continue
        d_along = (b - a) / L
        sign_out = 1.0 if buildings._area2(ring) > 0 else -1.0
        out_normal = np.array([d_along[1], -d_along[0]], dtype=np.float64) * sign_out

        # Shift horizontally 0.62 m toward wall center so plaque sits cleanly beside the front door.
        shift = 0.62 if along_d <= 0.5 * L else -0.62
        s_pos = float(np.clip(along_d + shift, 0.35, L - 0.35))
        pos_xy = a + d_along * s_pos + out_normal * 0.03
        door_g = buildings.door_ground(spec, edge_i, along_d, gmax)
        z_mid = float(door_g) + 2.02

        explicit = getattr(spec, "de_hn", None)
        if explicit:
            num = str(explicit)
        else:
            # Deterministic German street-sequential parity number with occasional 'a'/'b' suffix on narrow houses.
            c_mid = ring.mean(axis=0)
            base_num = 2 + int(_hash01(spec.seed, "de_hn_num", round(float(c_mid[0]) / 24.0)) * 46) * 2
            if float(out_normal[1]) < 0:
                base_num -= 1
            suffix = ""
            if L < 8.5 and _hash01(spec.seed, "de_hn_suf") < 0.18:
                suffix = "a" if _hash01(spec.seed, "de_hn_ab") < 0.7 else "b"
            num = f"{base_num}{suffix}"

        targets.append(
            HouseNumberTarget(
                center_xy=pos_xy,
                d_along=d_along,
                out_normal=out_normal,
                z_mid=z_mid,
                number=num,
            )
        )
    return targets
