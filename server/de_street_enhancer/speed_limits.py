"""German / OSM speed-limit normalization and urban road-chain propagation (`BNE_DE_STREET_IMMERSION`).

Normalizes explicit OSM country/zone speed tokens (`DE:urban`, `DE:rural`, `DE:motorway`,
`DE:living_street`, `walk`, `DE:30`/`DE:zone30`, `mph` conversion, numeric strings) and
propagates urban speed limits across short untagged intermediate segments inside urban/built-up
road chains so urban streets do not erroneously flick between 50 km/h and 100 km/h.
"""

from __future__ import annotations

import math
import re
from collections import deque

import numpy as np


MPH_TO_KMH = 1.609344
MIN_KMH = 5.0
MAX_KMH = 250.0
DE_RICHTGESCHWINDIGKEIT_KMH = 130.0

_TOKEN_KMH = {
    "de:urban": 50.0,
    "de:rural": 100.0,
    "de:motorway": 0.0,
    "de:living_street": 10.0,
    "de:walk": 10.0,
    "walk": 10.0,
    "de:zone30": 30.0,
    "de:zone:30": 30.0,
    "de:30": 30.0,
    "de:zone20": 20.0,
    "de:zone:20": 20.0,
    "de:20": 20.0,
    "de:zone10": 10.0,
    "de:zone:10": 10.0,
    "de:10": 10.0,
}

_DE_ZONE_RE = re.compile(r"^de:(?:zone:?)?(\d{1,3})$", re.IGNORECASE)
_NUM_UNIT_RE = re.compile(r"^\s*([0-9]+(?:\.[0-9]+)?)\s*(mph|km/h|kmh|kph)?\s*$", re.IGNORECASE)

_DE_RURAL_CLASSES = {"trunk", "primary", "secondary", "tertiary", "unclassified"}
_DE_URBAN_CLASSES = {"trunk", "primary", "secondary", "tertiary", "unclassified", "residential"}


def parse_maxspeed_kph(raw, country: str | None = None, cls: str | None = None, urban: bool = False) -> float | None:
    """Parse an OSM/Overture maxspeed value into km/h (`0.0` = unlimited, `None` = unknown).

    Handles explicit OSM tokens (`DE:urban` -> 50, `DE:rural` -> 100, `DE:motorway` / `none` -> 0,
    `DE:living_street` / `walk` -> 10, `DE:zone30` / `DE:30` -> 30), `mph` conversion, and numeric
    values. Invalid or out-of-range values return `None`.
    """
    if raw is None:
        return None
    if isinstance(raw, (bool, np.bool_)):
        return None
    if isinstance(raw, (int, float, np.integer, np.floating)):
        v = float(raw)
        if not math.isfinite(v):
            return None
        if v == 0.0:
            return 0.0
        return v if MIN_KMH <= v <= MAX_KMH else None

    s = str(raw).strip()
    if not s:
        return None
    low = s.lower()
    if low in ("nan", "null", "unknown", "signals", "variable", "implicit"):
        return None
    if low == "none":
        if cls == "motorway" or str(country or "").upper() == "DE":
            return 0.0
        return None
    if low in _TOKEN_KMH:
        return _TOKEN_KMH[low]
    m_z = _DE_ZONE_RE.match(low)
    if m_z:
        zv = float(int(m_z.group(1)))
        return zv if MIN_KMH <= zv <= MAX_KMH else None

    m = _NUM_UNIT_RE.match(s)
    if not m:
        return None
    try:
        val = float(m.group(1))
    except ValueError:
        return None
    if not math.isfinite(val):
        return None
    unit = (m.group(2) or "").lower()
    if unit == "mph":
        val = round(val * MPH_TO_KMH, 1)
    if val == 0.0:
        return 0.0
    return val if MIN_KMH <= val <= MAX_KMH else None


def de_default_kph(cls: str | None, urban: bool = False) -> float:
    """Statutory German (StVO § 3) default speed limit in km/h (`0.0` = unlimited Autobahn)."""
    c = str(cls or "").removesuffix("_link")
    if c == "motorway":
        return 0.0
    if c == "living_street":
        return 10.0
    if c == "service":
        return 20.0
    if urban:
        return 50.0
    if c in _DE_RURAL_CLASSES:
        return 100.0
    if c == "residential":
        return 50.0
    return 50.0


def _feature_length_m(feats, i: int) -> float:
    a = int(feats.coord_off[feats.ring_off[feats.part_off[i]]])
    b = int(feats.coord_off[feats.ring_off[feats.part_off[i + 1]]])
    if b - a < 2:
        return 0.0
    ll = np.asarray(feats.lonlat[a:b], dtype=np.float64)
    lat0 = float(np.mean(ll[:, 1]))
    kx = 111320.0 * max(0.2, math.cos(math.radians(lat0)))
    dx = np.diff(ll[:, 0]) * kx
    dy = np.diff(ll[:, 1]) * 110540.0
    return float(np.sum(np.hypot(dx, dy)))


def _explicit_feature_kmh(feats, i: int, spec, at: float = 0.5, country: str | None = None) -> float | None:
    """Return explicit mapped limit (km/h, `0.0` = unlimited) for feature `i`, or `None` if untagged."""
    speed = feats.rules.get("max_speed_kmh") if hasattr(feats, "rules") else None
    if speed is not None:
        for r in speed.rows(i):
            if speed.start[r] <= at <= speed.end[r]:
                v = parse_maxspeed_kph(speed.value[r], country=country, cls=getattr(spec, "cls", None), urban=bool(getattr(spec, "urban", False)))
                if v is not None:
                    return v
    attrs = getattr(feats, "attrs", {}) or {}
    osm_ms = attrs.get("osm_maxspeed")
    if osm_ms is not None and i < len(osm_ms):
        v = parse_maxspeed_kph(osm_ms[i], country=country, cls=getattr(spec, "cls", None), urban=bool(getattr(spec, "urban", False)))
        if v is not None:
            return v
    zone = attrs.get("osm_zone_maxspeed")
    if zone is not None and i < len(zone) and zone[i] is not None:
        v = parse_maxspeed_kph(zone[i], country=country, cls=getattr(spec, "cls", None), urban=bool(getattr(spec, "urban", False)))
        if v is not None:
            return v
    if spec is not None and getattr(spec, "kmh", None) is not None:
        v = parse_maxspeed_kph(spec.kmh, country=country, cls=getattr(spec, "cls", None), urban=bool(getattr(spec, "urban", False)))
        if v is not None:
            return v
    return None


def propagate_urban_limits(
    feats,
    specs: list,
    max_gap_m: float = 250.0,
    max_hops: int = 3,
    country: str | None = "DE",
) -> dict[int, float]:
    """Propagate urban speed limits across short untagged intermediate road segments.

    Prevents urban/built-up road chains (e.g., 50 km/h arterial or 30 km/h zone) from flickering
    to 100 km/h over a short untagged bridge, junction, or park-side segment (`<= max_gap_m` and
    `<= max_hops` hops between flanking urban-limit segments).
    """
    if feats is None or not specs:
        return {}
    n = min(len(feats), len(specs))
    if n < 2:
        return {}

    attrs = getattr(feats, "attrs", {}) or {}
    names_col = attrs.get("name")
    con = feats.rules.get("connectors") if hasattr(feats, "rules") else None

    explicit: dict[int, float] = {}
    lengths: dict[int, float] = {}
    con_to_feats: dict[str, list[int]] = {}
    feat_cons: dict[int, list[str]] = {}
    end_buckets: dict[tuple[int, int], list[int]] = {}

    for i in range(n):
        sp = specs[i]
        if sp is None or getattr(sp, "cls", None) == "motorway":
            continue
        lengths[i] = _feature_length_m(feats, i)
        ex = _explicit_feature_kmh(feats, i, sp, country=country)
        if ex is not None:
            explicit[i] = ex
        if con is not None:
            cids = [str(con.value[r]) for r in con.rows(i)]
            if cids:
                feat_cons[i] = cids
                for cid in cids:
                    con_to_feats.setdefault(cid, []).append(i)
        # Endpoint spatial fallback (~3 m grid) when connector rules are absent in synthetic tests
        a = int(feats.coord_off[feats.ring_off[feats.part_off[i]]])
        b = int(feats.coord_off[feats.ring_off[feats.part_off[i + 1]]])
        if b - a >= 2:
            for idx_pt in (a, b - 1):
                lon, lat = float(feats.lonlat[idx_pt, 0]), float(feats.lonlat[idx_pt, 1])
                bk = (int(round(lon * 30000.0)), int(round(lat * 30000.0)))
                end_buckets.setdefault(bk, []).append(i)

    def _name_of(i: int) -> str:
        if names_col is None or i >= len(names_col) or names_col[i] is None:
            return ""
        s = str(names_col[i]).strip()
        return "" if s in ("", "None", "nan") else s

    adj: dict[int, set[int]] = {}
    for group in con_to_feats.values():
        if len(group) < 2:
            continue
        for u in group:
            s_u = adj.setdefault(u, set())
            for v in group:
                if v != u:
                    s_u.add(v)
    if not con_to_feats:
        for group in end_buckets.values():
            if len(group) < 2:
                continue
            for u in group:
                s_u = adj.setdefault(u, set())
                for v in group:
                    if v != u:
                        s_u.add(v)

    propagated: dict[int, float] = {}
    for i in range(n):
        sp = specs[i]
        if sp is None or i in explicit or getattr(sp, "cls", None) not in _DE_URBAN_CLASSES:
            continue
        if lengths.get(i, 0.0) > max_gap_m:
            continue
        my_name = _name_of(i)
        # BFS through untagged short segments up to max_hops to collect flanking urban limits.
        flank_limits: list[float] = []
        urban_neighbors = 0
        q: deque[tuple[int, int, float]] = deque([(i, 0, lengths.get(i, 0.0))])
        visited = {i}
        while q:
            cur, hops, dist_m = q.popleft()
            for nb in adj.get(cur, ()):
                if nb in visited:
                    continue
                sp_nb = specs[nb]
                if sp_nb is None or getattr(sp_nb, "cls", None) == "motorway":
                    continue
                nb_name = _name_of(nb)
                same_corridor = (
                    (my_name != "" and nb_name == my_name)
                    or (getattr(sp_nb, "cls", None) == getattr(sp, "cls", None))
                )
                if not same_corridor:
                    continue
                visited.add(nb)
                if nb in explicit:
                    lim = explicit[nb]
                    if 0.0 < lim <= 60.0:
                        flank_limits.append(lim)
                        if getattr(sp_nb, "urban", False) or lim <= 50.0:
                            urban_neighbors += 1
                    continue
                if getattr(sp_nb, "urban", False):
                    urban_neighbors += 1
                    flank_limits.append(50.0)
                    continue
                nb_len = lengths.get(nb, 0.0)
                if hops + 1 < max_hops and dist_m + nb_len <= max_gap_m:
                    q.append((nb, hops + 1, dist_m + nb_len))

        # Propagate when flanked on both sides (>= 2 urban/tagged <=60 neighbors) or already urban with 1 tagged neighbor
        if len(flank_limits) >= 2 or (getattr(sp, "urban", False) and len(flank_limits) == 1):
            propagated[i] = min(flank_limits)
        elif urban_neighbors >= 2:
            propagated[i] = 50.0

    return propagated


def resolve_feature_limit_kph(
    feats,
    i: int,
    spec,
    at: float = 0.5,
    country: str | None = None,
    propagated: dict[int, float] | None = None,
) -> float | None:
    """Resolve the active speed limit (km/h, `0.0` = unlimited) for road feature `i`."""
    if spec is None:
        return None
    ex = _explicit_feature_kmh(feats, i, spec, at=at, country=country)
    if ex is not None:
        return ex
    if propagated is not None and i in propagated:
        return float(propagated[i])
    if str(country or "").upper() == "DE":
        return de_default_kph(getattr(spec, "cls", None), bool(getattr(spec, "urban", False)))
    return None
