"""Curated German retail/service brand registry for commercial shopfront fascias."""

from dataclasses import dataclass
import functools
import math
import re


ALDI_BORDER_LAT = 51.55  # Approximate Aldi-Äquator separating ALDI Nord and ALDI Süd


@dataclass(frozen=True)
class BrandSpec:
    """Visual specification and matching rules for a German storefront brand."""

    key: str
    title: str
    bg_rgb: tuple[int, int, int]
    fg_rgb: tuple[int, int, int]
    accent_rgb: tuple[int, int, int] | None
    border_rgb: tuple[int, int, int] | None
    emblem: str
    wikidata: str | None
    aliases: tuple[str, ...]
    categories: tuple[str, ...]
    weight: float = 1.0
    emissive_nits: float = 35.0
    north_south: str = "all"  # "all" | "north" | "south"


BRANDS: tuple[BrandSpec, ...] = (
    BrandSpec(
        key="rewe",
        title="REWE",
        bg_rgb=(204, 7, 30),
        fg_rgb=(255, 255, 255),
        accent_rgb=(255, 255, 255),
        border_rgb=(150, 5, 20),
        emblem="rewe_bar",
        wikidata="Q16968817",
        aliases=("rewe", "rewe city", "rewe center", "rewe to go"),
        categories=("supermarket", "grocery", "convenience_store", "retail"),
        weight=1.6,
    ),
    BrandSpec(
        key="edeka",
        title="EDEKA",
        bg_rgb=(255, 237, 0),
        fg_rgb=(0, 59, 126),
        accent_rgb=(0, 59, 126),
        border_rgb=(0, 59, 126),
        emblem="edeka_e",
        wikidata="Q701755",
        aliases=("edeka", "e center", "edeka aktiv markt", "nah & gut"),
        categories=("supermarket", "grocery", "retail"),
        weight=1.5,
    ),
    BrandSpec(
        key="aldi_sued",
        title="ALDI SÜD",
        bg_rgb=(0, 48, 122),
        fg_rgb=(255, 255, 255),
        accent_rgb=(242, 133, 0),
        border_rgb=(242, 133, 0),
        emblem="aldi_a",
        wikidata="Q41171672",
        aliases=("aldi sued", "aldi süd", "aldi"),
        categories=("supermarket", "discount_store", "grocery"),
        weight=1.1,
        north_south="south",
    ),
    BrandSpec(
        key="aldi_nord",
        title="ALDI",
        bg_rgb=(0, 120, 193),
        fg_rgb=(255, 255, 255),
        accent_rgb=(0, 42, 92),
        border_rgb=(255, 255, 255),
        emblem="aldi_a",
        wikidata="Q41171373",
        aliases=("aldi nord", "aldi"),
        categories=("supermarket", "discount_store", "grocery"),
        weight=1.1,
        north_south="north",
    ),
    BrandSpec(
        key="lidl",
        title="Lidl",
        bg_rgb=(0, 80, 170),
        fg_rgb=(255, 240, 0),
        accent_rgb=(227, 6, 19),
        border_rgb=(255, 240, 0),
        emblem="lidl_disc",
        wikidata="Q151954",
        aliases=("lidl",),
        categories=("supermarket", "discount_store", "grocery"),
        weight=1.1,
    ),
    BrandSpec(
        key="penny",
        title="PENNY",
        bg_rgb=(206, 17, 38),
        fg_rgb=(255, 224, 0),
        accent_rgb=(255, 255, 255),
        border_rgb=(255, 224, 0),
        emblem="penny_dot",
        wikidata="Q284688",
        aliases=("penny", "penny markt"),
        categories=("supermarket", "discount_store"),
        weight=0.8,
    ),
    BrandSpec(
        key="netto",
        title="Netto",
        bg_rgb=(255, 213, 0),
        fg_rgb=(206, 17, 38),
        accent_rgb=(20, 20, 20),
        border_rgb=(20, 20, 20),
        emblem="netto_ribbon",
        wikidata="Q879858",
        aliases=("netto", "netto marken-discount", "netto city"),
        categories=("supermarket", "discount_store"),
        weight=0.9,
    ),
    BrandSpec(
        key="kaufland",
        title="Kaufland",
        bg_rgb=(246, 246, 246),
        fg_rgb=(227, 6, 19),
        accent_rgb=(227, 6, 19),
        border_rgb=(227, 6, 19),
        emblem="kaufland_sq",
        wikidata="Q685967",
        aliases=("kaufland",),
        categories=("supermarket", "department_store"),
        weight=0.6,
    ),
    BrandSpec(
        key="dm",
        title="dm",
        bg_rgb=(248, 249, 250),
        fg_rgb=(0, 38, 100),
        accent_rgb=(209, 0, 116),
        border_rgb=(0, 38, 100),
        emblem="dm_wave",
        wikidata="Q266572",
        aliases=("dm", "dm-drogerie markt", "dm drogerie"),
        categories=("drugstore", "pharmacy", "cosmetics"),
        weight=1.0,
    ),
    BrandSpec(
        key="rossmann",
        title="ROSSMANN",
        bg_rgb=(250, 248, 248),
        fg_rgb=(200, 16, 46),
        accent_rgb=(200, 16, 46),
        border_rgb=(200, 16, 46),
        emblem="rossmann_dot",
        wikidata="Q316004",
        aliases=("rossmann", "dirk rossmann"),
        categories=("drugstore", "cosmetics"),
        weight=0.9,
    ),
    BrandSpec(
        key="apotheke",
        title="Apotheke",
        bg_rgb=(250, 250, 248),
        fg_rgb=(227, 6, 19),
        accent_rgb=(255, 255, 255),
        border_rgb=(227, 6, 19),
        emblem="apotheke_a",
        wikidata=None,
        aliases=("apotheke", "stadt-apotheke", "löwen-apotheke", "adler-apotheke", "rats-apotheke"),
        categories=("pharmacy", "chemist", "medical"),
        weight=1.5,
    ),
    BrandSpec(
        key="sparkasse",
        title="Sparkasse",
        bg_rgb=(255, 0, 0),
        fg_rgb=(255, 255, 255),
        accent_rgb=(255, 255, 255),
        border_rgb=(180, 0, 0),
        emblem="sparkasse_s",
        wikidata="Q13601825",
        aliases=("sparkasse", "kreissparkasse", "stadtsparkasse", "haspa"),
        categories=("bank", "atm", "financial_service"),
        weight=1.3,
    ),
    BrandSpec(
        key="volksbank",
        title="Volksbank",
        bg_rgb=(0, 56, 131),
        fg_rgb=(255, 255, 255),
        accent_rgb=(236, 102, 8),
        border_rgb=(236, 102, 8),
        emblem="vr_v",
        wikidata="Q2534301",
        aliases=("volksbank", "raiffeisenbank", "vr bank", "vr-bank", "sparda-bank"),
        categories=("bank", "financial_service"),
        weight=0.9,
    ),
    BrandSpec(
        key="post_dhl",
        title="DHL Paketshop",
        bg_rgb=(255, 204, 0),
        fg_rgb=(15, 15, 15),
        accent_rgb=(212, 5, 17),
        border_rgb=(212, 5, 17),
        emblem="post_horn",
        wikidata="Q489815",
        aliases=("dhl", "deutsche post", "postbank", "paketshop"),
        categories=("post_office", "courier"),
        weight=0.8,
    ),
    BrandSpec(
        key="baeckerei",
        title="Bäckerei",
        bg_rgb=(74, 42, 22),
        fg_rgb=(252, 240, 212),
        accent_rgb=(218, 165, 32),
        border_rgb=(218, 165, 32),
        emblem="pretzel",
        wikidata=None,
        aliases=("bäckerei", "baeckerei", "bäcker", "konditorei", "ihle", "höreder", "wimmer"),
        categories=("bakery", "pastry_shop", "cafe"),
        weight=1.9,
    ),
    BrandSpec(
        key="backwerk",
        title="BackWerk",
        bg_rgb=(48, 30, 18),
        fg_rgb=(255, 238, 195),
        accent_rgb=(215, 65, 25),
        border_rgb=(215, 65, 25),
        emblem="pretzel",
        wikidata="Q798338",
        aliases=("backwerk", "back-factory"),
        categories=("bakery", "cafe", "fast_food"),
        weight=0.6,
    ),
    BrandSpec(
        key="kamps",
        title="Kamps",
        bg_rgb=(90, 20, 32),
        fg_rgb=(255, 245, 225),
        accent_rgb=(212, 175, 55),
        border_rgb=(212, 175, 55),
        emblem="pretzel",
        wikidata="Q1723476",
        aliases=("kamps", "ditsch"),
        categories=("bakery",),
        weight=0.6,
    ),
    BrandSpec(
        key="doener",
        title="Döner & Imbiss",
        bg_rgb=(28, 72, 42),
        fg_rgb=(255, 248, 225),
        accent_rgb=(218, 165, 32),
        border_rgb=(218, 165, 32),
        emblem="flame_badge",
        wikidata=None,
        aliases=("döner", "kebab", "kebap", "imbiss", "bistro"),
        categories=("fast_food", "kebab_shop", "restaurant"),
        weight=1.3,
    ),
    BrandSpec(
        key="obi",
        title="OBI",
        bg_rgb=(238, 114, 3),
        fg_rgb=(255, 255, 255),
        accent_rgb=(40, 40, 40),
        border_rgb=(40, 40, 40),
        emblem="none",
        wikidata="Q300518",
        aliases=("obi", "bauhaus", "toom", "hornbach", "hagebau"),
        categories=("hardware_store", "home_improvement", "garden_center"),
        weight=0.5,
    ),
    BrandSpec(
        key="local_shop",
        title="Fachgeschäft",
        bg_rgb=(36, 44, 58),
        fg_rgb=(248, 244, 232),
        accent_rgb=(210, 175, 105),
        border_rgb=(210, 175, 105),
        emblem="none",
        wikidata=None,
        aliases=(),
        categories=("shop", "retail", "commercial", "boutique", "hair_salon", "optician"),
        weight=0.8,
    ),
)

BY_KEY: dict[str, BrandSpec] = {b.key: b for b in BRANDS}
BY_WIKIDATA: dict[str, BrandSpec] = {b.wikidata: b for b in BRANDS if b.wikidata}
_CAT_TO_BRAND: dict[str, BrandSpec] = {}
for _b in BRANDS:
    for _c in _b.categories:
        _CAT_TO_BRAND.setdefault(_c, _b)

_TOKEN_RE = re.compile(r"[^\w]+", re.UNICODE)


def _regional_aldi_flag(is_north: bool) -> BrandSpec:
    return BY_KEY["aldi_nord"] if is_north else BY_KEY["aldi_sued"]


def _regional_aldi(lat: float | None) -> BrandSpec:
    return _regional_aldi_flag(lat is not None and lat >= ALDI_BORDER_LAT)


def normalize_label(text: str, max_len: int = 24) -> str:
    """Trim whitespace and shorten overly long commercial POI names cleanly."""
    clean = " ".join(str(text or "").split())
    if len(clean) <= max_len:
        return clean
    return clean[: max_len - 1].rstrip(" -/") + "."


@functools.lru_cache(maxsize=2048)
def _match_poi_cached(
    qid: str,
    raw_brand: str,
    raw_name: str,
    cat: str,
    is_north: bool,
) -> tuple[BrandSpec | None, str]:
    if qid in BY_WIKIDATA:
        spec = BY_WIKIDATA[qid]
        if spec.key in ("aldi_sued", "aldi_nord"):
            spec = _regional_aldi_flag(is_north)
        return spec, spec.title

    joined = f"{raw_brand} {raw_name}".strip().lower()
    if joined:
        if "aldi" in joined:
            if "nord" in joined:
                return BY_KEY["aldi_nord"], BY_KEY["aldi_nord"].title
            if "süd" in joined or "sued" in joined:
                return BY_KEY["aldi_sued"], BY_KEY["aldi_sued"].title
            spec = _regional_aldi_flag(is_north)
            return spec, spec.title

        for spec in BRANDS:
            for alias in spec.aliases:
                if alias in joined:
                    label = normalize_label(raw_name) if (raw_name and spec.key in ("apotheke", "baeckerei")) else spec.title
                    return spec, label

    if cat:
        spec = _CAT_TO_BRAND.get(cat)
        if spec is not None:
            label = normalize_label(raw_name or raw_brand) if (raw_name or raw_brand) else spec.title
            return spec, label

    if raw_name:
        return BY_KEY["local_shop"], normalize_label(raw_name)
    return None, ""


def match_poi(
    brand_wikidata: str | None,
    brand_name: str | None,
    name: str | None,
    category: str | None,
    lat: float | None = None,
) -> tuple[BrandSpec | None, str]:
    """Resolve an Overture `places` POI onto a curated `BrandSpec` and display text."""
    qid = str(brand_wikidata or "").strip().upper()
    raw_brand = " ".join(str(brand_name or "").split())
    raw_name = " ".join(str(name or "").split())
    cat = str(category or "").strip().lower()
    is_north = (lat is not None and lat >= ALDI_BORDER_LAT)
    return _match_poi_cached(qid, raw_brand, raw_name, cat, is_north)


LOCAL_INDEPENDENT_SHOPS: tuple[tuple[str, str], ...] = (
    ("baeckerei", "Bäckerei"),
    ("local_shop", "Metzgerei"),
    ("local_shop", "Friseur"),
    ("local_shop", "Blumen"),
    ("local_shop", "Buchhandlung"),
    ("local_shop", "Optiker"),
    ("local_shop", "Eiscafé"),
    ("local_shop", "Kiosk"),
    ("local_shop", "Schneider"),
    ("local_shop", "Schuhhaus"),
    ("local_shop", "Weinhandlung"),
    ("local_shop", "Uhren & Schmuck"),
)


def fallback_brand(seed: float, lat: float | None, cls: str = "", local_seed: float | None = None) -> tuple[BrandSpec, str]:
    """Deterministically select an authentic regional German brand or local storefront for an unnamed facade."""
    low_cls = (cls or "").lower()
    if low_cls == "supermarket":
        pool = [BY_KEY["rewe"], BY_KEY["edeka"], _regional_aldi(lat), BY_KEY["lidl"], BY_KEY["penny"], BY_KEY["netto"]]
    elif low_cls in ("restaurant", "cafe", "fast_food"):
        pool = [BY_KEY["baeckerei"], BY_KEY["backwerk"], BY_KEY["kamps"], BY_KEY["doener"]]
    else:
        ls = float(seed if local_seed is None else local_seed)
        if ls < 0.42:
            idx = int(max(0.0, min(0.999999, ls / 0.42)) * len(LOCAL_INDEPENDENT_SHOPS))
            b_key, b_lbl = LOCAL_INDEPENDENT_SHOPS[idx]
            return BY_KEY[b_key], b_lbl
        pool = [
            b
            for b in BRANDS
            if b.key != "local_shop"
            and (b.north_south == "all" or (b.north_south == ("north" if lat is not None and lat >= ALDI_BORDER_LAT else "south")))
        ]

    total = math.fsum(b.weight for b in pool)
    target = max(0.0, min(0.999999, float(seed))) * total
    acc = 0.0
    for b in pool:
        acc += b.weight
        if target <= acc:
            return b, b.title
    return pool[-1], pool[-1].title
