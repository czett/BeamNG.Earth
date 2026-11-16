#!/usr/bin/env python3
"""Visual diagnostic generator for the Germany (`DE`) Street-Level Immersion Enhancer.

Outputs inspectable PNG atlases and a 2D top-down synthetic intersection schematic
under `/tmp/de_enhancer_preview/` without requiring a running BeamNG client.
"""

import os
import sys
from pathlib import Path

os.environ.setdefault(
    "BNE_REGIONAL_DIR",
    os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "server", "tests", "fixtures", "regional"),
)

import numpy as np
from PIL import Image, ImageDraw, ImageFont
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "server"))

import buildings  # noqa: E402
import geodesy  # noqa: E402
import roads  # noqa: E402
from de_street_enhancer import brand_registry, classifier, facade_style, placement, texture_atlas  # noqa: E402


OUT_DIR = Path("/tmp/de_enhancer_preview")


def _road_spec(cls="residential", width=6.5):
    return roads.Spec(width=width, kind="paved", urban=True, cls=cls, oneway=False, walk=True)


def _flat_ground(x, y):
    return np.zeros_like(np.asarray(x, dtype=np.float64))


def generate_street_atlas_preview():
    names = [
        ("street|blue|Maximilianstraße", ("Maximilianstraße", "blue")),
        ("street|blue|Leopoldstraße", ("Leopoldstraße", "blue")),
        ("street|blue|Bürgermeister-von-Schubert-Straße", ("Bürgermeister-von-Schubert-Straße", "blue")),
        ("street|blue|Königsallee", ("Königsallee", "blue")),
        ("street|blue|Bahnhofstraße", ("Bahnhofstraße", "blue")),
        ("street|blue|Unter den Linden", ("Unter den Linden", "blue")),
        ("street|blue|Großmehringer Straße", ("Großmehringer Straße", "blue")),
        ("street|blue|Am Rathausplatz", ("Am Rathausplatz", "blue")),
        ("street|white|Neuhauser Straße", ("Neuhauser Straße", "white")),
        ("street|white|Schützenstraße", ("Schützenstraße", "white")),
    ]
    _, _, _, _, atlas = texture_atlas.pack_atlas(
        names,
        lambda pair: texture_atlas.render_street_plate(pair[0], variant=pair[1]),
        out_dir=None,
        vfs_dir=None,
        prefix="st",
    )
    out_path = OUT_DIR / "street_signs_atlas.png"
    atlas.save(out_path)
    return out_path


def generate_shop_atlas_preview():
    entries = []
    for key in (
        "rewe", "edeka", "aldi_sued", "aldi_nord", "lidl", "penny", "netto", "kaufland",
        "dm", "rossmann", "apotheke", "sparkasse", "volksbank", "post_dhl",
        "baeckerei", "backwerk", "kamps", "doener", "obi", "local_shop",
    ):
        spec = brand_registry.BY_KEY[key]
        label = "Stadt-Apotheke" if key == "apotheke" else ("Café am Markt" if key == "local_shop" else spec.title)
        entries.append((f"shop|{key}|{label}", (spec, label)))
    _, _, _, _, atlas = texture_atlas.pack_atlas(
        entries,
        lambda pair: texture_atlas.render_shop_fascia(pair[0], pair[1]),
        out_dir=None,
        vfs_dir=None,
        prefix="sh",
    )
    out_path = OUT_DIR / "shop_fascias_atlas.png"
    atlas.save(out_path)
    return out_path


def generate_topdown_layout_preview():
    frame = geodesy.EnuFrame(48.1351, 11.5820)  # Munich center
    box = (0.0, 0.0, 256.0, 256.0)

    road_defs = [
        ("r_main_w", _road_spec("secondary", 8.0), np.array([[0.0, 128.0, 0.0], [128.0, 128.0, 0.0]]), "Maximilianstraße"),
        ("r_main_e", _road_spec("secondary", 8.0), np.array([[128.0, 128.0, 0.0], [256.0, 128.0, 0.0]]), "Maximilianstraße"),
        ("r_cross_s", _road_spec("residential", 6.5), np.array([[128.0, 0.0, 0.0], [128.0, 128.0, 0.0]]), "Georgenstraße"),
        ("r_cross_n", _road_spec("residential", 6.5), np.array([[128.0, 128.0, 0.0], [128.0, 256.0, 0.0]]), "Leopoldstraße"),
        ("r_acute", _road_spec("residential", 5.5), np.array([[128.0, 128.0, 0.0], [240.0, 200.0, 0.0]]), "Türkenstraße"),
    ]
    near_roads = [(fid, sp, pts, 11.5820) for fid, sp, pts, _ in road_defs]
    street_names = {fid: nm for fid, _sp, _pts, nm in road_defs}
    walks = [
        {"pts": np.array([[0.0, 133.1, 0.0], [120.0, 133.1, 0.0]]), "side": 1, "w": 2.2},
        {"pts": np.array([[0.0, 122.9, 0.0], [120.0, 122.9, 0.0]]), "side": -1, "w": 2.2},
    ]

    # Lamps & German junction signs
    props = [
        ["eu_lamp_steel", 120.5, 134.8, 0.0, 90.0, 1.0, 9.0, 0.0],
        ["eu_lamp_concrete", 70.0, 122.0, 0.0, 270.0, 1.0, 9.0, 0.0],
        ["de_z306", 122.5, 122.5, 0.0, 0.0, 1.0, 3.46, 0.0],
        ["de_z205", 134.0, 122.5, 0.0, 90.0, 1.0, 3.39, 0.0],
    ]

    # Commercial buildings along Maximilianstraße south side + courtyard building behind
    b_shop1 = buildings.Spec(
        ring=np.array([[26.0, 108.0], [54.0, 108.0], [54.0, 120.0], [26.0, 120.0]]),
        floors=3, floor_h=3.2, height=10.2, roof="flat", shop=True, cls="supermarket",
        seed=0.14, sign=2, front=2, street=(2,), min_h=0.0, windows=True, name="REWE",
    )
    b_shop2 = buildings.Spec(
        ring=np.array([[64.0, 108.0], [88.0, 108.0], [88.0, 120.0], [64.0, 120.0]]),
        floors=3, floor_h=3.2, height=10.2, roof="flat", shop=True, cls="pharmacy",
        seed=0.45, sign=2, front=2, street=(2,), min_h=0.0, windows=True, name="Stadt-Apotheke",
    )
    b_res1 = buildings.Spec(
        ring=np.array([[28.0, 146.0], [46.0, 146.0], [46.0, 158.0], [28.0, 158.0]]),
        floors=2, floor_h=2.8, height=5.8, roof="gabled", shop=False, cls="detached",
        seed=0.08, door=(0, 5.0), min_h=0.0,
    )
    b_res2 = buildings.Spec(
        ring=np.array([[62.0, 146.0], [82.0, 146.0], [82.0, 158.0], [62.0, 158.0]]),
        floors=2, floor_h=2.8, height=5.8, roof="gabled", shop=False, cls="detached",
        seed=0.61, door=(0, 12.0), min_h=0.0,
    )
    # Narrow suburban terrace & omitted-roof residential house (setback < 1.25 m behind sidewalk edge)
    b_terrace = buildings.Spec(
        ring=np.array([[88.0, 135.6], [96.0, 135.6], [96.0, 145.6], [88.0, 145.6]]),
        floors=2, floor_h=2.8, height=5.8, roof="gabled", shop=False, cls="terrace",
        seed=0.22, door=(0, 2.5), min_h=0.0,
    )
    b_flat_res = buildings.Spec(
        ring=np.array([[100.0, 135.5], [111.0, 135.5], [111.0, 145.5], [100.0, 145.5]]),
        floors=2, floor_h=2.8, height=5.6, roof="flat", shop=False, cls="house",
        seed=0.41, door=(0, 5.5), min_h=0.0,
    )
    b_list = [b_shop1, b_shop2, b_res1, b_res2, b_terrace, b_flat_res]
    items = [(b, 0.0, 0.0) for b in b_list]
    drives = [{"w": 3.0, "n": [[42.0, 146.0, 0.0], [42.0, 134.0, 0.0]]}]

    with mock.patch.dict(os.environ, {"BNE_DE_STREET_IMMERSION": "on"}):
        posts = placement.plan_street_signs(
            frame, near_roads, box, street_names, props, _flat_ground, rings=[b.ring for b in b_list], drives=drives
        )
        targets, _ = classifier.classify_commercial_buildings(items, [], frame, 0.0, 0.0)
        yard_rows = placement.place_residential_yards(
            frame, box, items, near_roads, walks, drives, None, [b.ring for b in b_list], _flat_ground
        )

    # Draw 1024x1024 top-down schematic (4 px per metre over 256x256 tile)
    S = 4.0
    img = Image.new("RGB", (1024, 1024), (235, 240, 232))
    d = ImageDraw.Draw(img)

    def px(pt):
        return (float(pt[0]) * S, (256.0 - float(pt[1])) * S)

    # Grid lines
    for g in range(0, 257, 32):
        d.line([(g * S, 0), (g * S, 1024)], fill=(215, 222, 214), width=1)
        d.line([(0, g * S), (1024, g * S)], fill=(215, 222, 214), width=1)

    # Sidewalks & driveways
    for w in walks:
        pts = w["pts"]
        d.line([px(pts[0]), px(pts[1])], fill=(195, 198, 202), width=int(round(w["w"] * S)))
    for dr in drives:
        n = dr["n"]
        d.line([px(n[0]), px(n[1])], fill=(210, 180, 135), width=int(round(dr["w"] * S)))

    # Carriageways
    for _fid, sp, pts, _ in near_roads:
        d.line([px(pts[0]), px(pts[1])], fill=(82, 86, 94), width=int(round(sp.width * S)))
        d.line([px(pts[0]), px(pts[1])], fill=(235, 235, 235), width=1)

    # Buildings
    for b, _, _ in items:
        poly = [px(p) for p in b.ring]
        fill = (205, 196, 185) if b.shop else (225, 204, 178)
        d.polygon(poly, fill=fill, outline=(70, 65, 60))

    # Yard hedges & fences
    for r in yard_rows:
        cx, cy = px((r[1], r[2]))
        col = (34, 139, 34) if r[0] == "fr_hedge" else (139, 90, 43)
        rad = 4.5 if r[0] == "fr_hedge" else 3.5
        d.ellipse([cx - rad, cy - rad, cx + rad, cy + rad], fill=col, outline=(20, 50, 20))

    # Shop fascias
    font_sm = texture_atlas._load_font(12, condensed=False)
    for t in targets:
        p0 = t.center_xy - t.d_along * (t.width_m * 0.5)
        p1 = t.center_xy + t.d_along * (t.width_m * 0.5)
        d.line([px(p0), px(p1)], fill=t.spec_brand.bg_rgb, width=6)
        tx, ty = px(t.center_xy + t.out_normal * 2.2)
        d.text((tx - 20, ty - 6), f"{t.spec_brand.title}: {t.label}", fill=(140, 15, 25), font=font_sm)

    # Lamps & de_z* signs
    for row in props:
        g, rx, ry = row[0], row[1], row[2]
        cx, cy = px((rx, ry))
        if str(g).startswith("eu_lamp"):
            d.ellipse([cx - 5, cy - 5, cx + 5, cy + 5], fill=(255, 200, 40), outline=(40, 40, 40))
        elif str(g).startswith("de_z"):
            d.polygon([(cx, cy - 7), (cx - 6, cy + 5), (cx + 6, cy + 5)], fill=(235, 180, 0), outline=(10, 10, 10))

    # Street signs & blade orientations
    for post in posts:
        cx, cy = px(post.xy)
        d.ellipse([cx - 6, cy - 6, cx + 6, cy + 6], fill=(14, 52, 108), outline=(255, 255, 255), width=2)
        for idx_b, (b_name, b_dir, _bz, _v) in enumerate(post.blades):
            p_a = post.xy - b_dir * 3.0
            p_b = post.xy + b_dir * 3.0
            d.line([px(p_a), px(p_b)], fill=(14, 90, 210), width=3)
        lbl_y = cy - 58
        d.rectangle([cx - 148, lbl_y - 4, cx - 14, lbl_y + len(post.blades) * 14 + 4], fill=(245, 248, 255), outline=(14, 52, 108))
        for idx_b, (b_name, _bd, _bz, _v) in enumerate(post.blades):
            d.text((cx - 142, lbl_y + idx_b * 14), b_name, fill=(10, 40, 100), font=font_sm)

    # Legend banner
    d.rectangle([10, 10, 390, 130], fill=(250, 250, 250), outline=(120, 120, 120))
    legend = [
        ("Dark blue dot/lines: Street name post & blades", (14, 52, 108)),
        ("Yellow circle / triangle: Lamp / de_z* sign", (180, 130, 0)),
        ("Colored bar + label: Commercial shop fascia", (180, 20, 30)),
        ("Green / Brown dots: Hedges / Fences (drive clear)", (34, 139, 34)),
    ]
    for i, (txt, col) in enumerate(legend):
        d.text((20, 20 + i * 24), txt, fill=col, font=font_sm)

    out_path = OUT_DIR / "intersection_topdown.png"
    img.save(out_path)
    return out_path


def _draw_elevation(d: ImageDraw.ImageDraw, rect: tuple[int, int, int, int], spec, fascia_target=None):
    """Render an orthographic front (-Y) elevation directly from `buildings.build()` arrays."""
    x0_px, y0_px, x1_px, y1_px = rect
    spec.gring = np.zeros(len(spec.ring), dtype=np.float64)
    if fascia_target is not None:
        spec.sign = None
    P, _uv, T, M, mats, C = buildings.build([(spec, 0.0, 0.0)], lite=False)
    roof_mats = {
        buildings.MATERIALS.index(m)
        for m in (
            buildings.ROOF_FLAT, buildings.ROOF_SLATE, buildings.ROOF_SHINGLE, buildings.ROOF_METAL,
            buildings.ROOF_TILES, buildings.ROOF_SLATE_ROUND, buildings.ROOF_SLATE_DARK, buildings.ROOF_WOOD,
        )
    }
    white_fac_mi = buildings.MATERIALS.index(buildings.FACADE)

    # Orthographic framing around X and Z, back-to-front painter sort by Y centroid.
    xs = P[:, 0]
    zs = P[:, 2]
    xmin, xmax = float(xs.min()) - 0.8, float(xs.max()) + 0.8
    zmin, zmax = -0.15, max(float(zs.max()) + 0.8, 7.5)
    pw, ph = x1_px - x0_px - 24, y1_px - y0_px - 28
    scale = min(pw / max(xmax - xmin, 1.0), ph / max(zmax - zmin, 1.0))
    cx_box = 0.5 * (x0_px + x1_px)
    x_mid = 0.5 * (xmin + xmax)
    y_ground = y1_px - 14

    def proj(pt):
        sx = cx_box + (float(pt[0]) - x_mid) * scale
        sy = y_ground - float(pt[2]) * scale
        return (sx, sy)

    # Background & ground sidewalk slab
    d.rectangle(rect, fill=(232, 238, 246), outline=(140, 148, 160))
    d.rectangle([x0_px + 4, y_ground, x1_px - 4, y1_px - 4], fill=(176, 178, 182))

    # Build drawable triangle list sorted far-to-near (+Y to -Y)
    v0 = P[T[:, 0]]
    nrm = np.cross(P[T[:, 1]] - v0, P[T[:, 2]] - v0)
    n_len = np.linalg.norm(nrm, axis=1)
    tri_items = []
    for i, tri in enumerate(T):
        if n_len[i] < 1e-8:
            continue
        nv = nrm[i] / n_len[i]
        if nv[1] > 0.25:
            continue
        pts = P[tri]
        if pts[:, 2].max() < -0.05:
            continue
        y_mid = float(pts[:, 1].mean())
        mi = int(M[i])
        rgb = C[tri, :3].astype(np.float64).mean(axis=0)
        # Apply approximate base texture albedo tint for clay tile / clinker / cornice contrast
        if mats[mi] == buildings.ROOF_TILES:
            rgb = rgb * np.array([0.78, 0.44, 0.30])
        elif mats[mi] in (buildings.ROOF_SLATE, buildings.ROOF_SLATE_DARK, buildings.ROOF_SLATE_ROUND):
            rgb = rgb * np.array([0.42, 0.44, 0.48])
        elif mats[mi] == buildings.ROOF_FLAT:
            rgb = rgb * np.array([0.48, 0.48, 0.50])
        elif spec.band == buildings.BAND_BRICK and mats[mi] == buildings.FACADE:
            rgb = rgb * np.array([0.82, 0.66, 0.62])
        shade = 0.72 + 0.18 * max(-1.0, float(nv[2])) - 0.14 * float(nv[1])
        col = tuple(int(max(0, min(255, round(v * shade)))) for v in rgb)
        tri_items.append((y_mid, [proj(pts[0]), proj(pts[1]), proj(pts[2])], col, mi, pts))

    tri_items.sort(key=lambda it: -it[0])
    for _ym, poly, col, mi, pts in tri_items:
        outline = (65, 62, 60) if mi in roof_mats else None
        d.polygon(poly, fill=col, outline=outline)

    # Overlay EDEKA / commercial shop fascia box in elevation view
    if fascia_target is not None:
        fx0 = float(fascia_target.center_xy[0] - fascia_target.width_m * 0.5)
        fx1 = float(fascia_target.center_xy[0] + fascia_target.width_m * 0.5)
        p_bl = proj((fx0, 0.0, fascia_target.z_bottom))
        p_tr = proj((fx1, 0.0, fascia_target.z_top))
        d.rectangle([p_bl[0], p_tr[1], p_tr[0], p_bl[1]], fill=fascia_target.spec_brand.bg_rgb, outline=(25, 25, 25), width=2)
        fnt = texture_atlas._load_font(12, condensed=False)
        d.text((0.5 * (p_bl[0] + p_tr[0]) - 22, 0.5 * (p_tr[1] + p_bl[1]) - 6), fascia_target.label, fill=fascia_target.spec_brand.fg_rgb, font=fnt)

    # Draw guide ticks: 0.75 m Sockel & eave height
    z_sock_y = y_ground - 0.75 * scale
    d.line([(x0_px + 6, z_sock_y), (x0_px + 26, z_sock_y)], fill=(35, 95, 190), width=2)
    z_eave = float(spec.height)
    z_eave_y = y_ground - z_eave * scale
    d.line([(x1_px - 26, z_eave_y), (x1_px - 6, z_eave_y)], fill=(180, 45, 45), width=2)


def generate_facades_comparison_preview():
    img = Image.new("RGB", (1340, 840), (247, 246, 243))
    d = ImageDraw.Draw(img)
    f_title = texture_atlas._load_font(18, condensed=False)
    f_sub = texture_atlas._load_font(13, condensed=False)
    f_xs = texture_atlas._load_font(11, condensed=True)

    d.text((20, 12), "BeamNG.Earth DE Realistic Facades — Before (Legacy Pastel) vs. After (DE Palette + Option B Sockel/AO + Overhangs + Cornice Fix)", fill=(28, 30, 34), font=f_title)

    # Row 1: Palette comparison swatches
    def _draw_swatches(x0, y0, title, rgbs, border=(90, 90, 90)):
        d.text((x0, y0), title, fill=(40, 42, 46), font=f_sub)
        for i, rgb in enumerate(rgbs):
            sx = x0 + i * 38
            sy = y0 + 20
            col = tuple(int(max(0, min(255, round(v * 255)))) for v in rgb)
            d.rectangle([sx, sy, sx + 34, sy + 26], fill=col, outline=border)

    legacy_pastels = [rgb for _, (mat, rgb) in buildings.LOOKS.items() if mat == buildings.FACADE][:10]
    _draw_swatches(20, 46, "Before — Generic North-American Pastels (PAINT_TINTS)", legacy_pastels[:10])
    _draw_swatches(450, 46, "After — DE South Plaster (Munich / Altweiss / Sandstein)", facade_style.DE_PLASTER_SOUTH[:10])
    _draw_swatches(890, 46, "After — Ruhr/North Clinker + DE Clay & Slate Roofs", list(facade_style.DE_BRICK_TINTS) + list(facade_style.DE_ROOF_TILE_TINTS) + list(facade_style.DE_ROOF_SLATE_DARK_TINTS[:2]))

    # Row 2 & 3: Three architectural mesh elevations (Before on top row, After on bottom row)
    cases = [
        (
            "1. Dortmund Row End (Pastel -> Clinker Brick + 0.75m Sockel + 0.35m Eave AO + Overhang)",
            (51.5136, 7.4653),
            np.array([[1.2, 0.7], [10.7, 0.7], [10.7, 8.7], [1.2, 8.7]]),
            {"class": "house", "roof_shape": "gabled", "floors": 2},
            False,
        ),
        (
            "2. Munich House (Non-Alpine Wood -> Warm Plaster + Biberschwanz Clay + Overhang)",
            (48.1351, 11.5820),
            np.array([[0.0, 0.0], [11.0, 0.0], [11.0, 8.5], [0.0, 8.5]]),
            {"class": "house", "roof_shape": "half-hipped", "floors": 2},
            False,
        ),
        (
            "3. EDEKA Supermarket (Clipped Fascia -> Mineral Wall + Cornice-Cleared Fascia)",
            (51.5136, 7.4653),
            np.array([[0.0, 0.0], [16.0, 0.0], [16.0, 12.0], [0.0, 12.0]]),
            {"class": "supermarket", "roof_shape": "flat", "floors": 1, "height": 4.5, "name": "EDEKA", "shop": True},
            True,
        ),
    ]

    col_w = 420
    for idx, (label, (lat, lon), ring, attrs, is_edeka) in enumerate(cases):
        cx0 = 20 + idx * (col_w + 20)
        d.text((cx0, 108), label, fill=(22, 24, 28), font=f_xs)

        # BEFORE
        with mock.patch.dict(os.environ, {"BNE_DE_STREET_IMMERSION": "off"}):
            s_before = buildings.plan(ring, dict(attrs), 0, lat, lon)
            if is_edeka:
                s_before.shop = True
                s_before.windows = False
                s_before.plain = False
                s_before.sign = 0
            d.text((cx0, 128), "BEFORE (BNE_DE_STREET_IMMERSION=off)", fill=(150, 35, 35), font=f_sub)
            _draw_elevation(d, (cx0, 148, cx0 + col_w, 458), s_before)

        # AFTER
        with mock.patch.dict(os.environ, {"BNE_DE_STREET_IMMERSION": "on"}):
            s_after = buildings.plan(ring, dict(attrs), 0, lat, lon)
            if is_edeka:
                s_after.shop = True
                s_after.windows = False
                s_after.plain = False
                s_after.sign = 0
                s_after.height = 4.5
            facade_style.compute_roof_overhangs([(s_after, 0.0, 0.0)])
            fascia = None
            if is_edeka:
                fr = geodesy.EnuFrame(lat, lon)
                tgts, _ = classifier.classify_commercial_buildings([(s_after, 0.0, 0.0)], [], fr, 0.0, 0.0)
                fascia = tgts[0] if tgts else None
            d.text((cx0, 474), "AFTER (DE Realistic Facades + Baked Sockel/AO)", fill=(22, 115, 48), font=f_sub)
            _draw_elevation(d, (cx0, 494, cx0 + col_w, 804), s_after, fascia_target=fascia)

    d.text((20, 816), "Blue tick = 0.75 m Sockel cap  |  Red tick = eave line (z_eave)  |  0 extra materials / 0 extra draw calls", fill=(70, 75, 82), font=f_xs)
    out_path = OUT_DIR / "facades_comparison.png"
    img.save(out_path)
    return out_path


def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    p1 = generate_street_atlas_preview()
    p2 = generate_shop_atlas_preview()
    p3 = generate_topdown_layout_preview()
    p4 = generate_facades_comparison_preview()
    print(f"Generated previews:\n  {p1}\n  {p2}\n  {p3}\n  {p4}")


if __name__ == "__main__":
    main()
