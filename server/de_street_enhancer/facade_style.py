"""Authentic German (`DE`) facade palettes, color grading, roof overhangs, and baked vertex-color depth.

Operates strictly inside Germany when `BNE_DE_STREET_IMMERSION` is enabled, keeping:
- Zero extra materials and zero extra draw calls (reuses `buildings.MATERIALS` + vertex colors)
- Zero extra collision triangles (`collision_mesh` stays untouched)
- Determinism keyed on `spec.seed` and geographic coordinates across near/far tiles.
"""

import colorsys
import hashlib
import math
import numpy as np

import dmath
import dnp
import germany


# Regional German mineral plaster palettes (sRGB 0..1):
# Warm mineral whites (Altweiss / Kalkweiss), sandstone, muted ochre, stone-grey/greige, rare heritage accents.
DE_PLASTER_SOUTH = (
    (0.87, 0.85, 0.80),  # Altweiss
    (0.84, 0.81, 0.75),  # Kalkweiss warm
    (0.84, 0.77, 0.65),  # Sandstein hell
    (0.80, 0.72, 0.59),  # Sandstein warm
    (0.81, 0.69, 0.49),  # gedämpftes Ocker (Bavaria/Gruenderzeit)
    (0.77, 0.65, 0.47),  # Ocker warm
    (0.74, 0.72, 0.68),  # Steingrau hell
    (0.69, 0.67, 0.63),  # Greige
    (0.76, 0.61, 0.53),  # gedämpftes Terrakotta (heritage)
    (0.68, 0.71, 0.64),  # gedämpftes Salbei (heritage)
)

DE_PLASTER_EAST = (
    (0.86, 0.84, 0.80),  # Altweiss
    (0.82, 0.78, 0.71),  # Kalkputz warm
    (0.81, 0.74, 0.62),  # Elbsandstein
    (0.79, 0.68, 0.50),  # Gruenderzeit Ocker
    (0.73, 0.72, 0.69),  # Betongrau / Putz
    (0.66, 0.65, 0.62),  # Steingrau
    (0.75, 0.71, 0.65),  # Taupe hell
    (0.69, 0.71, 0.65),  # Salbeigrau
)

DE_PLASTER_NORTH = (
    (0.86, 0.84, 0.80),  # Altweiss
    (0.82, 0.79, 0.73),  # Kalkputz
    (0.78, 0.73, 0.64),  # Sandstein gedämpft
    (0.73, 0.72, 0.70),  # Steingrau
    (0.67, 0.66, 0.64),  # Schiefergrau hell
    (0.63, 0.61, 0.58),  # Taupe / Greige
    (0.76, 0.71, 0.65),  # Warmgrau
)

# Clinker / brick tints applied on `FACADE` BAND_BRICK (whose base texture mean is ~[0.63, 0.52, 0.48]).
DE_BRICK_TINTS = (
    (0.68, 0.46, 0.39),  # klassischer Klinker rotbraun
    (0.56, 0.37, 0.32),  # dunkler Ruhr-Klinker
    (0.75, 0.54, 0.44),  # norddeutscher Rotklinker
    (0.62, 0.42, 0.37),  # gebrannter Backstein
    (0.83, 0.72, 0.59),  # Gelbklinker / Sandklinker
)

# German commercial / retail / modern mineral tones (no pastel slop).
DE_COMMERCIAL_TINTS = (
    (0.84, 0.83, 0.80),  # mineral white
    (0.75, 0.74, 0.71),  # warm concrete grey
    (0.67, 0.67, 0.66),  # neutral stone grey
    (0.80, 0.76, 0.69),  # muted limestone
    (0.58, 0.59, 0.60),  # slate grey
)

DE_INDUSTRIAL_PANEL_TINTS = (
    (0.74, 0.74, 0.73),
    (0.64, 0.65, 0.66),
    (0.79, 0.77, 0.73),
    (0.56, 0.57, 0.58),
    (0.68, 0.65, 0.61),
)

DE_INDUSTRIAL_METAL_TINTS = (
    (0.68, 0.70, 0.72),  # galvanized / silver
    (0.52, 0.54, 0.57),  # anthracite steel
    (0.62, 0.60, 0.57),  # warm grey cladding
    (0.55, 0.60, 0.65),  # muted steel blue
    (0.60, 0.41, 0.38),  # muted oxide red
)

DE_OFFICE_GLASS_TINTS = (
    (0.88, 0.90, 0.92),  # silver neutral
    (0.72, 0.79, 0.86),  # cool steel blue
    (0.62, 0.64, 0.67),  # charcoal smoked glass
    (0.76, 0.83, 0.80),  # muted architectural green-grey
    (0.84, 0.78, 0.70),  # warm bronze glass
)

# Roof tints per material (clay tiles already have terracotta texture mean ~(0.625, 0.465, 0.361)).
DE_ROOF_TILE_TINTS = (
    (0.95, 0.91, 0.88),  # classic red clay Pfanne
    (0.88, 0.78, 0.72),  # warm aged terracotta
    (0.76, 0.67, 0.62),  # weathered brown-red clay
    (0.92, 0.84, 0.78),  # bright Biberschwanz clay
    (0.40, 0.39, 0.40),  # engobe anthracite Pfanne
    (0.30, 0.30, 0.32),  # dark slate-black Pfanne
)

DE_ROOF_SLATE_DARK_TINTS = (
    (0.96, 0.96, 0.98),  # natural dark slate
    (0.82, 0.83, 0.86),  # deep anthracite
    (1.12, 1.10, 1.08),  # weathered slate grey
)

DE_ROOF_FLAT_TINTS = (
    (0.74, 0.74, 0.73),  # gravel flat roof
    (0.56, 0.56, 0.58),  # dark bitumen
    (0.44, 0.44, 0.46),  # weathered tar felt
    (0.66, 0.64, 0.60),  # warm aggregate
)

DE_CORNICE_RGB = (0.81, 0.80, 0.77)

# Eave / gable overhang constants (m)
OVERHANG_STANDARD_M = 0.34
OVERHANG_ALPINE_SOUTH_M = 0.38
OVERHANG_URBAN_M = 0.31
NEIGHBOR_FLUSH_M = 0.45
NEIGHBOR_CLEAR_M = 0.75

# Baked depth constants (Option B: near-only horizontal split + linear-light vertex colors)
SOCKEL_HEIGHT_M = 0.75
EAVE_AO_HEIGHT_M = 0.35


def _h01(*parts) -> float:
    h = hashlib.blake2b("|".join(str(p) for p in parts).encode("utf-8"), digest_size=8).digest()
    return int.from_bytes(h, "big") / float(1 << 64)


def _pick(seq, *seed_parts):
    return seq[int(_h01(*seed_parts) * len(seq)) % len(seq)]


def region_zone(lat: float | None, lon: float | None) -> str:
    """Coarse German architectural region: 'north_nw', 'central_east', or 'south'."""
    if lat is None or lon is None:
        return "central_east"
    la, lo = float(lat), float(lon)
    if (la >= 50.6 and lo <= 10.6) or la >= 52.8:
        return "north_nw"
    if la < 50.0:
        return "south"
    return "central_east"


def grade_wall_rgb(rgb: tuple[float, float, float], is_brick: bool = False) -> tuple[float, float, float]:
    """Clamp bright/pastel/oversaturated mapped wall colors into an authentic German mineral palette."""
    r, g, b = (max(0.0, min(1.0, float(v))) for v in rgb[:3])
    h, s, v = colorsys.rgb_to_hsv(r, g, b)
    # Cool hues (cyan/blue/green/purple: ~0.22..0.85) get stricter saturation cap so neon/baby pastels turn muted.
    cool = 0.22 <= h <= 0.88
    max_sat = 0.40 if is_brick else (0.18 if cool else 0.32)
    if s > max_sat:
        # Soft compression above half-cap so slightly muted colors keep character while extremes tame down.
        s = max_sat
    if is_brick:
        v = max(0.32, min(0.76, v))
    else:
        v = max(0.38, min(0.87, v))
    rr, gg, bb = colorsys.hsv_to_rgb(h, s, v)
    # Subtle warm mineral bias on near-neutral whites so pure RGB whites read like lime/mineral plaster.
    if not is_brick and s < 0.06 and v > 0.78:
        bb = max(0.0, bb * 0.965)
        gg = max(0.0, gg * 0.990)
    return (round(rr, 4), round(gg, 4), round(bb, 4))


def grade_roof_rgb(rgb: tuple[float, float, float], base_mat: str) -> tuple[float, float, float]:
    """Clamp oversaturated/neon mapped or aerial-sampled roof tints."""
    import buildings as bld

    r, g, b = (max(0.0, min(1.25, float(v))) for v in rgb[:3])
    h, s, v = colorsys.rgb_to_hsv(min(r, 1.0), min(g, 1.0), min(b, 1.0))
    if base_mat == bld.ROOF_TILES:
        # Base texture is already warm terracotta; keep tints near neutral or dark engobe.
        max_sat = 0.28
        v = max(0.28, min(0.96, v))
    elif base_mat in (bld.ROOF_SLATE_DARK, bld.ROOF_SLATE_ROUND):
        max_sat = 0.14
        v = max(0.24, min(1.0, v))
    else:
        cool = 0.20 <= h <= 0.88
        max_sat = 0.18 if cool else 0.42
        v = max(0.22, min(0.72, v))
    s = min(s, max_sat)
    rr, gg, bb = colorsys.hsv_to_rgb(h, s, v)
    return (round(rr, 4), round(gg, 4), round(bb, 4))


def is_de_spec(spec) -> bool:
    """True when `spec` belongs to an enhanced building inside Germany."""
    return bool(getattr(spec, "de_in", False))


def adapt_building(spec, attrs: dict, lat: float | None, lon: float | None):
    """Apply German architectural material classification and color grading in-place on `spec`."""
    import buildings as bld

    cls = (getattr(spec, "cls", None) or "").lower()
    if (
        cls in {"landmark", "ship", "pier", "pyramid", "elevator", "tank", "greenhouse", "mast",
                "bridge_part", "bridge_pier", "toll_booth"}
        or cls in bld.BRIDGE_CLASSES
        or cls in bld.CANOPY_CLASSES
        or getattr(spec, "fr_house", None)
        or getattr(spec, "deck", False)
    ):
        return spec

    de_in = attrs.get("_de_in")
    if de_in is False:
        return spec
    if de_in is None:
        if lat is None or lon is None or not germany.contains(float(lon), float(lat))[0]:
            return spec
    b_lat = attrs.get("_de_lat", lat)
    b_lon = attrs.get("_de_lon", lon)
    spec.de_in = True

    zone = region_zone(b_lat, b_lon)
    seed = getattr(spec, "seed", 0.5)
    # Extract explicit OSM/Overture house number when present.
    hn_val = attrs.get("addr:housenumber") or attrs.get("housenumber")
    if not hn_val and attrs.get("tags"):
        try:
            import json
            t_dict = attrs["tags"] if isinstance(attrs["tags"], dict) else json.loads(str(attrs["tags"]))
            if isinstance(t_dict, dict):
                hn_val = t_dict.get("addr:housenumber") or t_dict.get("housenumber")
        except Exception:
            hn_val = None
    if hn_val:
        s_hn = str(hn_val).strip()
        if s_hn and s_hn.lower() not in ("none", "null", "nan"):
            spec.de_hn = s_hn[:10]

    fm = str(attrs.get("facade_material") or "").strip().lower()
    fc_raw = attrs.get("facade_color")
    rmat = str(attrs.get("roof_material") or "").strip().lower()
    rc_raw = attrs.get("roof_color")
    floors = int(getattr(spec, "floors", 1) or 1)
    area = abs(bld._area2(np.asarray(spec.ring, np.float64)[:, :2])) / 2.0
    alpine = bool(attrs.get("_de_alpine", False))

    # --- 1. Facade material & palette ---
    cur_mat, cur_rgb = bld.LOOKS.get(spec.facade, (bld.FACADE, (0.85, 0.84, 0.80)))
    has_fc = bool(fc_raw and bld.parse_color(fc_raw) is not None)

    if has_fc:
        graded = grade_wall_rgb(cur_rgb, is_brick=(fm == "brick" or spec.band == bld.BAND_BRICK or cur_mat == bld.BRICK_WALL))
        spec.facade = bld.custom_look(cur_mat, graded)
        if spec.wall is not None:
            spec.wall = spec.facade
    elif cls in bld.BARN_CLASSES or (cls in bld.SHED_CLASSES and area < 150.0):
        # Muted barns & sheds (avoid glaring primary colors)
        if cls in bld.BARN_CLASSES:
            rgb = _pick(((0.48, 0.32, 0.25), (0.44, 0.36, 0.28), (0.58, 0.54, 0.48)), seed, "de_barn")
        else:
            rgb = _pick(((0.66, 0.64, 0.60), (0.54, 0.48, 0.42), (0.74, 0.72, 0.68)), seed, "de_shed")
        spec.facade = bld.custom_look(cur_mat if cur_mat in (bld.SIDING, bld.STONE, bld.METALWALL) else bld.SIDING, rgb)
    elif cur_mat == bld.OFFICE or spec.band in (bld.BAND_OFFICE, bld.BAND_OFFICE2):
        spec.facade = bld.custom_look(bld.OFFICE, _pick(DE_OFFICE_GLASS_TINTS, seed, "de_office"))
    elif cur_mat == bld.PANEL:
        spec.facade = bld.custom_look(bld.PANEL, _pick(DE_INDUSTRIAL_PANEL_TINTS, seed, "de_panel"))
    elif cur_mat == bld.METALWALL:
        spec.facade = bld.custom_look(bld.METALWALL, _pick(DE_INDUSTRIAL_METAL_TINTS, seed, "de_metal"))
    elif fm in bld.STONE_FACADES or cur_mat in (bld.STONE, bld.STONE_RUBBLE):
        rgb = _pick(((0.80, 0.75, 0.66), (0.74, 0.71, 0.65), (0.70, 0.69, 0.67)), seed, "de_stone")
        spec.facade = bld.custom_look(cur_mat, rgb)
        if spec.wall is not None:
            spec.wall = spec.facade
    elif fm in ("wood", "timber", "log", "wood_boards", "timber_framing"):
        spec.facade = bld.custom_look(bld.SIDING, _pick(((0.46, 0.34, 0.25), (0.38, 0.29, 0.22), (0.54, 0.49, 0.43)), seed, "de_wood"))
        if spec.wall is not None:
            spec.wall = spec.facade
    elif fm in ("concrete", "cement", "precast", "cement_block", "cinder_block", "concrete_block", "block"):
        spec.facade = bld.custom_look(cur_mat, _pick(DE_INDUSTRIAL_PANEL_TINTS, seed, "de_conc"))
        if spec.wall is not None:
            spec.wall = spec.facade
    elif fm == "brick":
        spec.band = bld.BAND_BRICK
        spec.wall = None
        spec.facade = bld.custom_look(bld.FACADE, _pick(DE_BRICK_TINTS, seed, "de_brick"))
    else:
        # Unmapped residential / commercial / urban building:
        # Eliminate Alpine wood siding outside genuine mountain terrain, and replace PAINT_TINTS pastels.
        is_alpine_chalet = (
            cur_mat == bld.SIDING
            and (alpine or (b_lat is not None and float(b_lat) < 47.65))
            and cls in bld.HOUSE_CLASSES
        )
        if is_alpine_chalet:
            spec.facade = bld.custom_look(bld.SIDING, _pick(((0.48, 0.35, 0.26), (0.58, 0.51, 0.43)), seed, "de_chalet"))
            spec.wall = spec.facade
        else:
            # Convert non-Alpine siding houses into crisp German plaster/brick FACADE.
            if cur_mat == bld.SIDING and spec.wall is not None:
                spec.wall = None
                spec.plain = False
                spec.windows = True
                spec.band = bld.BAND_SASH if _h01(seed, "de_win") < 0.7 else bld.BAND_TALL
            row_like = cls == "terrace" or int(attrs.get("_de_neighbours") or 0) >= 1
            ep = bld.era(attrs.get("_year"))
            base_brick = 0.56 if zone == "north_nw" else (0.30 if zone == "central_east" else 0.12)
            if row_like:
                base_brick *= 1.18
            elif cls in bld.HOUSE_CLASSES and not row_like:
                base_brick *= 0.80
            if ep == "old":
                base_brick *= 1.30
            elif ep in ("postwar", "new"):
                base_brick *= 0.65
            if spec.shop and floors <= 2 and cls in ("supermarket", "retail", "commercial"):
                base_brick *= 0.45
            brick_p = min(0.78, base_brick)
            use_brick = _h01(seed, "de_brick_pick") < brick_p and not (ep == "postwar" and floors >= 4)
            if use_brick and spec.band != bld.BAND_OFFICE:
                spec.band = bld.BAND_BRICK
                spec.wall = None
                spec.facade = bld.custom_look(bld.FACADE, _pick(DE_BRICK_TINTS, seed, "de_brick_c"))
            else:
                if spec.band == bld.BAND_BRICK:
                    spec.band = bld.BAND_SASH if floors <= 4 else bld.BAND_TALL
                if getattr(spec, "shop", False) or cls in ("retail", "commercial", "supermarket"):
                    pal = DE_COMMERCIAL_TINTS
                elif zone == "south":
                    pal = DE_PLASTER_SOUTH
                elif zone == "north_nw":
                    pal = DE_PLASTER_NORTH
                else:
                    pal = DE_PLASTER_EAST
                target_mat = bld.STUCCO if spec.wall is not None and cur_mat == bld.STUCCO else bld.FACADE
                spec.facade = bld.custom_look(target_mat, _pick(pal, seed, "de_plaster"))
                if spec.wall is not None:
                    spec.wall = spec.facade

    # --- 2. Roof material & color grading ---
    rm_cur, rr_cur = bld.LOOKS.get(spec.roof_mat, (bld.ROOF_FLAT, (0.65, 0.65, 0.65)))
    has_rc = bool(rc_raw and bld.parse_color(rc_raw) is not None)
    if spec.roof == "flat":
        if has_rc or attrs.get("_roof_photo") is not None:
            spec.roof_mat = bld.custom_look(rm_cur, grade_roof_rgb(rr_cur, rm_cur))
        elif rm_cur == bld.ROOF_FLAT and not rmat:
            spec.roof_mat = bld.custom_look(bld.ROOF_FLAT, _pick(DE_ROOF_FLAT_TINTS, seed, "de_rflat"))
    elif spec.roof not in bld.DOME_ROOFS:
        if has_rc or attrs.get("_roof_photo") is not None:
            spec.roof_mat = bld.custom_look(rm_cur, grade_roof_rgb(rr_cur, rm_cur))
        elif not rmat and cls not in bld.BARN_CLASSES and cls not in bld.SHED_CLASSES:
            tile_share = 0.78 if zone == "south" else (0.58 if zone == "north_nw" else 0.68)
            if _h01(seed, "de_rtile") < tile_share:
                spec.roof_mat = bld.custom_look(bld.ROOF_TILES, _pick(DE_ROOF_TILE_TINTS, seed, "de_rtile_c"))
            else:
                slate_mat = bld.ROOF_SLATE_DARK if _h01(seed, "de_rslate") < 0.72 else bld.ROOF_SLATE_ROUND
                spec.roof_mat = bld.custom_look(
                    slate_mat,
                    _pick(DE_ROOF_SLATE_DARK_TINTS if slate_mat == bld.ROOF_SLATE_DARK else ((0.86, 0.86, 0.88), (0.70, 0.70, 0.73)),
                          seed, "de_rslate_c"),
                )

    return spec


# ---------------------------------------------------------------------------
# Neighbor-safe roof overhangs & polygon offsetting
# ---------------------------------------------------------------------------

def _seg_seg_dist2(a: np.ndarray, b: np.ndarray, c: np.ndarray, d: np.ndarray) -> float:
    """Squared minimum distance between 2D segments AB and CD."""
    u = b - a
    v = d - c
    w = a - c
    a_ = float(np.dot(u, u))
    b_ = float(np.dot(u, v))
    c_ = float(np.dot(v, v))
    d_ = float(np.dot(u, w))
    e_ = float(np.dot(v, w))
    denom = a_ * c_ - b_ * b_
    sN, sD = 0.0, denom
    tN, tD = 0.0, denom
    if denom < 1e-12:
        sN, sD = 0.0, 1.0
        tN, tD = e_, c_
    else:
        sN = b_ * e_ - c_ * d_
        tN = a_ * e_ - b_ * d_
        if sN < 0.0:
            sN = 0.0
            tN = e_
            tD = c_
        elif sN > sD:
            sN = sD
            tN = e_ + b_
            tD = c_
    if tN < 0.0:
        tN = 0.0
        if -d_ < 0.0:
            sN = 0.0
        elif -d_ > a_:
            sN = sD
        else:
            sN = -d_
            sD = a_
    elif tN > tD:
        tN = tD
        if (-d_ + b_) < 0.0:
            sN = 0.0
        elif (-d_ + b_) > a_:
            sN = sD
        else:
            sN = -d_ + b_
            sD = a_
    sc = 0.0 if abs(sN) < 1e-12 else sN / sD
    tc = 0.0 if abs(tN) < 1e-12 else tN / tD
    dp = w + sc * u - tc * v
    return float(np.dot(dp, dp))


def default_overhang_m(spec) -> float:
    cls = (getattr(spec, "cls", None) or "").lower()
    if cls in {"shed", "garage", "garages", "carport"}:
        return 0.22
    if (getattr(spec, "pitch", None) or 32.0) <= 28.0:
        return OVERHANG_ALPINE_SOUTH_M
    return OVERHANG_STANDARD_M


def compute_roof_overhangs(items: list) -> None:
    """Compute safe per-edge roof overhangs (`spec.de_eaves`) checking neighbor building clearance."""
    import buildings as bld

    pitched_shapes = {"gabled", "hipped", "half-hipped", "pyramidal", "skillion", "gambrel", "mansard"}
    if not items:
        return

    entries: list[tuple[object, np.ndarray, tuple[float, float, float, float], float, float]] = []
    for spec, gmin, gmax in items:
        ring = np.asarray(bld.drawn_ring(spec), dtype=np.float64)[:, :2]
        if len(ring) < 3 or not np.isfinite(ring).all():
            continue
        if bld._area2(ring) < 0:
            ring = ring[::-1]
        z_bot = bld.base_z(spec, gmin, gmax) + float(spec.min_h or 0.0)
        z_top = z_bot + float(spec.height or 0.0) + 4.0
        bb = (float(ring[:, 0].min()), float(ring[:, 1].min()), float(ring[:, 0].max()), float(ring[:, 1].max()))
        entries.append((spec, ring, bb, z_bot, z_top))

    if not entries:
        return

    # Uniform grid index (16 m cells) for fast neighbor lookup.
    cell_m = 16.0
    grid: dict[tuple[int, int], list[int]] = {}
    for idx, (_sp, _rg, (x0, y0, x1, y1), _zb, _zt) in enumerate(entries):
        gx0, gy0 = int(math.floor((x0 - 1.0) / cell_m)), int(math.floor((y0 - 1.0) / cell_m))
        gx1, gy1 = int(math.floor((x1 + 1.0) / cell_m)), int(math.floor((y1 + 1.0) / cell_m))
        for gx in range(gx0, gx1 + 1):
            for gy in range(gy0, gy1 + 1):
                grid.setdefault((gx, gy), []).append(idx)

    for idx, (spec, ring, (x0, y0, x1, y1), z_bot, z_top) in enumerate(entries):
        if not is_de_spec(spec) or spec.roof not in pitched_shapes:
            continue
        oh_max = default_overhang_m(spec)
        gx0, gy0 = int(math.floor((x0 - 1.0) / cell_m)), int(math.floor((y0 - 1.0) / cell_m))
        gx1, gy1 = int(math.floor((x1 + 1.0) / cell_m)), int(math.floor((y1 + 1.0) / cell_m))
        cand_ids: set[int] = set()
        for gx in range(gx0, gx1 + 1):
            for gy in range(gy0, gy1 + 1):
                for j in grid.get((gx, gy), ()):
                    if j != idx:
                        cand_ids.add(j)

        n = len(ring)
        pad = 1.0
        neighbors = [
            entries[j][1]
            for j in cand_ids
            if not (
                entries[j][2][2] < x0 - pad
                or entries[j][2][0] > x1 + pad
                or entries[j][2][3] < y0 - pad
                or entries[j][2][1] > y1 + pad
                or entries[j][4] < z_bot
                or entries[j][3] > z_top
            )
        ]

        if not neighbors:
            spec.de_eaves = tuple([oh_max] * n)
            continue

        ohs: list[float] = []
        for k in range(n):
            a, b = ring[k], ring[(k + 1) % n]
            d = b - a
            L = float(math.hypot(d[0], d[1]))
            if L < 1e-4:
                ohs.append(0.0)
                continue
            d_u = d / L
            out = np.array([d_u[1], -d_u[0]], dtype=np.float64)
            ex0, ey0 = min(a[0], b[0]) - pad, min(a[1], b[1]) - pad
            ex1, ey1 = max(a[0], b[0]) + pad, max(a[1], b[1]) + pad
            blocked_inside = False
            # Probe slightly outside the edge for direct containment inside adjacent footprint
            for t_probe in (0.2, 0.5, 0.8):
                pt = a + d * t_probe + out * 0.22
                for nb in neighbors:
                    if nb[:, 0].min() <= pt[0] <= nb[:, 0].max() and nb[:, 1].min() <= pt[1] <= nb[:, 1].max():
                        if bld._inside(nb, pt):
                            blocked_inside = True
                            break
                if blocked_inside:
                    break
            if blocked_inside:
                ohs.append(0.0)
                continue

            s_lo = min(0.08, 0.1 * L)
            s_hi = L - s_lo
            min_out = 99.0
            for nb in neighbors:
                if nb[:, 0].max() < ex0 or nb[:, 0].min() > ex1 or nb[:, 1].max() < ey0 or nb[:, 1].min() > ey1:
                    continue
                m = len(nb)
                rel = nb - a
                ss = rel @ d_u
                ts = rel @ out
                for p_i in range(m):
                    q_i = (p_i + 1) % m
                    s0_n, t0_n = float(ss[p_i]), float(ts[p_i])
                    s1_n, t1_n = float(ss[q_i]), float(ts[q_i])
                    if max(s0_n, s1_n) < s_lo or min(s0_n, s1_n) > s_hi:
                        continue
                    ds = s1_n - s0_n
                    u0, u1 = 0.0, 1.0
                    if abs(ds) > 1e-9:
                        ua, ub = (s_lo - s0_n) / ds, (s_hi - s0_n) / ds
                        if ua > ub:
                            ua, ub = ub, ua
                        u0, u1 = max(u0, ua), min(u1, ub)
                        if u0 > u1:
                            continue
                    ta = t0_n + u0 * (t1_n - t0_n)
                    tb = t0_n + u1 * (t1_n - t0_n)
                    if max(ta, tb) < -0.05:
                        continue
                    t_min = 0.0 if min(ta, tb) <= 0.0 else min(ta, tb)
                    if t_min < min_out:
                        min_out = t_min
            dist = min_out
            if dist < NEIGHBOR_FLUSH_M:
                ohs.append(0.0)
            elif dist < NEIGHBOR_CLEAR_M:
                frac = (dist - NEIGHBOR_FLUSH_M) / max(NEIGHBOR_CLEAR_M - NEIGHBOR_FLUSH_M, 1e-6)
                ohs.append(round(oh_max * frac * 0.85, 3))
            else:
                ohs.append(oh_max)
        spec.de_eaves = tuple(ohs)


def _segments_cross(a: np.ndarray, b: np.ndarray, c: np.ndarray, d: np.ndarray) -> bool:
    def ccw(p1, p2, p3):
        return (p3[1] - p1[1]) * (p2[0] - p1[0]) > (p2[1] - p1[1]) * (p3[0] - p1[0])
    return (ccw(a, c, d) != ccw(b, c, d)) and (ccw(a, b, c) != ccw(a, b, d))


def offset_ring_safe(ring: np.ndarray, edge_oh: tuple[float, ...] | list[float]) -> np.ndarray | None:
    """Outward-offset counter-clockwise ring per edge; returns None if degenerate/self-intersecting."""
    import buildings as bld

    r = np.asarray(ring, dtype=np.float64)[:, :2]
    n = len(r)
    if n < 3 or len(edge_oh) != n or max(edge_oh) <= 1e-4:
        return None
    if bld._area2(r) < 0:
        r = r[::-1]
        edge_oh = list(edge_oh)[::-1]

    dirs = []
    norms = []
    for i in range(n):
        e = r[(i + 1) % n] - r[i]
        L = float(math.hypot(e[0], e[1]))
        if L < 1e-5:
            return None
        d = e / L
        dirs.append(d)
        norms.append(np.array([d[1], -d[0]], dtype=np.float64))

    pts = []
    for i in range(n):
        ip = (i - 1) % n
        oh_p, oh_c = float(edge_oh[ip]), float(edge_oh[i])
        if oh_p <= 1e-5 and oh_c <= 1e-5:
            pts.append(r[i].copy())
            continue
        dp, dc = dirs[ip], dirs[i]
        np_, nc = norms[ip], norms[i]
        p1 = r[i] + np_ * oh_p
        p2 = r[i] + nc * oh_c
        det = float(dp[0] * dc[1] - dp[1] * dc[0])
        if abs(det) > 0.15:
            diff = p2 - p1
            t = float((diff[0] * dc[1] - diff[1] * dc[0]) / det)
            q = p1 + dp * t
            max_miter = 2.2 * max(oh_p, oh_c)
            delta = q - r[i]
            dlen = float(math.hypot(delta[0], delta[1]))
            if dlen > max_miter and dlen > 1e-6:
                q = r[i] + delta * (max_miter / dlen)
            pts.append(q)
        else:
            pts.append(r[i] + 0.5 * (np_ * oh_p + nc * oh_c))

    out = np.asarray(pts, dtype=np.float64)
    if not np.isfinite(out).all() or bld._area2(out) < bld._area2(r) * 0.99:
        return None
    # Self-intersection check on non-adjacent edges
    for i in range(n):
        a, b = out[i], out[(i + 1) % n]
        for j in range(i + 2, n):
            if i == 0 and j == n - 1:
                continue
            if _segments_cross(a, b, out[j], out[(j + 1) % n]):
                return None
    return out


# ---------------------------------------------------------------------------
# Option B: Near-only horizontal quad split + linear-space vertex depth AO
# ---------------------------------------------------------------------------

def _ground_at_xy(spec, gmin: float, gmax: float, xy: np.ndarray) -> np.ndarray:
    """Interpolate local ground elevation at `(V, 2)` points from `spec.gring` edges, clamped to [gmin, gmax]."""
    gr = getattr(spec, "gring", None)
    ring = np.asarray(spec.ring, dtype=np.float64)[:, :2]
    if gr is None or len(gr) != len(ring) or abs(gmax - gmin) < 0.04 or len(ring) < 3:
        return np.full(len(xy), float(gmax), dtype=np.float64)
    gr = np.asarray(gr, dtype=np.float64)
    a = ring
    b = np.roll(ring, -1, axis=0)
    d = b - a
    l2 = np.maximum((d * d).sum(axis=1), 1e-9)
    # Closest point projection onto each footprint edge (V, E)
    diff = xy[:, None, :] - a[None, :, :]
    t = np.clip((diff * d[None, :, :]).sum(axis=2) / l2[None, :], 0.0, 1.0)
    proj = a[None, :, :] + t[:, :, None] * d[None, :, :]
    dist2 = ((xy[:, None, :] - proj) ** 2).sum(axis=2)
    ei = np.argmin(dist2, axis=1)
    ti = t[np.arange(len(xy)), ei]
    g_nxt = np.roll(gr, -1)
    gz = gr[ei] + ti * (g_nxt[ei] - gr[ei])
    return np.clip(gz, float(gmin), float(gmax))


def bake_building_depth(
    mesh,
    spec,
    gmin: float,
    gmax: float,
    z_eave: float,
    lite: bool,
    mat_idx,
) -> None:
    """Split vertical wall quads (Option B on near tiles) and bake Sockel + under-eave AO in linear light."""
    import buildings as bld

    P, UV, T, M, C = mesh.raw_arrays()
    if not len(T):
        return

    wall_exclude_mats = {
        bld.MATERIALS.index(m)
        for m in (
            bld.ROOF_FLAT, bld.ROOF_SLATE, bld.ROOF_SHINGLE, bld.ROOF_METAL,
            bld.ROOF_TILES, bld.ROOF_SLATE_ROUND, bld.ROOF_SLATE_DARK, bld.ROOF_WOOD,
            bld.MARBLE, bld.SKY_WALL, bld.SKY_WALL_DAY,
            bld.LANDMARK_IRON, bld.LANDMARK_STONE, bld.LANDMARK_LAMP,
            bld.LANDMARK_FLOODLIT, bld.LANDMARK_DIAL,
        )
    }
    white_facade_mi = mat_idx["bne_bld_fac_white"][0]
    shop_mi = mat_idx[bld.SHOP][0]
    lobby_mi = mat_idx[bld.LOBBY][0]
    min_h = float(getattr(spec, "min_h", 0.0) or 0.0)
    has_ground_sockel = min_h <= 0.5

    # Step 1 (Option B, near-only): horizontally split vertical unshared 4-vertex wall quads
    # crossing `z_sockel = g_local + 0.75` or `z_ao = z_eave - 0.35`.
    # In `Mesh.quads`, every block from `building_walls_np` is pairs of triangles `[0,1,2],[0,2,3]`
    # on 4 consecutive unshared vertices.
    if not lite and len(T) >= 2 and len(P) >= 4:
        # Identify 4-vertex quad pairs: adjacent tris (2k, 2k+1) sharing v0 and v2, sequential v0..v3
        n_tri = len(T)
        # Fast vectorized check for consecutive quad-pairs starting at even indices where T = [v, v+1, v+2], [v, v+2, v+3]
        pair_n = n_tri // 2
        if pair_n > 0:
            t_even = T[0:2 * pair_n:2]
            t_odd = T[1:2 * pair_n:2]
            v0 = t_even[:, 0]
            m_even = M[0:2 * pair_n:2]
            is_wall_mat = ~np.isin(m_even, list(wall_exclude_mats))
            if spec.wall:
                is_wall_mat &= (m_even != white_facade_mi)
            is_seq_quad = (
                is_wall_mat
                & (v0 >= 0)
                & (v0 + 3 < len(P))
                & (t_even[:, 1] == v0 + 1)
                & (t_even[:, 2] == v0 + 2)
                & (t_odd[:, 0] == v0)
                & (t_odd[:, 1] == v0 + 2)
                & (t_odd[:, 2] == v0 + 3)
                & (m_even == M[1:2 * pair_n:2])
            )
            cand = np.flatnonzero(is_seq_quad)
            q_idx = np.empty(0, dtype=np.int64)
            if len(cand):
                vc = v0[cand]
                z0 = P[vc, 2]
                z1 = P[vc + 1, 2]
                z2 = P[vc + 2, 2]
                z3 = P[vc + 3, 2]
                is_vert = (
                    (np.abs(z0 - z1) < 1e-4)
                    & (np.abs(z2 - z3) < 1e-4)
                    & (z2 - z0 > 0.5)
                    & (np.abs(P[vc, 0] - P[vc + 3, 0]) < 1e-4)
                    & (np.abs(P[vc, 1] - P[vc + 3, 1]) < 1e-4)
                    & (np.abs(P[vc + 1, 0] - P[vc + 2, 0]) < 1e-4)
                    & (np.abs(P[vc + 1, 1] - P[vc + 2, 1]) < 1e-4)
                )
                q_idx = cand[is_vert]
            if len(q_idx):
                p_mid = 0.5 * (P[v0[q_idx], :2] + P[v0[q_idx] + 1, :2])
                g_local = _ground_at_xy(spec, gmin, gmax, p_mid)
                z_sockel_cuts = g_local + SOCKEL_HEIGHT_M
                z_eave_cut = float(z_eave) - EAVE_AO_HEIGHT_M

                extra_P, extra_UV, extra_C, extra_T, extra_M = [], [], [], [], []
                drop_pair = np.zeros(pair_n, dtype=bool)
                v_cursor = len(P)

                for j, qi in enumerate(q_idx.tolist()):
                    vb = int(v0[qi])
                    zb, zt = float(P[vb, 2]), float(P[vb + 2, 2])
                    cuts: list[float] = []
                    if has_ground_sockel:
                        zs = float(z_sockel_cuts[j])
                        if zb + 0.08 < zs < zt - 0.08:
                            cuts.append(zs)
                    if zb + 0.08 < z_eave_cut < zt - 0.08:
                        if not cuts or abs(z_eave_cut - cuts[-1]) > 0.08:
                            cuts.append(z_eave_cut)
                    if not cuts:
                        continue
                    cuts.sort()
                    drop_pair[qi] = True
                    z_levels = [zb] + cuts + [zt]
                    p_a, p_b = P[vb, :2], P[vb + 1, :2]
                    uv_a0, uv_b0 = UV[vb], UV[vb + 1]
                    uv_b1, uv_a1 = UV[vb + 2], UV[vb + 3]
                    c_row = C[vb]
                    mat_q = int(M[2 * qi])
                    span_z = zt - zb
                    for za_, zb_ in zip(z_levels[:-1], z_levels[1:]):
                        ta = (za_ - zb) / span_z
                        tb = (zb_ - zb) / span_z
                        extra_P.extend([
                            [p_a[0], p_a[1], za_],
                            [p_b[0], p_b[1], za_],
                            [p_b[0], p_b[1], zb_],
                            [p_a[0], p_a[1], zb_],
                        ])
                        extra_UV.extend([
                            uv_a0 + ta * (uv_a1 - uv_a0),
                            uv_b0 + ta * (uv_b1 - uv_b0),
                            uv_b0 + tb * (uv_b1 - uv_b0),
                            uv_a0 + tb * (uv_a1 - uv_a0),
                        ])
                        extra_C.extend([c_row, c_row, c_row, c_row])
                        extra_T.extend([
                            [v_cursor, v_cursor + 1, v_cursor + 2],
                            [v_cursor, v_cursor + 2, v_cursor + 3],
                        ])
                        extra_M.extend([mat_q, mat_q])
                        v_cursor += 4

                if extra_T:
                    keep_tri = np.ones(n_tri, dtype=bool)
                    dp_idx = np.flatnonzero(drop_pair)
                    keep_tri[2 * dp_idx] = False
                    keep_tri[2 * dp_idx + 1] = False
                    T = np.concatenate([T[keep_tri], np.asarray(extra_T, dtype=np.int64)])
                    M = np.concatenate([M[keep_tri], np.asarray(extra_M, dtype=np.int64)])
                    P = np.concatenate([P, np.asarray(extra_P, dtype=np.float64)])
                    UV = np.concatenate([UV, np.asarray(extra_UV, dtype=np.float64)])
                    C = np.concatenate([C, np.asarray(extra_C, dtype=np.uint8)])

    # Step 2: Identify wall & gable vertices via triangle normals and materials.
    v0 = P[T[:, 0]]
    n_vec = np.cross(P[T[:, 1]] - v0, P[T[:, 2]] - v0)
    n_len = np.linalg.norm(n_vec, axis=1)
    nz = np.abs(n_vec[:, 2]) / np.maximum(n_len, 1e-12)
    is_wall_tri = (nz < 0.35) & (~np.isin(M, list(wall_exclude_mats)))
    if not is_wall_tri.any():
        mesh.set_raw_arrays(P, UV, T, M, C)
        return

    wall_verts = np.unique(T[is_wall_tri].ravel())
    if spec.wall:
        # Never darken laid-over white window frames in Sockel pass
        win_tris = is_wall_tri & (M == white_facade_mi)
        win_verts = set(np.unique(T[win_tris].ravel()).tolist()) if win_tris.any() else set()
    else:
        win_verts = set()

    # Check which vertices belong to shopfront/lobby materials (gentler base darkening)
    shop_tris = is_wall_tri & np.isin(M, [shop_mi, lobby_mi])
    shop_verts = np.zeros(len(P), dtype=bool)
    if shop_tris.any():
        shop_verts[np.unique(T[shop_tris].ravel())] = True

    # Identify vertices sitting at the bottom vs top of each wall triangle (so shared cut boundary
    # at z_g + 0.75 m can keep a crisp plinth-top edge on the lower band without darkening the upper band).
    tri_z_min = P[T, 2].min(axis=1)
    tri_z_max = P[T, 2].max(axis=1)
    is_sockel_band_tri = np.zeros(len(T), dtype=bool)
    if has_ground_sockel:
        tri_mid_xy = P[T, :2].mean(axis=1)
        tri_g = _ground_at_xy(spec, gmin, gmax, tri_mid_xy)
        is_sockel_band_tri = is_wall_tri & (tri_z_max <= tri_g + SOCKEL_HEIGHT_M + 0.08)
    sockel_band_verts = np.zeros(len(P), dtype=bool)
    if is_sockel_band_tri.any():
        sockel_band_verts[np.unique(T[is_sockel_band_tri].ravel())] = True

    # Convert wall vertex colors to linear light
    lin = np.power(C[wall_verts, :3].astype(np.float64) / 255.0, 2.2)
    pts_w = P[wall_verts]
    zw = pts_w[:, 2]
    gz = _ground_at_xy(spec, gmin, gmax, pts_w[:, :2])

    scale = np.ones((len(wall_verts), 3), dtype=np.float64)
    stone_blend = np.zeros(len(wall_verts), dtype=np.float64)

    # A) Ground Plinth / Sockel (0.0 m .. 0.75 m)
    if has_ground_sockel:
        h_above = zw - gz
        is_shop_v = shop_verts[wall_verts]
        is_sock_v = sockel_band_verts[wall_verts]

        # Foundation / below-ground skirt + lower Sockel (<= 0.75 m)
        low_mask = (h_above <= SOCKEL_HEIGHT_M + 0.03) & (is_sock_v | (h_above < SOCKEL_HEIGHT_M - 0.05))
        if low_mask.any():
            t = np.clip(h_above[low_mask] / SOCKEL_HEIGHT_M, 0.0, 1.0)
            # Linear-light darkening: 0.54 at 0.0 m -> 0.67 at 0.75 m (gentler on shopfronts)
            k_res = 0.54 + 0.13 * t
            k_shop = 0.80 + 0.14 * t
            k = np.where(is_shop_v[low_mask], k_shop, k_res)
            scale[low_mask] *= k[:, None]
            # Slight mineral grey-stone desaturation on residential/masonry Sockel
            stone_blend[low_mask] = np.where(is_shop_v[low_mask], 0.05, 0.35 * (1.0 - 0.3 * t))

        # Subtle splash/dirt transition right above Sockel cap (0.75 m .. 1.35 m) on upper wall band
        splash_mask = (~low_mask) & (h_above >= SOCKEL_HEIGHT_M - 0.03) & (h_above <= SOCKEL_HEIGHT_M + 0.65)
        if splash_mask.any():
            u = np.clip((h_above[splash_mask] - SOCKEL_HEIGHT_M) / 0.65, 0.0, 1.0)
            k = np.where(is_shop_v[splash_mask], 0.95 + 0.05 * u, 0.90 + 0.10 * u)
            scale[splash_mask] *= k[:, None]

    # Identify wall quads that sit directly underneath a gable triangle above z_eave so we don't
    # paint a dark horizontal eave-AO stripe across the middle of a continuous gable-end masonry wall.
    gable_tris = is_wall_tri & (tri_z_max > float(z_eave) + 0.15)
    gable_xy_segs: list[tuple[np.ndarray, np.ndarray]] = []
    if gable_tris.any():
        for tri in T[gable_tris]:
            pts_t = P[tri]
            base_pts = pts_t[np.abs(pts_t[:, 2] - float(z_eave)) < 0.15]
            if len(base_pts) >= 2:
                gable_xy_segs.append((base_pts[0, :2], base_pts[1, :2]))

    def _on_gable_base(xy_pt: np.ndarray) -> bool:
        for ga, gb in gable_xy_segs:
            ab = gb - ga
            l2 = float(np.dot(ab, ab))
            if l2 < 1e-4:
                continue
            t = float(np.dot(xy_pt - ga, ab) / l2)
            if -0.05 <= t <= 1.05:
                proj = ga + np.clip(t, 0.0, 1.0) * ab
                if float(np.hypot(xy_pt[0] - proj[0], xy_pt[1] - proj[1])) < 0.25:
                    return True
        return False

    # B) Under-Eave Ambient Occlusion (top 0.35 m below z_eave) & gable rake darkening
    eave_lo = float(z_eave) - EAVE_AO_HEIGHT_M
    ao_min = 0.72 if spec.roof != "flat" else 0.78
    eave_mask = (zw >= eave_lo) & (zw <= float(z_eave) + 0.03)
    if eave_mask.any() and gable_xy_segs:
        for idx_local in np.flatnonzero(eave_mask):
            if _on_gable_base(pts_w[idx_local, :2]):
                eave_mask[idx_local] = False
    if eave_mask.any():
        v_t = np.clip((zw[eave_mask] - eave_lo) / EAVE_AO_HEIGHT_M, 0.0, 1.0)
        k_eave = 1.0 - (1.0 - ao_min) * v_t
        scale[eave_mask] *= k_eave[:, None]

    # Gable triangles above z_eave: keep base continuous (~0.98) and shade apex/rake subtly under bargeboard (~0.78)
    gable_mask = zw > float(z_eave) + 0.03
    if gable_mask.any():
        z_max_g = max(float(zw[gable_mask].max()), float(z_eave) + 1.0)
        gt = np.clip((zw[gable_mask] - float(z_eave)) / (z_max_g - float(z_eave)), 0.0, 1.0)
        k_gab = 0.98 - 0.20 * gt
        scale[gable_mask] *= k_gab[:, None]

    if win_verts:
        skip_mask = np.array([int(vi) in win_verts for vi in wall_verts], dtype=bool)
        scale[skip_mask] = 1.0
        stone_blend[skip_mask] = 0.0

    # Apply mineral stone tint blend + brightness modulation in linear light
    if (stone_blend > 0).any():
        lum = 0.2126 * lin[:, 0] + 0.7152 * lin[:, 1] + 0.0722 * lin[:, 2]
        stone_col = np.column_stack([lum * 0.96, lum * 0.94, lum * 0.90])
        lin = lin * (1.0 - stone_blend[:, None]) + stone_col * stone_blend[:, None]
    lin = np.clip(lin * scale, 0.0, 1.0)

    C = C.copy()
    C[wall_verts, :3] = np.clip(np.round(np.power(lin, 1.0 / 2.2) * 255.0), 0, 255).astype(np.uint8)
    mesh.set_raw_arrays(P, UV, T, M, C)
    if not lite:
        _add_entrance_canopy_and_balconies(mesh, spec, gmin, gmax, z_eave, mat_idx)


_BALCONY_SKIP_CLS = frozenset({
    "industrial", "warehouse", "garage", "garages", "shed", "barn", "farm_auxiliary",
    "stable", "cowshed", "church", "chapel", "cathedral", "commercial", "retail",
    "supermarket", "kiosk", "greenhouse", "hangar",
})


def _add_box_prism(mesh, center: np.ndarray, axis_x: np.ndarray, axis_y: np.ndarray, axis_z: np.ndarray,
                   hx: float, hy: float, hz: float, mat_token) -> None:
    """Append a watertight closed 6-face prism to `buildings.Mesh` (`CCW` outward normals)."""
    ex = axis_x * hx
    ey = axis_y * hy
    ez = axis_z * hz
    uv = ((0.05, 0.05), (0.95, 0.05), (0.95, 0.95), (0.05, 0.95))

    # Front (+Y), Back (-Y), Right (+X), Left (-X), Top (+Z), Bottom (-Z)
    fc = center + ey
    mesh.quad(fc - ex - ez, fc + ex - ez, fc + ex + ez, fc - ex + ez, *uv, mat_token)
    bc = center - ey
    mesh.quad(bc + ex - ez, bc - ex - ez, bc - ex + ez, bc + ex + ez, *uv, mat_token)
    rc = center + ex
    mesh.quad(rc + ey - ez, rc - ey - ez, rc - ey + ez, rc + ey + ez, *uv, mat_token)
    lc = center - ex
    mesh.quad(lc - ey - ez, lc + ey - ez, lc + ey + ez, lc - ey + ez, *uv, mat_token)
    tc = center + ez
    mesh.quad(tc - ex + ey, tc + ex + ey, tc + ex - ey, tc - ex - ey, *uv, mat_token)
    dc = center - ez
    mesh.quad(dc - ex - ey, dc + ex - ey, dc + ex + ey, dc - ex + ey, *uv, mat_token)


def _add_entrance_canopy_and_balconies(mesh, spec, gmin: float, gmax: float, z_eave: float, mat_idx) -> None:
    """Append batched 3D glass/metal entrance canopies (`Vordächer`) and residential balconies (`Balkone`)."""
    import buildings as bld

    if getattr(spec, "portal", False) or getattr(spec, "deck", False) or getattr(spec, "ship", False):
        return
    if (getattr(spec, "min_h", 0.0) or 0.0) > 0.5:
        return
    if getattr(spec, "shop", False) or getattr(spec, "plain", False):
        return
    cls = (getattr(spec, "cls", None) or "").lower()
    if cls in _BALCONY_SKIP_CLS:
        return

    ring = bld.drawn_ring(spec)
    n_edges = len(ring)
    if n_edges < 3:
        return

    # Vertex budget guard against `buildings.VERTS_MAX` (65535).
    if mesh.n > 54000:
        return

    try:
        glass_tok = (bld.MATERIALS.index(bld.GLASSHOUSE), (184, 214, 232, 255))
        steel_tok = (bld.MATERIALS.index(bld.METALWALL), (54, 58, 64, 255))
        conc_tok = (bld.MATERIALS.index(bld.CONCRETE), (206, 208, 204, 255))
    except ValueError:
        return

    eaves = getattr(spec, "de_eaves", None)
    axis_z = np.array([0.0, 0.0, 1.0], dtype=np.float64)
    sign_out = 1.0 if bld._area2(ring) > 0 else -1.0

    # 1. Entrance Canopy (`Vordach`) above `spec.door`
    door = getattr(spec, "door", None)
    floors = int(getattr(spec, "floors", 1) or 1)
    if door is not None and not getattr(spec, "porch", False) and floors <= 5:
        edge_i, along_d = int(door[0]), float(door[1])
        if 0 <= edge_i < n_edges and (eaves is None or eaves[edge_i] > 0.12):
            a, b = ring[edge_i], ring[(edge_i + 1) % n_edges]
            L = float(math.hypot(*(b - a)))
            if L >= 3.2:
                d_u = (b - a) / L
                out = np.array([d_u[1], -d_u[0]], dtype=np.float64) * sign_out
                ax = np.array([d_u[0], d_u[1], 0.0], dtype=np.float64)
                ay = np.array([out[0], out[1], 0.0], dtype=np.float64)
                door_g = bld.door_ground(spec, edge_i, along_d, gmax)
                z_can = door_g + 2.46
                if z_can + 0.25 < z_eave:
                    c_xy = a + d_u * float(np.clip(along_d, 1.1, L - 1.1))
                    # Glass canopy pane (1.80 m wide x 0.90 m deep)
                    c_pane = np.array([c_xy[0] + ay[0] * 0.46, c_xy[1] + ay[1] * 0.46, z_can], dtype=np.float64)
                    _add_box_prism(mesh, c_pane, ax, ay, axis_z, 0.90, 0.45, 0.024, glass_tok)
                    # Two cantilevered dark anthracite support arms
                    for sx in (-0.72, 0.72):
                        c_arm = np.array([c_xy[0] + ax[0] * sx + ay[0] * 0.44, c_xy[1] + ax[1] * sx + ay[1] * 0.44, z_can - 0.04], dtype=np.float64)
                        _add_box_prism(mesh, c_arm, ax, ay, axis_z, 0.03, 0.43, 0.025, steel_tok)

    # 2. Residential Balconies (`Balkone`) on upper floors (2 <= floors <= 5)
    area = abs(bld._area2(ring)) / 2.0
    if not (2 <= floors <= 5) or area < 55.0 or mesh.n > 50000:
        return

    floor_h = float(getattr(spec, "floor_h", 2.8) or 2.8)
    base_z = bld.base_z(spec, gmin, gmax)
    cand_edges: list[tuple[float, int]] = []
    for ei in range(n_edges):
        if eaves is not None and eaves[ei] < 0.25:
            continue
        a, b = ring[ei], ring[(ei + 1) % n_edges]
        L = float(math.hypot(*(b - a)))
        if L >= 5.2:
            # Prefer front door edge or long primary facades
            score = L + (4.0 if (door is not None and ei == door[0]) else 0.0)
            cand_edges.append((score, ei))
    if not cand_edges:
        return

    cand_edges.sort(reverse=True)
    chosen = [ei for _sc, ei in cand_edges[:2]]
    bal_w = 2.8
    bal_d = 1.05

    for ei in chosen:
        a, b = ring[ei], ring[(ei + 1) % n_edges]
        L = float(math.hypot(*(b - a)))
        d_u = (b - a) / L
        out = np.array([d_u[1], -d_u[0]], dtype=np.float64) * sign_out
        ax = np.array([d_u[0], d_u[1], 0.0], dtype=np.float64)
        ay = np.array([out[0], out[1], 0.0], dtype=np.float64)
        c_mid = (a + b) * 0.5

        for fl in range(1, floors):
            if mesh.n + 240 > 58000:
                return
            slab_z = base_z + fl * floor_h - 0.08
            if slab_z + 1.15 >= z_eave - 0.10:
                continue
            # Concrete deck slab
            c_deck = np.array([c_mid[0] + ay[0] * (bal_d * 0.5), c_mid[1] + ay[1] * (bal_d * 0.5), slab_z], dtype=np.float64)
            _add_box_prism(mesh, c_deck, ax, ay, axis_z, bal_w * 0.5, bal_d * 0.5, 0.07, conc_tok)

            rail_z = slab_z + 0.55
            top_z = slab_z + 1.04
            # Frosted glass front balustrade + side rail bars
            c_front_g = np.array([c_mid[0] + ay[0] * (bal_d - 0.04), c_mid[1] + ay[1] * (bal_d - 0.04), rail_z], dtype=np.float64)
            _add_box_prism(mesh, c_front_g, ax, ay, axis_z, bal_w * 0.5 - 0.05, 0.015, 0.42, glass_tok)
            # Top anthracite handrail (front + 2 sides)
            c_top_f = np.array([c_mid[0] + ay[0] * (bal_d - 0.03), c_mid[1] + ay[1] * (bal_d - 0.03), top_z], dtype=np.float64)
            _add_box_prism(mesh, c_top_f, ax, ay, axis_z, bal_w * 0.5, 0.025, 0.025, steel_tok)
            for sx in (-1.0, 1.0):
                c_side_r = np.array([
                    c_mid[0] + ax[0] * (sx * (bal_w * 0.5 - 0.025)) + ay[0] * (bal_d * 0.5),
                    c_mid[1] + ax[1] * (sx * (bal_w * 0.5 - 0.025)) + ay[1] * (bal_d * 0.5),
                    top_z,
                ], dtype=np.float64)
                _add_box_prism(mesh, c_side_r, ax, ay, axis_z, 0.025, bal_d * 0.5, 0.025, steel_tok)
                c_post = np.array([
                    c_mid[0] + ax[0] * (sx * (bal_w * 0.5 - 0.03)) + ay[0] * (bal_d - 0.03),
                    c_mid[1] + ax[1] * (sx * (bal_w * 0.5 - 0.03)) + ay[1] * (bal_d - 0.03),
                    rail_z,
                ], dtype=np.float64)
                _add_box_prism(mesh, c_post, ax, ay, axis_z, 0.025, 0.025, 0.50, steel_tok)
