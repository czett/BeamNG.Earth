"""Pillow-based German sign/fascia typography rendering & cached DXT1 DDS atlases.

Generates dynamic texture atlases for street name signs (`de_st_<hash>.dds`)
and commercial shopfront fascias (`de_sh_<hash>.dds`) using bundled DIN /
DejaVu fonts and encodes directly to DDS via `imagery.write_dds` to avoid
BeamNG's runtime TextureCooker PNG deadlock.
"""

import functools
import hashlib
import math
import os
import re
from typing import Iterable

import numpy as np
from PIL import Image, ImageDraw, ImageFont

import imagery


_HERE = os.path.dirname(os.path.abspath(__file__))
_SERVER_DIR = os.path.dirname(_HERE)
_REPO_ROOT = os.path.dirname(_SERVER_DIR)

FONT_CANDIDATES_BOLD = (
    os.path.join(_REPO_ROOT, "tools", "fonts", "D-DIN-Bold.otf"),
    os.path.join(_SERVER_DIR, "data", "fonts", "D-DIN.ttf"),
    os.path.join(_REPO_ROOT, "tools", "fonts", "DejaVuSans-Bold.ttf"),
)
FONT_CANDIDATES_CONDENSED = (
    os.path.join(_SERVER_DIR, "data", "fonts", "D-DINCondensed.ttf"),
    os.path.join(_REPO_ROOT, "tools", "fonts", "town", "D-DINCondensed.ttf"),
    os.path.join(_REPO_ROOT, "tools", "fonts", "DejaVuSans-Bold.ttf"),
)

SLOT_W = 512
SLOT_H = 64
ATLAS_W = 1024
MAX_SLOTS_16 = 16
MAX_SLOTS_32 = 32
INNER_PAD = 4  # DXT1 uses 4x4 texel blocks; keeping 4px border inset prevents neighbor mip bleed.

# Authentic German street name sign color schemes.
STREET_PALETTE_BLUE = {
    "bg": (14, 52, 108),       # RAL 5010 Enzianblau
    "fg": (248, 250, 252),     # Pure reflective white
    "border": (236, 240, 245),
}
STREET_PALETTE_WHITE = {
    "bg": (244, 244, 238),     # Municipal cream-white variant
    "fg": (18, 22, 28),
    "border": (24, 28, 36),
}

_ABBREV_RULES = (
    (re.compile(r"straße\b", re.IGNORECASE), "str."),
    (re.compile(r"strasse\b", re.IGNORECASE), "str."),
    (re.compile(r"\bBürgermeister-", re.IGNORECASE), "Bgm.-"),
    (re.compile(r"\bSankt\s+", re.IGNORECASE), "St. "),
)


@functools.lru_cache(maxsize=64)
def _load_font(size: int, condensed: bool = False):
    """Load bundled DIN / DejaVu font with graceful Pillow default fallback."""
    candidates = FONT_CANDIDATES_CONDENSED if condensed else FONT_CANDIDATES_BOLD
    for path in candidates:
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            continue
    try:
        return ImageFont.load_default(size=size)
    except (OSError, TypeError):
        return ImageFont.load_default()


def _shorten_german_street(name: str, max_px: int, draw: ImageDraw.ImageDraw, min_size: int = 24) -> tuple[str, ImageFont.FreeTypeFont]:
    """Fit German street name inside slot width using DIN Bold -> Condensed -> standard abbreviations."""
    text = " ".join(str(name or "").split())
    if not text:
        return "", _load_font(28, condensed=False)

    candidates = [text]
    short = text
    for pat, repl in _ABBREV_RULES:
        nxt = pat.sub(repl, short)
        if nxt != short:
            short = nxt
            candidates.append(short)

    for cand in candidates:
        for size in (36, 33, 30, 27):
            font = _load_font(size, condensed=False)
            bx = draw.textbbox((0, 0), cand, font=font)
            if (bx[2] - bx[0]) <= max_px:
                return cand, font
        for size in (36, 33, 30, 27, 24, 21):
            font = _load_font(size, condensed=True)
            bx = draw.textbbox((0, 0), cand, font=font)
            if (bx[2] - bx[0]) <= max_px:
                return cand, font

    # Final clamp with smallest readable condensed size.
    best = candidates[-1]
    font = _load_font(max(18, min_size - 4), condensed=True)
    return best, font


def _fit_text(draw: ImageDraw.ImageDraw, text: str, max_w: int, max_h: int, sizes=(38, 34, 30, 26, 22, 18)):
    """Select largest font fitting inside `(max_w, max_h)`."""
    clean = " ".join(str(text or "").split()) or "Shop"
    for condensed in (False, True):
        for sz in sizes:
            f = _load_font(sz, condensed=condensed)
            bx = draw.textbbox((0, 0), clean, font=f)
            if (bx[2] - bx[0]) <= max_w and (bx[3] - bx[1]) <= max_h:
                return clean, f, bx
    f = _load_font(16, condensed=True)
    return clean, f, draw.textbbox((0, 0), clean, font=f)


@functools.lru_cache(maxsize=256)
def render_street_plate(name: str, variant: str = "blue", w: int = SLOT_W, h: int = SLOT_H) -> Image.Image:
    """Render a crisp `w x h` German street name plate (RAL 5010 blue or white municipal style)."""
    pal = STREET_PALETTE_WHITE if variant == "white" else STREET_PALETTE_BLUE
    img = Image.new("RGB", (w, h), pal["bg"])
    draw = ImageDraw.Draw(img)

    # Outer edge flush + crisp rounded inset frame.
    pad = INNER_PAD
    draw.rounded_rectangle(
        [pad, pad, w - 1 - pad, h - 1 - pad],
        radius=8,
        fill=pal["bg"],
        outline=pal["border"],
        width=2,
    )
    if variant == "white":
        draw.rounded_rectangle(
            [pad + 3, pad + 3, w - 4 - pad, h - 4 - pad],
            radius=6,
            outline=pal["border"],
            width=1,
        )

    inner_w = w - 2 * (pad + 14)
    fitted, font = _shorten_german_street(name, inner_w, draw)
    bx = draw.textbbox((0, 0), fitted, font=font)
    tw, th = bx[2] - bx[0], bx[3] - bx[1]
    tx = (w - tw) / 2.0 - bx[0]
    ty = (h - th) / 2.0 - bx[1]
    draw.text((tx, ty), fitted, font=font, fill=pal["fg"])
    return img


def _draw_emblem(draw: ImageDraw.ImageDraw, spec, x0: int, y0: int, size: int) -> bool:
    """Draw a vector/raster brand emblem inside `[x0, y0, x0+size, y0+size]`. Returns True if drawn."""
    emb = spec.emblem
    if not emb or emb == "none":
        return False

    cx, cy = x0 + size / 2.0, y0 + size / 2.0
    r = size * 0.44
    accent = spec.accent_rgb or spec.fg_rgb

    if emb == "apotheke_a":
        # Stylized German Apotheke red Gothic 'A' with inset white cross.
        red = (225, 10, 24)
        draw.rounded_rectangle([x0 + 2, y0 + 2, x0 + size - 2, y0 + size - 2], radius=6, fill=(255, 255, 255), outline=red, width=2)
        pts = [
            (x0 + size * 0.18, y0 + size * 0.86),
            (x0 + size * 0.46, y0 + size * 0.14),
            (x0 + size * 0.64, y0 + size * 0.14),
            (x0 + size * 0.84, y0 + size * 0.86),
            (x0 + size * 0.67, y0 + size * 0.86),
            (x0 + size * 0.62, y0 + size * 0.68),
            (x0 + size * 0.36, y0 + size * 0.68),
            (x0 + size * 0.31, y0 + size * 0.86),
        ]
        draw.polygon(pts, fill=red)
        # White cross inside the upper aperture.
        mx, my = x0 + size * 0.50, y0 + size * 0.46
        draw.rectangle([mx - 5, my - 2, mx + 5, my + 2], fill=(255, 255, 255))
        draw.rectangle([mx - 2, my - 5, mx + 2, my + 5], fill=(255, 255, 255))
        return True

    if emb == "sparkasse_s":
        draw.ellipse([cx - r * 0.30, y0 + 4, cx + r * 0.30, y0 + 4 + r * 0.60], fill=(255, 255, 255))
        draw.arc([cx - r * 0.72, y0 + size * 0.34, cx + r * 0.72, y0 + size * 0.92], 140, 390, fill=(255, 255, 255), width=5)
        draw.rectangle([cx - r * 0.48, cy + 1, cx + r * 0.48, cy + 6], fill=(255, 255, 255))
        return True

    if emb == "lidl_disc":
        draw.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(255, 240, 0), outline=(227, 6, 19), width=3)
        f = _load_font(int(size * 0.42), condensed=False)
        bx = draw.textbbox((0, 0), "L", font=f)
        draw.text((cx - (bx[2] - bx[0]) / 2 - bx[0], cy - (bx[3] - bx[1]) / 2 - bx[1]), "L", font=f, fill=(0, 80, 170))
        return True

    if emb == "edeka_e":
        draw.rounded_rectangle([x0 + 3, y0 + 3, x0 + size - 3, y0 + size - 3], radius=5, fill=(0, 59, 126))
        f = _load_font(int(size * 0.62), condensed=False)
        bx = draw.textbbox((0, 0), "E", font=f)
        draw.text((cx - (bx[2] - bx[0]) / 2 - bx[0], cy - (bx[3] - bx[1]) / 2 - bx[1]), "E", font=f, fill=(255, 237, 0))
        return True

    if emb == "aldi_a":
        draw.rounded_rectangle([x0 + 3, y0 + 3, x0 + size - 3, y0 + size - 3], radius=6, fill=(0, 120, 193), outline=accent, width=3)
        for k, stripe in enumerate((0.26, 0.46, 0.66)):
            draw.rectangle([x0 + 8, y0 + int(size * stripe), x0 + size - 8, y0 + int(size * stripe) + 4], fill=(255, 255, 255))
        return True

    if emb == "rewe_bar":
        draw.rectangle([x0 + 4, y0 + 10, x0 + 10, y0 + size - 10], fill=(255, 255, 255))
        draw.rectangle([x0 + 14, y0 + 16, x0 + 20, y0 + size - 10], fill=(255, 255, 255))
        return True

    if emb in ("pretzel", "post_horn", "vr_v", "dm_wave", "kaufland_sq", "netto_ribbon", "penny_dot", "rossmann_dot", "flame_badge"):
        draw.ellipse([cx - r * 0.85, cy - r * 0.85, cx + r * 0.85, cy + r * 0.85], fill=accent)
        letter = {"pretzel": "B", "post_horn": "P", "vr_v": "V", "dm_wave": "dm", "kaufland_sq": "K",
                  "netto_ribbon": "N", "penny_dot": "P", "rossmann_dot": "R", "flame_badge": "D"}[emb]
        f = _load_font(int(size * (0.36 if len(letter) > 1 else 0.46)), condensed=False)
        bx = draw.textbbox((0, 0), letter, font=f)
        ink = spec.bg_rgb if emb != "netto_ribbon" else (255, 255, 255)
        draw.text((cx - (bx[2] - bx[0]) / 2 - bx[0], cy - (bx[3] - bx[1]) / 2 - bx[1]), letter, font=f, fill=ink)
        return True

    return False


@functools.lru_cache(maxsize=256)
def _render_shop_fascia_cached(
    brand_key: str,
    emblem: str,
    bg_rgb: tuple[int, int, int],
    fg_rgb: tuple[int, int, int],
    border_rgb: tuple[int, int, int] | None,
    accent_rgb: tuple[int, int, int] | None,
    label: str,
    w: int,
    h: int,
) -> Image.Image:
    """Render an illuminated commercial fascia banner into a `w x h` RGB image (cached)."""
    from types import SimpleNamespace

    spec = SimpleNamespace(
        key=brand_key,
        emblem=emblem,
        bg_rgb=bg_rgb,
        fg_rgb=fg_rgb,
        border_rgb=border_rgb,
        accent_rgb=accent_rgb,
    )
    img = Image.new("RGB", (w, h), spec.bg_rgb)
    draw = ImageDraw.Draw(img)

    pad = INNER_PAD
    border_col = spec.border_rgb or spec.fg_rgb
    draw.rounded_rectangle(
        [pad, pad, w - 1 - pad, h - 1 - pad],
        radius=6,
        fill=spec.bg_rgb,
        outline=border_col,
        width=2,
    )

    emb_size = h - 2 * (pad + 4)
    has_emb = _draw_emblem(draw, spec, pad + 10, pad + 4, emb_size)
    text_left = pad + (18 + emb_size if has_emb else 16)
    text_w = (w - pad - 14) - text_left
    fitted, font, bx = _fit_text(draw, label, max(80, text_w), h - 2 * (pad + 6))
    tw, th = bx[2] - bx[0], bx[3] - bx[1]
    tx = text_left + max(0.0, (text_w - tw) / 2.0) - bx[0]
    ty = (h - th) / 2.0 - bx[1]
    draw.text((tx, ty), fitted, font=font, fill=spec.fg_rgb)
    return img


def render_shop_fascia(spec, label: str, w: int = SLOT_W, h: int = SLOT_H) -> Image.Image:
    """Render an illuminated commercial fascia banner into a `w x h` RGB image."""
    return _render_shop_fascia_cached(
        getattr(spec, "key", ""),
        getattr(spec, "emblem", ""),
        tuple(spec.bg_rgb),
        tuple(spec.fg_rgb),
        tuple(spec.border_rgb) if spec.border_rgb is not None else None,
        tuple(spec.accent_rgb) if spec.accent_rgb is not None else None,
        str(label),
        w,
        h,
    )


def uv_subrect(uv: tuple[float, float, float, float], rx0: float, ry0: float, rx1: float, ry1: float) -> tuple[float, float, float, float]:
    """Slice a top-down `[0..1]` sub-rectangle `(rx0, ry0, rx1, ry1)` out of a slot's Collada UV rect."""
    u0, v_bot, u1, v_top = uv
    du = u1 - u0
    dv = v_top - v_bot
    return (
        u0 + rx0 * du,
        v_top - ry1 * dv,
        u0 + rx1 * du,
        v_top - ry0 * dv,
    )


def render_bus_stop_panel(stop_name: str, w: int = SLOT_W, h: int = SLOT_H) -> Image.Image:
    """Render German StVO 224 `H` Haltestelle sign (left 25%) + timetable & stop name (right 75%)."""
    img = Image.new("RGB", (w, h), (236, 238, 232))
    draw = ImageDraw.Draw(img)
    pad = INNER_PAD

    # Left quadrant (0 .. 0.25): yellow StVO 224 square with green ring + bold 'H'.
    split_x = w // 4
    draw.rectangle([pad, pad, split_x - pad, h - pad], fill=(244, 198, 12))
    cx, cy = split_x // 2, h // 2
    rad = min(split_x // 2 - pad - 2, h // 2 - pad - 2)
    draw.ellipse([cx - rad, cy - rad, cx + rad, cy + rad], fill=(244, 198, 12), outline=(12, 108, 52), width=4)
    font_h = _load_font(max(18, int(rad * 1.45)), condensed=False)
    bx_h = draw.textbbox((0, 0), "H", font=font_h)
    draw.text((cx - (bx_h[2] - bx_h[0]) / 2.0 - bx_h[0], cy - (bx_h[3] - bx_h[1]) / 2.0 - bx_h[1]), "H", font=font_h, fill=(12, 108, 52))

    # Right 3/4 (0.25 .. 1.0): green header bar with stop name + white timetable schedule grid.
    tx0 = split_x + pad
    tx1 = w - pad
    hdr_h = int((h - 2 * pad) * 0.46)
    draw.rectangle([tx0, pad, tx1, pad + hdr_h], fill=(12, 108, 52))
    label = " ".join(str(stop_name or "Haltestelle").split()) or "Haltestelle"
    fitted, font_lbl, bx_l = _fit_text(draw, label, max(60, tx1 - tx0 - 10), max(12, hdr_h - 4))
    draw.text((tx0 + 6 - bx_l[0], pad + (hdr_h - (bx_l[3] - bx_l[1])) / 2.0 - bx_l[1]), fitted, font=font_lbl, fill=(255, 255, 255))

    # Timetable rows below header
    tt_y0 = pad + hdr_h + 2
    draw.rectangle([tx0, tt_y0, tx1, h - pad], fill=(248, 248, 244), outline=(140, 148, 142))
    for row_i, y_frac in enumerate((0.25, 0.55, 0.82)):
        ry = int(tt_y0 + (h - pad - tt_y0) * y_frac)
        draw.line([(tx0 + 6, ry), (tx1 - 6, ry)], fill=(120, 130, 126) if row_i % 2 == 0 else (180, 186, 182), width=1)
    return img


@functools.lru_cache(maxsize=4)
def render_furniture_swatch(w: int = SLOT_W, h: int = SLOT_H) -> Image.Image:
    """Render 8x 64x64 micro-prop material swatches inside one 512x64 atlas slot."""
    img = Image.new("RGB", (w, h), (46, 52, 58))
    draw = ImageDraw.Draw(img)
    sw = w // 8  # 64 px

    # 0: Stromkasten pebble-grey cabinet with dark louver slots
    x0 = 0
    draw.rectangle([x0, 0, x0 + sw - 1, h - 1], fill=(178, 182, 176))
    for y_l in range(14, 38, 5):
        draw.line([(x0 + 10, y_l), (x0 + sw - 11, y_l)], fill=(96, 102, 98), width=2)
    draw.rectangle([x0 + 6, h - 12, x0 + sw - 7, h - 1], fill=(116, 120, 118))

    # 1: DHL Packstation signal yellow + red stripe + locker doors
    x0 = sw
    draw.rectangle([x0, 0, x0 + sw - 1, h - 1], fill=(245, 200, 12))
    draw.rectangle([x0, 4, x0 + sw - 1, 14], fill=(208, 18, 28))
    for gx in (x0 + 16, x0 + 32, x0 + 48):
        draw.line([(gx, 16), (gx, h - 4)], fill=(184, 148, 8), width=1)
    for gy in (24, 38, 50):
        draw.line([(x0 + 4, gy), (x0 + sw - 5, gy)], fill=(184, 148, 8), width=1)
    draw.rectangle([x0 + 20, 26, x0 + 42, 42], fill=(42, 48, 56))

    # 2: Altglascontainer trio (Weiss / Braun / Gruen bands)
    x0 = sw * 2
    draw.rectangle([x0, 0, x0 + 20, h - 1], fill=(224, 226, 220))
    draw.rectangle([x0 + 21, 0, x0 + 42, h - 1], fill=(118, 68, 36))
    draw.rectangle([x0 + 43, 0, x0 + sw - 1, h - 1], fill=(34, 106, 52))
    for cx_b in (x0 + 10, x0 + 31, x0 + 53):
        draw.ellipse([cx_b - 5, 16, cx_b + 5, 26], fill=(24, 28, 30))

    # 3: Poller dark anthracite + red/white reflective band
    x0 = sw * 3
    draw.rectangle([x0, 0, x0 + sw - 1, h - 1], fill=(44, 48, 54))
    draw.rectangle([x0, 10, x0 + sw - 1, 18], fill=(214, 34, 34))
    draw.rectangle([x0, 19, x0 + sw - 1, 27], fill=(240, 240, 236))
    draw.rectangle([x0, 28, x0 + sw - 1, 36], fill=(214, 34, 34))

    # 4: Bus shelter blue-grey tinted tempered glass
    x0 = sw * 4
    draw.rectangle([x0, 0, x0 + sw - 1, h - 1], fill=(108, 138, 162))
    draw.line([(x0 + 10, 4), (x0 + 26, h - 5)], fill=(142, 174, 198), width=4)
    for dx in range(x0 + 6, x0 + sw - 4, 10):
        draw.rectangle([dx, h // 2 - 2, dx + 4, h // 2 + 2], fill=(220, 228, 234))

    # 5: Anthracite shelter steel
    draw.rectangle([sw * 5, 0, sw * 6 - 1, h - 1], fill=(46, 52, 58))
    # 6: Warm wood bench slats
    draw.rectangle([sw * 6, 0, sw * 7 - 1, h - 1], fill=(134, 88, 52))
    # 7: Concrete plinth
    draw.rectangle([sw * 7, 0, sw * 8 - 1, h - 1], fill=(136, 138, 134))
    return img


FUEL_PYLON_PALETTES: dict[str, tuple[tuple[int, int, int], tuple[int, int, int], str]] = {
    "aral": ((0, 72, 154), (255, 255, 255), "ARAL"),
    "shell": ((251, 206, 7), (218, 22, 28), "SHELL"),
    "esso": ((12, 54, 128), (255, 255, 255), "ESSO"),
    "jet": ((252, 208, 10), (16, 48, 124), "JET"),
    "totalenergies": ((228, 30, 36), (255, 255, 255), "TOTAL"),
    "avia": ((212, 22, 32), (255, 255, 255), "AVIA"),
    "bft": ((18, 86, 152), (255, 255, 255), "bft"),
    "star": ((228, 28, 36), (255, 255, 255), "STAR"),
    "fuel_generic": ((24, 62, 118), (255, 255, 255), "TANKSTELLE"),
}


def render_fuel_pylon(
    brand_key: str,
    brand_label: str,
    e10: str,
    e5: str,
    diesel: str,
    w: int = SLOT_W,
    h: int = SLOT_H,
) -> Image.Image:
    """Render a German fuel-station price totem (`Preistafel`) into a 512x64 atlas slot."""
    bg_hdr, fg_hdr, def_lbl = FUEL_PYLON_PALETTES.get(brand_key, FUEL_PYLON_PALETTES["fuel_generic"])
    img = Image.new("RGB", (w, h), (22, 26, 32))
    draw = ImageDraw.Draw(img)

    # Top brand header bar
    hdr_h = 19
    draw.rectangle([2, 2, w - 3, hdr_h], fill=bg_hdr)
    lbl = " ".join(str(brand_label or def_lbl).split()) or def_lbl
    fitted, font_hdr, bx_h = _fit_text(draw, lbl, w - 24, hdr_h - 3, sizes=(16, 14, 12))
    tx = (w - (bx_h[2] - bx_h[0])) / 2.0 - bx_h[0]
    ty = 2 + (hdr_h - 2 - (bx_h[3] - bx_h[1])) / 2.0 - bx_h[1]
    draw.text((tx, ty), fitted, font=font_hdr, fill=fg_hdr)

    # 3 crisp LED fuel-price rows
    font_row = _load_font(12, condensed=True)
    font_price = _load_font(13, condensed=False)
    rows = (
        ("Super E10", str(e10), (255, 198, 48)),
        ("Super E5", str(e5), (255, 198, 48)),
        ("Diesel", str(diesel), (236, 240, 244)),
    )
    row_h = (h - hdr_h - 4) // 3
    for idx, (fuel_name, price_str, p_col) in enumerate(rows):
        ry0 = hdr_h + 2 + idx * row_h
        if idx > 0:
            draw.line([(8, ry0), (w - 9, ry0)], fill=(44, 50, 58), width=1)
        bx_f = draw.textbbox((0, 0), fuel_name, font=font_row)
        draw.text((16 - bx_f[0], ry0 + (row_h - (bx_f[3] - bx_f[1])) / 2.0 - bx_f[1]), fuel_name, font=font_row, fill=(210, 214, 220))
        bx_p = draw.textbbox((0, 0), price_str, font=font_price)
        draw.text((w - 16 - (bx_p[2] - bx_p[0]) - bx_p[0], ry0 + (row_h - (bx_p[3] - bx_p[1])) / 2.0 - bx_p[1]), price_str, font=font_price, fill=p_col)
    return img


def render_housenumber_grid(numbers: list[str], w: int = SLOT_W, h: int = SLOT_H) -> Image.Image:
    """Pack up to 4 German royal-blue/white enamel house number plaques (4x1 grid, 128x64 each) into one 512x64 slot."""
    img = Image.new("RGB", (w, h), (16, 48, 96))
    draw = ImageDraw.Draw(img)
    cell_w, cell_h = w // 4, h  # 128 x 64 (matches 0.42 m x 0.30 m plaque proportions cleanly)
    for col, num in enumerate(numbers[:4]):
        cx0, cy0 = col * cell_w, 0
        # Royal-blue German Hausnummer enamel with crisp white border.
        draw.rectangle([cx0 + 3, cy0 + 4, cx0 + cell_w - 4, cy0 + cell_h - 5], fill=(14, 54, 114), outline=(238, 240, 244), width=3)
        txt = str(num).strip()[:6]
        fitted, font, bx = _fit_text(draw, txt, cell_w - 18, cell_h - 14, sizes=(44, 38, 34, 30, 26, 22, 18))
        tw, th = bx[2] - bx[0], bx[3] - bx[1]
        draw.text((cx0 + (cell_w - tw) / 2.0 - bx[0], cy0 + (cell_h - th) / 2.0 - bx[1]), fitted, font=font, fill=(250, 250, 250))
    return img


def _atlas_dims(count: int) -> tuple[int, int, int]:
    """Return `(atlas_w, atlas_h, max_slots)` power-of-two dimensions for slot packing."""
    if count <= MAX_SLOTS_16:
        return ATLAS_W, 512, MAX_SLOTS_16
    if count <= MAX_SLOTS_32:
        return ATLAS_W, 1024, MAX_SLOTS_32
    return ATLAS_W, 2048, 64


def pack_atlas(
    entries: Iterable[tuple[str, object]],
    render_fn,
    out_dir: str | None,
    vfs_dir: str | None,
    prefix: str,
    skip_render_if_cached: bool = False,
) -> tuple[str | None, str | None, str | None, dict[str, tuple[float, float, float, float]], Image.Image | None]:
    """Pack unique items into one DXT1 DDS atlas and compute Collada UV rects.

    Args:
        entries: Iterable of `(cache_key, payload)` tuples passed to `render_fn(payload)`.
        render_fn: Callable returning a `SLOT_W x SLOT_H` RGB Pillow image.
        out_dir: Directory where `de_<prefix>_<hash>.dds` will be written (None skips disk IO).
        vfs_dir: BeamNG VFS directory corresponding to `out_dir`.
        prefix: Short tag (`"st"` for street signs, `"sh"` for shop fascias).

    Returns:
        `(mat_name, dds_disk_path, vfs_path, uv_map, pil_image)` where `uv_map[key]` gives
        `(u0, v0_dae, u1, v1_dae)` in Collada bottom-up V coordinates.
    """
    unique: list[tuple[str, object]] = []
    seen: set[str] = set()
    for key, payload in entries:
        if key in seen:
            continue
        seen.add(key)
        unique.append((key, payload))
        if len(unique) >= 64:
            break

    if not unique:
        return None, None, None, {}, None

    # Sort keys deterministically so identical tiles hash identically regardless of traversal order.
    unique.sort(key=lambda kv: kv[0])
    atlas_w, atlas_h, _ = _atlas_dims(len(unique))
    cols = atlas_w // SLOT_W

    digest_input = f"v1|{prefix}|{atlas_w}x{atlas_h}|" + "|".join(k for k, _ in unique)
    h = hashlib.blake2b(digest_input.encode("utf-8"), digest_size=6).hexdigest()
    mat_name = f"bne_de_{prefix}_{h}"
    filename = f"de_{prefix}_{h}.dds"

    disk_path = os.path.join(out_dir, filename) if out_dir else None
    vfs_path = f"{vfs_dir}/{filename}" if vfs_dir else None
    uv_map: dict[str, tuple[float, float, float, float]] = {}

    # Compute deterministic UVs up-front; if the exact hash-named DDS already exists on disk
    # and the caller doesn't need the PIL Image, skip all Pillow rendering and DDS compression.
    for idx, (key, _payload) in enumerate(unique):
        col = idx % cols
        row = idx // cols
        px0 = col * SLOT_W
        py0 = row * SLOT_H
        # Inset 3px inside the 4px padding margin to avoid bilinear bleed across slots;
        # convert top-down pixel Y into Collada bottom-up V (`v_dae = 1 - y / H`).
        u0 = (px0 + 3.0) / float(atlas_w)
        u1 = (px0 + SLOT_W - 3.0) / float(atlas_w)
        v_top_dae = 1.0 - (py0 + 3.0) / float(atlas_h)
        v_bot_dae = 1.0 - (py0 + SLOT_H - 3.0) / float(atlas_h)
        uv_map[key] = (u0, v_bot_dae, u1, v_top_dae)

    if skip_render_if_cached and disk_path and os.path.exists(disk_path):
        return mat_name, disk_path, vfs_path, uv_map, None

    atlas = Image.new("RGB", (atlas_w, atlas_h), (24, 30, 40))
    for idx, (_key, payload) in enumerate(unique):
        col = idx % cols
        row = idx // cols
        px0 = col * SLOT_W
        py0 = row * SLOT_H
        tile_img = render_fn(payload)
        if tile_img.size != (SLOT_W, SLOT_H):
            tile_img = tile_img.resize((SLOT_W, SLOT_H), Image.Resampling.LANCZOS)
        atlas.paste(tile_img, (px0, py0))

    if disk_path and not os.path.exists(disk_path):
        os.makedirs(out_dir, exist_ok=True)
        imagery.write_dds(disk_path, np.asarray(atlas, dtype=np.uint8))

    return mat_name, disk_path, vfs_path, uv_map, atlas
