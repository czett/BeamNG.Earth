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

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "server"))

import buildings  # noqa: E402
import geodesy  # noqa: E402
import roads  # noqa: E402
from de_street_enhancer import brand_registry, classifier, placement, texture_atlas  # noqa: E402


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
    items = [(b, 0.0, 0.0) for b in (b_shop1, b_shop2, b_res1, b_res2)]
    drives = [{"w": 3.0, "n": [[42.0, 146.0, 0.0], [42.0, 134.0, 0.0]]}]

    posts = placement.plan_street_signs(
        frame, near_roads, box, street_names, props, _flat_ground, rings=[b.ring for b in (b_shop1, b_shop2, b_res1, b_res2)], drives=drives
    )
    targets, _ = classifier.classify_commercial_buildings(items, [], frame, 0.0, 0.0)
    yard_rows = placement.place_residential_yards(
        frame, box, items, near_roads, walks, drives, None, [b.ring for b in (b_shop1, b_shop2, b_res1, b_res2)], _flat_ground
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


def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    p1 = generate_street_atlas_preview()
    p2 = generate_shop_atlas_preview()
    p3 = generate_topdown_layout_preview()
    print(f"Generated previews:\n  {p1}\n  {p2}\n  {p3}")


if __name__ == "__main__":
    main()
