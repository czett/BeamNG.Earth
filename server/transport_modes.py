"""Global, deterministic Transport Modes (Taxi, Bus, Logistics) job and route-stop generation.

Generates multi-stop transport jobs anywhere on Earth using:
  - Overture z14 MapData cells (roads, places, buildings, land_use, infrastructure)
  - Natural Earth populated places (randomplace.towns()) for zero-network regional/long-haul hubs
  - Bounded single-shot Overpass queries for OSM route=bus relations (with TTL cache and deterministic local fallback)

All coordinates are snapped onto drivable ground roads (excluding footway/cycleway/pedestrian/steps/path/service-only
and bridges/tunnels via roads.ground_parts) so the client GPS and kerbside zone markers always sit on valid roads.
"""
import hashlib
import json
import logging
import math
import threading
import time
import urllib.parse

import numpy as np

import dmath
import mapcells
import netfetch
import randomplace
import roads as roadsmod

log = logging.getLogger("earthd.transport")

M_LAT = 111320.0
DEADLINE_S = 1.6
END_CLEAR_M = 20.0
OVERPASS_URL = "https://overpass-api.de/api/interpreter"
OVERPASS_CACHE_S = 3600.0
OVERPASS_FAIL_COOLDOWN_S = 65.0
OVERPASS_MAX_CACHE = 64

DRIVABLE_CLASSES = frozenset({
    "trunk", "primary", "secondary", "tertiary", "unclassified", "residential", "living_street", "unknown",
})
LOGISTICS_FALLBACK_CLASSES = DRIVABLE_CLASSES | frozenset({"service"})
SKIP_SUBCLASSES = frozenset({"driveway", "parking_aisle", "sidewalk", "crosswalk", "cycle_crossing", "alley"})

MODES = ("taxi", "bus", "logistics")
TIERS = {
    "taxi": {
        "neighborhood": {"min_km": 1.0, "max_km": 3.0, "label": "Neighborhood (1-3 km)"},
        "city": {"min_km": 4.0, "max_km": 12.0, "label": "City (4-12 km)"},
        "regional": {"min_km": 20.0, "max_km": 60.0, "label": "Regional (20-60 km)"},
    },
    "bus": {
        "partial": {"min_stops": 4, "max_stops": 6, "label": "Partial Route (4-6 stops)"},
        "full": {"min_stops": 6, "max_stops": 60, "label": "Full Line (complete OSM route=bus)"},
    },
    "logistics": {
        "local": {"target_km": 3.0, "min_stops": 3, "max_stops": 4, "label": "Local Van (3 km, 3-4 stops)"},
        "city": {"target_km": 10.0, "min_stops": 5, "max_stops": 8, "label": "City Delivery (10 km, 5-8 stops)"},
        "regional": {"target_km": 50.0, "min_stops": 2, "max_stops": 3, "label": "Regional Haul (50 km, 2-3 stops)"},
        "long": {"target_km": 115.0, "min_stops": 2, "max_stops": 2, "label": "Long Haul (100 km+)"},
    },
}

TAXI_PLACE_CATS = frozenset({
    "train_station", "subway_station", "bus_station", "light_rail_station", "metro_station", "ferry_terminal",
    "airport", "hotel", "lodging", "resort", "motel", "hostel", "restaurant", "cafe", "coffee_shop", "bar", "pub",
    "museum", "cinema", "movie_theater", "theatre", "theater", "hospital", "supermarket", "shopping_mall",
    "department_store", "university", "college_university", "park", "stadium", "landmark", "tourist_attraction",
})
LOGISTICS_RETAIL_EXACT = frozenset({
    "supermarket", "grocery_store", "convenience_store", "pharmacy", "department_store", "hardware_store",
    "shopping_mall", "shopping", "market", "farmers_market", "restaurant", "fast_food_restaurant",
    "casual_eatery", "cafe", "coffee_shop", "bakery", "deli", "post_office", "warehouse", "wholesale",
    "wholesale_store", "building_supply_store", "furniture_store", "electronics_store", "auto_parts_store",
})
LOGISTICS_RETAIL_SUFFIX = ("_store", "_shop", "_market", "_restaurant", "_depot")
LOGISTICS_HUB_CLASSES = frozenset({"industrial", "warehouse", "manufacture", "factory", "depot", "storage", "hangar"})
LOGISTICS_COMMERCIAL_CLASSES = frozenset({"commercial", "retail", "office", "supermarket", "mall"})
LOGISTICS_HUB_CATS = frozenset({
    "warehouse", "wholesale", "wholesale_store", "freight_forwarding_service", "logistics_service",
    "shipping_and_mailing_service", "courier_service", "distribution_service", "factory", "industrial_facility",
    "building_supply_store", "supermarket", "department_store", "shopping_mall", "post_office",
})

_bus_cache_lock = threading.Lock()
_bus_cache = {}


def _cos_lat(lat):
    return max(dmath.cos(math.radians(float(lat))), 0.05)


def dist_m(lat1, lon1, lat2, lon2):
    """Great-circle distance in metres between two WGS84 points."""
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp = p2 - p1
    dl = math.radians(lon2 - lon1)
    a = dmath.sin(dp / 2.0) ** 2 + dmath.cos(p1) * dmath.cos(p2) * dmath.sin(dl / 2.0) ** 2
    return 2.0 * 6371008.8 * math.atan2(math.sqrt(a), math.sqrt(max(0.0, 1.0 - a)))


def bearing_deg(lat1, lon1, lat2, lon2):
    """Compass bearing (0 = north, 90 = east) from point 1 to point 2."""
    k = _cos_lat((lat1 + lat2) * 0.5)
    dx = (lon2 - lon1) * M_LAT * k
    dy = (lat2 - lat1) * M_LAT
    if abs(dx) < 1e-9 and abs(dy) < 1e-9:
        return 0.0
    return (math.degrees(math.atan2(dx, dy)) + 360.0) % 360.0


def offset_latlon(lat, lon, distance_m, bearing):
    """Point offset distance_m along compass bearing (degrees clockwise from north)."""
    rad = math.radians(float(bearing))
    dlat = distance_m * dmath.cos(rad) / M_LAT
    dlon = distance_m * dmath.sin(rad) / (M_LAT * _cos_lat(lat))
    nlat = max(-85.0, min(85.0, lat + dlat))
    nlon = ((lon + dlon + 180.0) % 360.0) - 180.0
    return nlat, nlon


def _heading_diff(b1, b2):
    d = abs((float(b1) - float(b2) + 180.0) % 360.0 - 180.0)
    return d


def _stable_index(seed, key, n):
    if n <= 1:
        return 0
    h = hashlib.sha256(f"{seed}:{key}".encode("utf-8")).digest()
    return int.from_bytes(h[:8], "big") % n


def _clean(text):
    return " ".join(str(text or "").split()).strip()


def validate_request(msg):
    """Validate incoming transport_job dict -> (cleaned_dict, None) or (None, error_str)."""
    if not isinstance(msg, dict):
        return None, "invalid request"
    mode = str(msg.get("mode") or "").strip().lower()
    if mode not in TIERS:
        return None, f"unknown mode {mode!r}"
    tier = str(msg.get("tier") or "").strip().lower()
    if tier not in TIERS[mode]:
        return None, f"unknown tier {tier!r} for {mode}"
    try:
        lat, lon = float(msg["lat"]), float(msg["lon"])
    except (KeyError, TypeError, ValueError):
        return None, "missing or invalid lat/lon"
    if not (math.isfinite(lat) and math.isfinite(lon) and -90.0 <= lat <= 90.0 and -180.0 <= lon <= 180.0):
        return None, "lat/lon out of range"
    heading = msg.get("heading")
    if heading is not None:
        try:
            heading = float(heading)
            if not math.isfinite(heading):
                heading = None
            else:
                heading = heading % 360.0
        except (TypeError, ValueError):
            heading = None
    seed = msg.get("seed", 0)
    try:
        seed = int(seed) if seed is not None else 0
    except (TypeError, ValueError):
        seed = 0
    return {"mode": mode, "tier": tier, "lat": lat, "lon": lon, "heading": heading, "seed": seed}, None


# --------------------------------------------------------------------------- MapData cell helpers

def _cells_around(lat, lon, radius_m, max_cells=16):
    k = _cos_lat(lat)
    dlat = radius_m / M_LAT
    dlon = radius_m / (M_LAT * k)
    keys = list(mapcells.cells_for_bbox(lat - dlat, lon - dlon, lat + dlat, lon + dlon, max_cells=max(64, max_cells * 4)))
    if len(keys) <= max_cells:
        return keys
    # Sort closest to (lat, lon) first using cell center approximation
    home = mapcells.cell_of(lat, lon)
    keys.sort(key=lambda c: (c[1] - home[1]) ** 2 + (c[2] - home[2]) ** 2)
    return keys[:max_cells]


def _cell_layer(md, key, layer, deadline):
    if md is None:
        return None
    if not md.has(key, layer) and time.monotonic() > deadline:
        return None
    try:
        return md.cell(key, layers=(layer,), kind="demand").layers.get(layer)
    except Exception as e:
        log.debug("transport cell %s/%s: %s: %s", key, layer, type(e).__name__, e)
        return None


def _col(attrs, name, n):
    v = attrs.get(name) if attrs else None
    return v if v is not None else [""] * n


def _tags_dict(attrs, i):
    tags = attrs.get("tags") if attrs else None
    if tags is None:
        return {}
    raw = tags[i]
    if isinstance(raw, dict):
        return {str(k).lower(): str(v).lower() for k, v in raw.items()}
    try:
        parsed = json.loads(str(raw))
        if isinstance(parsed, dict):
            return {str(k).lower(): str(v).lower() for k, v in parsed.items()}
    except (TypeError, ValueError):
        pass
    return {}


def _feature_center(feats, i):
    attrs = getattr(feats, "attrs", {}) or {}
    cx, cy = attrs.get("cx"), attrs.get("cy")
    if cx is not None and cy is not None:
        try:
            la, lo = float(cy[i]), float(cx[i])
            if math.isfinite(la) and math.isfinite(lo):
                return la, lo
        except (TypeError, ValueError, IndexError):
            pass
    parts = feats.parts(i) if hasattr(feats, "parts") else None
    if parts and parts[0] and len(parts[0][0]) >= 1:
        ring = np.asarray(parts[0][0], np.float64)
        return float(ring[:, 1].mean()), float(ring[:, 0].mean())
    return None


def _road_subclass(feats, i):
    attrs = getattr(feats, "attrs", {}) or {}
    sc = attrs.get("subclass")
    if sc is not None:
        val = str(sc[i] or "").strip().lower()
        if val:
            return val
    rules = getattr(feats, "rules", None) or {}
    tbl = rules.get("subclass")
    if tbl is not None and len(getattr(tbl, "feature", ())) > 0:
        try:
            j = tbl.major(i)
            if j >= 0:
                return str(tbl.value[j] or "").strip().lower()
        except Exception:
            pass
    return ""


def _ground_rings(feats, i):
    if hasattr(roadsmod, "quick_ground_parts"):
        try:
            return roadsmod.quick_ground_parts(feats, i)
        except Exception:
            pass
    if hasattr(roadsmod, "ground_parts"):
        try:
            return roadsmod.ground_parts(feats, i)
        except Exception:
            pass
    return [ring for part in feats.parts(i) for ring in part if len(ring) >= 2]


def _seg_nearest(xy, p):
    a, b = xy[:-1], xy[1:]
    ab = b - a
    L2 = np.maximum((ab * ab).sum(1), 1e-12)
    t = np.clip(((p - a) * ab).sum(1) / L2, 0.0, 1.0)
    d = dnp_hypot(*(a + t[:, None] * ab - p).T)
    k = int(d.argmin())
    return float(d[k]), k, float(t[k])


def dnp_hypot(x, y):
    return np.hypot(x, y)


def snap_to_road(md, lat, lon, radius_m=350.0, classes=DRIVABLE_CLASSES, deadline=None, road_cells=None):
    """Snap (lat, lon) onto the nearest drivable ground road segment within radius_m.

    Returns dict {lat, lon, road, roadClass, bearing, snapDistM} or None.
    """
    if deadline is None:
        deadline = time.monotonic() + DEADLINE_S
    if road_cells is None:
        keys = _cells_around(lat, lon, radius_m, max_cells=9)
        road_cells = [_cell_layer(md, key, "roads", deadline) for key in keys]

    k = _cos_lat(lat)
    best = None
    for f in road_cells:
        if f is None or not len(f.ids):
            continue
        attrs = getattr(f, "attrs", {}) or {}
        cls_col = _col(attrs, "class", len(f.ids))
        name_col = _col(attrs, "name", len(f.ids))
        sub_col = _col(attrs, "subtype", len(f.ids))
        for i in range(len(f.ids)):
            sub = str(sub_col[i] or "road").strip().lower()
            if sub and sub != "road":
                continue
            c = str(cls_col[i] or "").strip().lower()
            if c not in classes:
                continue
            sc = _road_subclass(f, i)
            if sc in SKIP_SUBCLASSES:
                continue
            for ring in _ground_rings(f, i):
                arr = np.asarray(ring, np.float64)
                if len(arr) < 2:
                    continue
                xy = np.stack([(arr[:, 0] - lon) * M_LAT * k, (arr[:, 1] - lat) * M_LAT], axis=1)
                diffs = np.diff(xy, axis=0)
                seg_lens = np.hypot(diffs[:, 0], diffs[:, 1])
                s = np.r_[0.0, np.cumsum(seg_lens)]
                if s[-1] < 1.0:
                    continue
                d, j, t = _seg_nearest(xy, np.zeros(2))
                if d > radius_m:
                    continue
                # Slight preference for non-service roads when service is included as fallback
                rank_d = d + (60.0 if c == "service" else 0.0)
                if best is not None and rank_d >= best[0]:
                    continue
                at = s[j] + t * (s[j + 1] - s[j])
                if s[-1] > 2.0 * END_CLEAR_M:
                    at = min(max(at, END_CLEAR_M), s[-1] - END_CLEAR_M)
                qx = float(np.interp(at, s, xy[:, 0]))
                qy = float(np.interp(at, s, xy[:, 1]))
                seg_dx, seg_dy = float(diffs[j, 0]), float(diffs[j, 1])
                brg = (math.degrees(math.atan2(seg_dx, seg_dy)) + 360.0) % 360.0 if (seg_dx * seg_dx + seg_dy * seg_dy) > 1e-6 else 0.0
                slat = round(float(lat + qy / M_LAT), 6)
                slon = round(float(lon + qx / (M_LAT * k)), 6)
                rname = _clean(name_col[i])
                best = (rank_d, {
                    "lat": slat, "lon": slon,
                    "road": rname, "roadClass": c, "bearing": round(brg, 1), "snapDistM": round(d, 1),
                })
    return best[1] if best else None


def _road_candidates(md, lat, lon, min_m, max_m, classes=DRIVABLE_CLASSES, deadline=None, limit=40):
    """Collect candidate points directly along drivable ground roads in [min_m, max_m]."""
    if deadline is None:
        deadline = time.monotonic() + DEADLINE_S
    keys = _cells_around(lat, lon, min(max_m, 4500.0), max_cells=12)
    k = _cos_lat(lat)
    out = []
    seen = set()
    for key in keys:
        f = _cell_layer(md, key, "roads", deadline)
        if f is None or not len(f.ids):
            continue
        attrs = getattr(f, "attrs", {}) or {}
        cls_col = _col(attrs, "class", len(f.ids))
        name_col = _col(attrs, "name", len(f.ids))
        sub_col = _col(attrs, "subtype", len(f.ids))
        for i in range(len(f.ids)):
            sub = str(sub_col[i] or "road").strip().lower()
            if sub and sub != "road":
                continue
            c = str(cls_col[i] or "").strip().lower()
            if c not in classes:
                continue
            if _road_subclass(f, i) in SKIP_SUBCLASSES:
                continue
            fid = str(f.ids[i])
            if fid in seen:
                continue
            seen.add(fid)
            for ring in _ground_rings(f, i):
                arr = np.asarray(ring, np.float64)
                if len(arr) < 2:
                    continue
                xy = np.stack([(arr[:, 0] - lon) * M_LAT * k, (arr[:, 1] - lat) * M_LAT], axis=1)
                diffs = np.diff(xy, axis=0)
                s = np.r_[0.0, np.cumsum(np.hypot(diffs[:, 0], diffs[:, 1]))]
                if s[-1] < 8.0:
                    continue
                mid_s = s[-1] * 0.5
                qx = float(np.interp(mid_s, s, xy[:, 0]))
                qy = float(np.interp(mid_s, s, xy[:, 1]))
                d = math.hypot(qx, qy)
                if min_m <= d <= max_m:
                    mid_j = max(0, min(len(diffs) - 1, int(np.searchsorted(s, mid_s) - 1)))
                    brg = (math.degrees(math.atan2(float(diffs[mid_j, 0]), float(diffs[mid_j, 1]))) + 360.0) % 360.0
                    out.append({
                        "lat": round(float(lat + qy / M_LAT), 6),
                        "lon": round(float(lon + qx / (M_LAT * k)), 6),
                        "name": _clean(name_col[i]) or f"{c.replace('_', ' ').title()} Road",
                        "road": _clean(name_col[i]),
                        "roadClass": c,
                        "bearing": round(brg, 1),
                        "distM": d,
                    })
                    if len(out) >= limit:
                        return out
    return out


def _collect_pois_in_cells(md, keys, layers, deadline):
    """Gather normalized POI/building/land_use candidates from explicit cell keys."""
    places_out, bld_out, land_out = [], [], []
    seen = set()
    for key in keys:
        if "places" in layers:
            f = _cell_layer(md, key, "places", deadline)
            if f is not None and len(f.ids):
                attrs = getattr(f, "attrs", {}) or {}
                n = len(f.ids)
                names = _col(attrs, "name", n)
                cats = _col(attrs, "basic_category", n)
                taxes = _col(attrs, "taxonomy", n)
                status = _col(attrs, "operating_status", n)
                conf = attrs.get("confidence")
                for i in range(n):
                    pid = ("p", str(f.ids[i]))
                    if pid in seen:
                        continue
                    nm = _clean(names[i])
                    st = str(status[i] or "").lower()
                    if not nm or st in ("permanently_closed", "temporarily_closed", "closed"):
                        continue
                    pt = _feature_center(f, i)
                    if not pt:
                        continue
                    cval = float(conf[i]) if conf is not None else 0.8
                    if not math.isfinite(cval):
                        cval = 0.8
                    seen.add(pid)
                    places_out.append({
                        "name": nm,
                        "cat": str(cats[i] or "").strip().lower(),
                        "tax": str(taxes[i] or "").strip().lower(),
                        "lat": pt[0], "lon": pt[1], "conf": cval,
                    })
        if "buildings" in layers:
            f = _cell_layer(md, key, "buildings", deadline)
            if f is not None and len(f.ids):
                attrs = getattr(f, "attrs", {}) or {}
                n = len(f.ids)
                names = _col(attrs, "name", n)
                classes = _col(attrs, "class", n)
                for i in range(n):
                    bid = ("b", str(f.ids[i]))
                    if bid in seen:
                        continue
                    nm = _clean(names[i])
                    cls = str(classes[i] or "").strip().lower()
                    if not nm and cls not in LOGISTICS_HUB_CLASSES and cls not in LOGISTICS_COMMERCIAL_CLASSES:
                        continue
                    pt = _feature_center(f, i)
                    if not pt:
                        continue
                    seen.add(bid)
                    bld_out.append({"name": nm, "class": cls, "lat": pt[0], "lon": pt[1]})
        if "land_use" in layers:
            f = _cell_layer(md, key, "land_use", deadline)
            if f is not None and len(f.ids):
                attrs = getattr(f, "attrs", {}) or {}
                n = len(f.ids)
                names = _col(attrs, "name", n)
                classes = _col(attrs, "class", n)
                for i in range(n):
                    lid = ("l", str(f.ids[i]))
                    if lid in seen:
                        continue
                    cls = str(classes[i] or "").strip().lower()
                    tags = _tags_dict(attrs, i)
                    lu_tag = tags.get("landuse", "")
                    if cls not in ("industrial", "commercial", "retail") and lu_tag not in ("industrial", "commercial", "retail"):
                        continue
                    pt = _feature_center(f, i)
                    if not pt:
                        continue
                    seen.add(lid)
                    land_out.append({
                        "name": _clean(names[i]),
                        "class": cls or lu_tag,
                        "tags": tags,
                        "lat": pt[0], "lon": pt[1],
                    })
    return places_out, bld_out, land_out


def _make_stop(idx, kind, name, snapped, address="", zone_radius=12.0):
    road = snapped.get("road") or ""
    addr = address or road or f"{snapped['lat']:.5f}, {snapped['lon']:.5f}"
    return {
        "index": int(idx),
        "kind": kind,
        "name": _clean(name) or road or f"Stop {idx}",
        "address": addr,
        "lat": round(float(snapped["lat"]), 6),
        "lon": round(float(snapped["lon"]), 6),
        "road": road,
        "bearing": round(float(snapped.get("bearing") or 0.0), 1),
        "zoneRadius": float(zone_radius),
    }


def _route_estimate_km(lat0, lon0, stops):
    if not stops:
        return 0.0
    total = dist_m(lat0, lon0, stops[0]["lat"], stops[0]["lon"])
    for a, b in zip(stops, stops[1:]):
        total += dist_m(a["lat"], a["lon"], b["lat"], b["lon"])
    return round(total / 1000.0, 2)


# --------------------------------------------------------------------------- Taxi mode

def _pick_taxi_spot(md, anchor_lat, anchor_lon, min_m, max_m, ref_lat, ref_lon, seed, tag, deadline, fallback_name):
    keys = _cells_around(anchor_lat, anchor_lon, 1800.0, max_cells=9)
    road_cells = [_cell_layer(md, k, "roads", deadline) for k in keys]
    places_out, bld_out, _ = _collect_pois_in_cells(md, keys, ("places", "buildings"), deadline)

    candidates = []
    for p in places_out:
        d = dist_m(ref_lat, ref_lon, p["lat"], p["lon"])
        if min_m <= d <= max_m:
            prio = 2 if (p["cat"] in TAXI_PLACE_CATS or p["tax"] in TAXI_PLACE_CATS) else 1
            candidates.append((prio, p["conf"], d, p["lat"], p["lon"], p["name"], p["cat"]))
    for b in bld_out:
        if not b["name"]:
            continue
        d = dist_m(ref_lat, ref_lon, b["lat"], b["lon"])
        if min_m <= d <= max_m:
            candidates.append((0, 0.5, d, b["lat"], b["lon"], b["name"], b["class"]))

    candidates.sort(key=lambda c: (-c[0], -c[1], c[5], c[3]))
    if candidates:
        pool = candidates[:min(8, len(candidates))]
        for attempt in range(len(pool)):
            pick = pool[(_stable_index(seed, tag, len(pool)) + attempt) % len(pool)]
            snapped = snap_to_road(md, pick[3], pick[4], radius_m=280.0, deadline=deadline, road_cells=road_cells)
            if snapped and min_m <= dist_m(ref_lat, ref_lon, snapped["lat"], snapped["lon"]) <= max_m * 1.25:
                return pick[5], snapped

    # Fallback directly onto drivable ground roads inside the target box
    rc = _road_candidates(md, ref_lat, ref_lon, min_m, max_m, deadline=deadline) if anchor_lat == ref_lat and anchor_lon == ref_lon else []
    if rc:
        pick = rc[_stable_index(seed, tag + ":rc", len(rc))]
        return pick["name"], pick
    snapped = snap_to_road(md, anchor_lat, anchor_lon, radius_m=1500.0, deadline=deadline, road_cells=road_cells)
    if snapped:
        d = dist_m(ref_lat, ref_lon, snapped["lat"], snapped["lon"])
        if d >= max(150.0, min_m * 0.6):
            return (snapped["road"] or fallback_name), snapped
    return None


def _towns_in_band(lat, lon, min_km, max_km, heading, seed, tag):
    """Rank Natural Earth populated places in [min_km, max_km], biased gently toward heading."""
    ts = randomplace.towns()
    if not ts:
        return []
    hits = []
    min_m, max_m = min_km * 1000.0, max_km * 1000.0
    mid_m = 0.5 * (min_m + max_m)
    for tlat, tlon, tname in ts:
        d = dist_m(lat, lon, tlat, tlon)
        if min_m <= d <= max_m:
            ang = _heading_diff(heading, bearing_deg(lat, lon, tlat, tlon)) if heading is not None else 0.0
            score = abs(d - mid_m) / max(1.0, max_m - min_m) + (ang / 180.0) * 0.65
            hits.append((score, tlat, tlon, tname))
    hits.sort(key=lambda r: (r[0], r[3]))
    if not hits:
        return []
    # Rotate deterministically across top few matches on different seeds
    top = hits[:min(6, len(hits))]
    off = _stable_index(seed, tag, len(top))
    return top[off:] + top[:off]


def _generate_taxi(md, req, deadline):
    lat, lon, heading, seed, tier = req["lat"], req["lon"], req["heading"], req["seed"], req["tier"]
    spec = TIERS["taxi"][tier]
    min_km, max_km = spec["min_km"], spec["max_km"]

    # 1. Pickup within 250 m - 1100 m (or fallback within 1500 m)
    pickup = _pick_taxi_spot(md, lat, lon, 250.0, 1100.0, lat, lon, seed, "taxi_pu", deadline, "Street Pickup")
    if not pickup:
        snapped = snap_to_road(md, lat, lon, radius_m=1500.0, deadline=deadline)
        if not snapped:
            return {"ok": False, "error": "No drivable roads found near your location"}
        pickup = (snapped["road"] or "Roadside Pickup", snapped)
    pu_name, pu_snap = pickup
    pu_stop = _make_stop(1, "pickup", pu_name, pu_snap, zone_radius=12.0)

    # 2. Drop-off in the selected distance tier
    dropoff = None
    base_brg = heading if heading is not None else float(_stable_index(seed, "taxi_brg", 360))
    if tier == "neighborhood":
        for rot in (0.0, 45.0, -45.0, 90.0, -90.0, 135.0, -135.0, 180.0):
            if time.monotonic() > deadline:
                break
            dist_target = (min_km + (max_km - min_km) * ((_stable_index(seed, f"d{rot}", 100) + 10) / 115.0)) * 1000.0
            alat, alon = offset_latlon(pu_stop["lat"], pu_stop["lon"], dist_target, (base_brg + rot) % 360.0)
            dropoff = _pick_taxi_spot(
                md, alat, alon, min_km * 1000.0, max_km * 1000.0,
                pu_stop["lat"], pu_stop["lon"], seed, f"taxi_do:{rot}", deadline, "Taxi Drop-off",
            )
            if dropoff:
                break
    elif tier == "city":
        for rot in (0.0, 40.0, -40.0, 85.0, -85.0, 140.0, -140.0, 180.0):
            if time.monotonic() > deadline:
                break
            frac = 0.25 + 0.55 * (_stable_index(seed, f"cd{rot}", 100) / 100.0)
            dist_target = (min_km + (max_km - min_km) * frac) * 1000.0
            alat, alon = offset_latlon(pu_stop["lat"], pu_stop["lon"], dist_target, (base_brg + rot) % 360.0)
            dropoff = _pick_taxi_spot(
                md, alat, alon, min_km * 1000.0, max_km * 1000.0,
                pu_stop["lat"], pu_stop["lon"], seed, f"taxi_do:{rot}", deadline, "City Drop-off",
            )
            if dropoff:
                break
    else:  # regional (20-60 km)
        towns = _towns_in_band(pu_stop["lat"], pu_stop["lon"], min_km, max_km, heading, seed, "taxi_reg")
        for _, tlat, tlon, tname in towns[:4]:
            if time.monotonic() > deadline:
                break
            dropoff = _pick_taxi_spot(
                md, tlat, tlon, min_km * 1000.0, max_km * 1000.0,
                pu_stop["lat"], pu_stop["lon"], seed, f"taxi_reg:{tname}", deadline, tname,
            )
            if dropoff:
                do_name, do_snap = dropoff
                if tname.lower() not in do_name.lower():
                    dropoff = (do_name, {**do_snap, "_town": tname})
                break
        if not dropoff:
            for rot in (0.0, 45.0, -45.0, 90.0, -90.0):
                if time.monotonic() > deadline:
                    break
                dist_target = 0.5 * (min_km + max_km) * 1000.0
                alat, alon = offset_latlon(pu_stop["lat"], pu_stop["lon"], dist_target, (base_brg + rot) % 360.0)
                dropoff = _pick_taxi_spot(
                    md, alat, alon, min_km * 1000.0, max_km * 1000.0,
                    pu_stop["lat"], pu_stop["lon"], seed, f"taxi_reg_off:{rot}", deadline, "Regional Destination",
                )
                if dropoff:
                    break

    if not dropoff:
        return {"ok": False, "error": "Could not find a drivable destination in that distance tier"}
    do_name, do_snap = dropoff
    town_suffix = do_snap.get("_town")
    do_addr = do_snap.get("road") or ""
    if town_suffix:
        do_addr = f"{do_addr}, {town_suffix}" if do_addr else town_suffix
    do_stop = _make_stop(2, "dropoff", do_name, do_snap, address=do_addr, zone_radius=12.0)
    stops = [pu_stop, do_stop]
    return {
        "ok": True,
        "mode": "taxi",
        "tier": tier,
        "title": f"{pu_stop['name']} -> {do_stop['name']}",
        "source": "overture",
        "estimatedKm": _route_estimate_km(lat, lon, stops),
        "stops": stops,
    }


# --------------------------------------------------------------------------- Bus mode

def _bus_overpass_query(lat, lon):
    q = (
        "[out:json][timeout:3][maxsize:2097152];"
        f'(node(around:1800,{lat:.4f},{lon:.4f})["highway"="bus_stop"];'
        f'node(around:1800,{lat:.4f},{lon:.4f})["public_transport"~"^(platform|stop_position)$"]["bus"="yes"];)->.near;'
        'rel(bn.near)["type"="route"]["route"="bus"]->.r;'
        ".r out body 8;"
        '(node(r.r:"stop");node(r.r:"stop_entry_only");node(r.r:"stop_exit_only");'
        'node(r.r:"platform");node(r.r:"platform_entry_only");node(r.r:"platform_exit_only");'
        'way(r.r:"platform");node(r.r)["highway"="bus_stop"];);'
        "out center tags;"
    )
    return OVERPASS_URL + "?" + urllib.parse.urlencode({"data": q})


def parse_bus_relations(data):
    """Parse Overpass JSON into normalized ordered bus routes [{id, ref, name, stops:[{lat, lon, name, role}]}]. Pure."""
    if not isinstance(data, dict) or data.get("remark"):
        return []
    nodes, ways, rels = {}, {}, []
    for el in data.get("elements") or ():
        if not isinstance(el, dict):
            continue
        et = el.get("type")
        eid = el.get("id")
        if eid is None:
            continue
        if et == "node" and "lat" in el and "lon" in el:
            try:
                nodes[eid] = (float(el["lat"]), float(el["lon"]), el.get("tags") or {})
            except (TypeError, ValueError):
                pass
        elif et == "way":
            c = el.get("center") or {}
            if "lat" in c and "lon" in c:
                try:
                    ways[eid] = (float(c["lat"]), float(c["lon"]), el.get("tags") or {})
                except (TypeError, ValueError):
                    pass
        elif et == "relation":
            rels.append(el)

    routes = []
    for rel in rels:
        tags = rel.get("tags") or {}
        raw_stops = []
        for m in rel.get("members") or ():
            if not isinstance(m, dict):
                continue
            role = str(m.get("role") or "").strip().lower()
            mtype = m.get("type")
            ref_id = m.get("ref")
            item = nodes.get(ref_id) if mtype == "node" else ways.get(ref_id) if mtype == "way" else None
            if item is None:
                continue
            la, lo, stags = item
            is_stop_role = role in (
                "stop", "stop_entry_only", "stop_exit_only",
                "platform", "platform_entry_only", "platform_exit_only",
            )
            is_stop_tag = stags.get("highway") == "bus_stop" or stags.get("public_transport") in ("platform", "stop_position")
            if not (is_stop_role or is_stop_tag):
                continue
            if not (-90.0 <= la <= 90.0 and -180.0 <= lo <= 180.0):
                continue
            nm = _clean(stags.get("name") or stags.get("ref") or "")
            raw_stops.append({"lat": la, "lon": lo, "name": nm, "role": role, "is_pos": "stop" in role or stags.get("public_transport") == "stop_position"})

        # Deduplicate paired stop_position + platform at the same physical stop (< 45 m)
        dedup = []
        for s in raw_stops:
            if dedup and dist_m(dedup[-1]["lat"], dedup[-1]["lon"], s["lat"], s["lon"]) <= 45.0:
                # Prefer stop_position coordinates (on road) and keep whichever has a name
                if s["is_pos"] and not dedup[-1]["is_pos"]:
                    name = dedup[-1]["name"] or s["name"]
                    dedup[-1] = {**s, "name": name}
                elif not dedup[-1]["name"] and s["name"]:
                    dedup[-1]["name"] = s["name"]
                continue
            dedup.append(s)

        if len(dedup) >= 4:
            ref = _clean(tags.get("ref") or "")
            rname = _clean(tags.get("name") or "")
            if not rname:
                frm, to = _clean(tags.get("from")), _clean(tags.get("to"))
                rname = f"{frm} -> {to}" if frm and to else (f"Bus {ref}" if ref else "Bus Route")
            routes.append({"id": rel.get("id"), "ref": ref, "name": rname, "stops": dedup})
    return routes


def _fetch_bus_relations(net, lat, lon):
    if net is None:
        return []
    key = (round(lat, 3), round(lon, 3))
    now = time.monotonic()
    with _bus_cache_lock:
        ent = _bus_cache.get(key)
        if ent is not None and ent[0] > now:
            return ent[1]
    try:
        resp = net.get(_bus_overpass_query(lat, lon), kind="demand")
        routes = parse_bus_relations(json.loads(resp.body.decode("utf-8", "replace")))
        ttl = OVERPASS_CACHE_S
    except Exception as e:
        log.info("bus overpass: %s: %s", type(e).__name__, e)
        routes = []
        ttl = OVERPASS_FAIL_COOLDOWN_S
    with _bus_cache_lock:
        if len(_bus_cache) >= OVERPASS_MAX_CACHE:
            _bus_cache.clear()
        _bus_cache[key] = (time.monotonic() + ttl, routes)
    return routes


def _slice_partial_bus(stops, lat, lon, heading):
    """Slice 4-6 consecutive stops along heading from nearest/ahead stop."""
    n = len(stops)
    if n <= 6:
        return list(stops)
    best_idx = 0
    best_score = float("inf")
    for idx, s in enumerate(stops):
        d = dist_m(lat, lon, s["lat"], s["lon"])
        # Prefer stops slightly ahead along heading if heading is known
        align = 0.0
        if heading is not None and idx + 1 < n:
            seg_brg = bearing_deg(s["lat"], s["lon"], stops[idx + 1]["lat"], stops[idx + 1]["lon"])
            align = _heading_diff(heading, seg_brg) * 6.0
        sc = d + align
        if sc < best_score:
            best_score = sc
            best_idx = idx
    # Ensure at least 4-6 stops remain; shift backward if near terminus
    count = min(6, max(4, n - best_idx))
    start = min(best_idx, max(0, n - count))
    return stops[start:start + count]


def _infra_bus_stops(md, lat, lon, deadline):
    keys = _cells_around(lat, lon, 3000.0, max_cells=9)
    out, seen = [], set()
    for key in keys:
        f = _cell_layer(md, key, "infrastructure", deadline)
        if f is None or not len(f.ids):
            continue
        attrs = getattr(f, "attrs", {}) or {}
        n = len(f.ids)
        classes = _col(attrs, "class", n)
        names = _col(attrs, "name", n)
        for i in range(n):
            cls = str(classes[i] or "").strip().lower()
            tags = _tags_dict(attrs, i)
            if cls not in ("bus_stop", "platform", "bus_station", "stop_position") and tags.get("highway") != "bus_stop":
                continue
            if tags.get("railway") == "platform" and tags.get("bus") != "yes":
                continue
            pt = _feature_center(f, i)
            if not pt:
                continue
            la, lo = pt
            # Deduplicate co-located platforms/stop_positions within 45 m
            if any(dist_m(la, lo, o["lat"], o["lon"]) <= 45.0 for o in seen):
                continue
            seen.add((la, lo))
            nm = _clean(names[i]) or _clean(tags.get("name") or "") or f"Bus Stop {len(out) + 1}"
            out.append({"lat": la, "lon": lo, "name": nm})
    return out


def _chain_stops_by_heading(candidates, lat, lon, heading, target_count):
    """Deterministically order stops into a progressive forward chain without zig-zagging."""
    if not candidates:
        return []
    cur_lat, cur_lon = lat, lon
    cur_brg = heading
    remaining = list(candidates)
    chosen = []
    while remaining and len(chosen) < target_count:
        best_i = None
        best_cost = float("inf")
        for i, c in enumerate(remaining):
            d = dist_m(cur_lat, cur_lon, c["lat"], c["lon"])
            if chosen and d < 220.0:
                continue
            if d > 2800.0:
                continue
            ang = _heading_diff(cur_brg, bearing_deg(cur_lat, cur_lon, c["lat"], c["lon"])) if cur_brg is not None else 0.0
            if chosen and cur_brg is not None and ang > 105.0:
                continue
            cost = d + ang * 8.0
            if cost < best_cost:
                best_cost = cost
                best_i = i
        if best_i is None:
            break
        nxt = remaining.pop(best_i)
        cur_brg = bearing_deg(cur_lat, cur_lon, nxt["lat"], nxt["lon"])
        cur_lat, cur_lon = nxt["lat"], nxt["lon"]
        chosen.append(nxt)
    return chosen


def _generate_bus(md, net, req, deadline):
    lat, lon, heading, seed, tier = req["lat"], req["lon"], req["heading"], req["seed"], req["tier"]
    target_min = 4 if tier == "partial" else 6
    target_max = 6 if tier == "partial" else 10

    # 1. Try OSM route=bus via bounded Overpass
    routes = _fetch_bus_relations(net, lat, lon)
    if routes:
        def route_rank(r):
            dmin = min(dist_m(lat, lon, s["lat"], s["lon"]) for s in r["stops"])
            align = 0.0
            if heading is not None and len(r["stops"]) >= 2:
                brg = bearing_deg(r["stops"][0]["lat"], r["stops"][0]["lon"], r["stops"][1]["lat"], r["stops"][1]["lon"])
                align = _heading_diff(heading, brg) * 5.0
            return dmin + align

        ranked = sorted(routes, key=route_rank)
        chosen_route = ranked[_stable_index(seed, f"bus_rel:{tier}", min(3, len(ranked)))]
        raw_stops = _slice_partial_bus(chosen_route["stops"], lat, lon, heading) if tier == "partial" else chosen_route["stops"]
        road_cache = {}
        snapped_stops = []
        for idx, s in enumerate(raw_stops, 1):
            ckey = mapcells.cell_of(s["lat"], s["lon"])
            if ckey not in road_cache:
                road_cache[ckey] = [_cell_layer(md, ckey, "roads", deadline)] if time.monotonic() <= deadline else []
            snapped = snap_to_road(md, s["lat"], s["lon"], radius_m=150.0, deadline=deadline, road_cells=road_cache[ckey])
            if not snapped:
                snapped = {"lat": s["lat"], "lon": s["lon"], "road": "", "bearing": 0.0}
            snapped_stops.append(_make_stop(idx, "bus_stop", s["name"] or f"Stop {idx}", snapped, zone_radius=14.0))
        if len(snapped_stops) >= 4:
            return {
                "ok": True,
                "mode": "bus",
                "tier": tier,
                "title": chosen_route["name"],
                "routeRef": chosen_route["ref"] or chosen_route["name"],
                "source": "osm_bus",
                "estimatedKm": _route_estimate_km(lat, lon, snapped_stops),
                "stops": snapped_stops,
            }

    # 2. Fallback A: Overture infrastructure transit stops chained along heading
    infra = _infra_bus_stops(md, lat, lon, deadline)
    chain = _chain_stops_by_heading(infra, lat, lon, heading, target_max)
    if len(chain) >= target_min:
        stops = []
        for idx, s in enumerate(chain, 1):
            snapped = snap_to_road(md, s["lat"], s["lon"], radius_m=150.0, deadline=deadline) or {
                "lat": s["lat"], "lon": s["lon"], "road": "", "bearing": 0.0,
            }
            stops.append(_make_stop(idx, "bus_stop", s["name"], snapped, zone_radius=14.0))
        return {
            "ok": True,
            "mode": "bus",
            "tier": tier,
            "title": f"Local Transit Chain ({len(stops)} stops)",
            "routeRef": "Local Bus",
            "source": "overture",
            "estimatedKm": _route_estimate_km(lat, lon, stops),
            "stops": stops,
        }

    # 3. Fallback B: Deterministic road-snapped stop chain along drivable roads
    base_brg = heading if heading is not None else float(_stable_index(seed, "bus_brg", 360))
    step_m = 480.0
    stops = []
    cur_lat, cur_lon = lat, lon
    for k in range(1, target_max + 4):
        if time.monotonic() > deadline or len(stops) >= target_max:
            break
        alat, alon = offset_latlon(cur_lat, cur_lon, step_m, base_brg)
        snapped = snap_to_road(md, alat, alon, radius_m=400.0, deadline=deadline)
        if not snapped:
            alat, alon = offset_latlon(cur_lat, cur_lon, step_m, (base_brg + 35.0) % 360.0)
            snapped = snap_to_road(md, alat, alon, radius_m=400.0, deadline=deadline)
        if snapped and (not stops or dist_m(stops[-1]["lat"], stops[-1]["lon"], snapped["lat"], snapped["lon"]) >= 250.0):
            idx = len(stops) + 1
            nm = f"{snapped['road']} Stop {idx}" if snapped.get("road") else f"Bus Stop {idx}"
            stops.append(_make_stop(idx, "bus_stop", nm, snapped, zone_radius=14.0))
            base_brg = bearing_deg(cur_lat, cur_lon, snapped["lat"], snapped["lon"])
            cur_lat, cur_lon = snapped["lat"], snapped["lon"]
        else:
            cur_lat, cur_lon = alat, alon

    if len(stops) < 2:
        return {"ok": False, "error": "No drivable roads found nearby for a bus route"}
    return {
        "ok": True,
        "mode": "bus",
        "tier": tier,
        "title": f"Bus Corridor ({len(stops)} stops)",
        "routeRef": "Local Corridor",
        "source": "road_chain",
        "estimatedKm": _route_estimate_km(lat, lon, stops),
        "stops": stops,
    }


# --------------------------------------------------------------------------- Logistics mode

def _is_retail_place(cat, tax):
    if cat in LOGISTICS_RETAIL_EXACT or tax in LOGISTICS_RETAIL_EXACT:
        return True
    return cat.endswith(LOGISTICS_RETAIL_SUFFIX) or tax.endswith(LOGISTICS_RETAIL_SUFFIX)


def _generate_logistics_short(md, req, deadline):
    lat, lon, heading, seed, tier = req["lat"], req["lon"], req["heading"], req["seed"], req["tier"]
    spec = TIERS["logistics"][tier]
    target_km = spec["target_km"]
    min_stops, max_stops = spec["min_stops"], spec["max_stops"]
    base_brg = heading if heading is not None else float(_stable_index(seed, f"log_brg:{tier}", 360))

    # Targeted cell pockets: local + 2-3 stepped pockets along a progressive arc (<= 16 cells)
    keys = list(_cells_around(lat, lon, 2000.0, max_cells=6))
    if tier == "city":
        for frac, rot in ((0.35, -20.0), (0.65, 15.0), (0.95, 0.0)):
            alat, alon = offset_latlon(lat, lon, target_km * 1000.0 * frac, (base_brg + rot) % 360.0)
            for k in _cells_around(alat, alon, 1200.0, max_cells=4):
                if k not in keys:
                    keys.append(k)
    else:
        alat, alon = offset_latlon(lat, lon, target_km * 1000.0 * 0.6, base_brg)
        for k in _cells_around(alat, alon, 1400.0, max_cells=4):
            if k not in keys:
                keys.append(k)
    keys = keys[:14]

    places_out, bld_out, _ = _collect_pois_in_cells(md, keys, ("places", "buildings"), deadline)
    candidates = []
    max_r_m = target_km * 1250.0
    for p in places_out:
        d = dist_m(lat, lon, p["lat"], p["lon"])
        if 200.0 <= d <= max_r_m:
            retail = 2 if _is_retail_place(p["cat"], p["tax"]) else 1
            candidates.append((retail, p["conf"], p["lat"], p["lon"], p["name"]))
    for b in bld_out:
        if not b["name"]:
            continue
        d = dist_m(lat, lon, b["lat"], b["lon"])
        if 200.0 <= d <= max_r_m and b["class"] in (LOGISTICS_COMMERCIAL_CLASSES | LOGISTICS_HUB_CLASSES):
            candidates.append((1, 0.6, b["lat"], b["lon"], b["name"]))

    candidates.sort(key=lambda c: (-c[0], -c[1], c[4], c[2]))
    # Pick spread-out stops sequentially by nearest neighbor from player
    picked = []
    cur_lat, cur_lon = lat, lon
    pool = list(candidates[:80])
    min_gap = 320.0 if tier == "local" else 650.0
    want = min_stops + _stable_index(seed, f"n:{tier}", max_stops - min_stops + 1)
    while pool and len(picked) < want and time.monotonic() <= deadline:
        pool.sort(key=lambda c: (dist_m(cur_lat, cur_lon, c[2], c[3]) - c[0] * 150.0, c[4]))
        nxt = None
        for idx, cand in enumerate(pool):
            if all(dist_m(cand[2], cand[3], prev["lat"], prev["lon"]) >= min_gap for prev in picked):
                nxt = pool.pop(idx)
                break
        if nxt is None:
            break
        snapped = snap_to_road(md, nxt[2], nxt[3], radius_m=250.0, classes=LOGISTICS_FALLBACK_CLASSES, deadline=deadline)
        if snapped:
            stop_idx = len(picked) + 1
            kind = "loading" if stop_idx == 1 else "delivery"
            picked.append(_make_stop(stop_idx, kind, nxt[4], snapped, zone_radius=13.0))
            cur_lat, cur_lon = snapped["lat"], snapped["lon"]

    # Road-chain fallback if sparse
    if len(picked) < min_stops:
        step_m = (target_km * 1000.0) / max(1, min_stops)
        for k in range(len(picked) + 1, min_stops + 2):
            if time.monotonic() > deadline or len(picked) >= min_stops:
                break
            alat, alon = offset_latlon(cur_lat, cur_lon, step_m, (base_brg + (k % 3 - 1) * 25.0) % 360.0)
            snapped = snap_to_road(md, alat, alon, radius_m=500.0, classes=LOGISTICS_FALLBACK_CLASSES, deadline=deadline)
            if snapped and all(dist_m(snapped["lat"], snapped["lon"], prev["lat"], prev["lon"]) >= 250.0 for prev in picked):
                stop_idx = len(picked) + 1
                nm = f"{snapped['road']} Drop-off {stop_idx}" if snapped.get("road") else f"Delivery Point {stop_idx}"
                picked.append(_make_stop(stop_idx, "loading" if stop_idx == 1 else "delivery", nm, snapped, zone_radius=13.0))
                cur_lat, cur_lon = snapped["lat"], snapped["lon"]

    if not picked:
        return {"ok": False, "error": "No drivable delivery locations found nearby"}
    return {
        "ok": True,
        "mode": "logistics",
        "tier": tier,
        "title": f"{'Local Van' if tier == 'local' else 'City Delivery'} ({len(picked)} stops)",
        "source": "overture",
        "estimatedKm": _route_estimate_km(lat, lon, picked),
        "stops": picked,
    }


def _find_freight_hub(md, alat, alon, seed, tag, deadline, fallback_label):
    """Search a small targeted 2x2 cell box around (alat, alon) for industrial/warehouse/commercial hub."""
    keys = _cells_around(alat, alon, 1600.0, max_cells=4)
    road_cells = [_cell_layer(md, k, "roads", deadline) for k in keys]
    places_out, bld_out, land_out = _collect_pois_in_cells(md, keys, ("places", "buildings", "land_use"), deadline)

    candidates = []
    for lu in land_out:
        prio = 4 if lu["class"] == "industrial" else 2
        nm = lu["name"] or (f"{fallback_label} Industrial Park" if lu["class"] == "industrial" else f"{fallback_label} Commercial Zone")
        candidates.append((prio, lu["lat"], lu["lon"], nm))
    for b in bld_out:
        if b["class"] in LOGISTICS_HUB_CLASSES:
            candidates.append((3, b["lat"], b["lon"], b["name"] or f"{fallback_label} Warehouse"))
        elif b["class"] in LOGISTICS_COMMERCIAL_CLASSES and b["name"]:
            candidates.append((1, b["lat"], b["lon"], b["name"]))
    for p in places_out:
        if p["cat"] in LOGISTICS_HUB_CATS or p["tax"] in LOGISTICS_HUB_CATS:
            candidates.append((3, p["lat"], p["lon"], p["name"]))
        elif _is_retail_place(p["cat"], p["tax"]):
            candidates.append((1, p["lat"], p["lon"], p["name"]))

    candidates.sort(key=lambda c: (-c[0], c[3], c[1]))
    if candidates:
        top = candidates[:min(6, len(candidates))]
        for off in range(len(top)):
            pick = top[(_stable_index(seed, tag, len(top)) + off) % len(top)]
            snapped = snap_to_road(md, pick[1], pick[2], radius_m=350.0, classes=LOGISTICS_FALLBACK_CLASSES,
                                   deadline=deadline, road_cells=road_cells)
            if snapped:
                return pick[3], snapped
    snapped = snap_to_road(md, alat, alon, radius_m=1500.0, classes=LOGISTICS_FALLBACK_CLASSES,
                           deadline=deadline, road_cells=road_cells)
    if snapped:
        return (snapped["road"] or f"{fallback_label} Depot"), snapped
    return None


def _generate_logistics_haul(md, req, deadline):
    lat, lon, heading, seed, tier = req["lat"], req["lon"], req["heading"], req["seed"], req["tier"]
    is_long = tier == "long"
    min_km, max_km = (100.0, 175.0) if is_long else (38.0, 62.0)

    # 1. Origin hub near player (300 m - 2500 m)
    origin_off_lat, origin_off_lon = offset_latlon(lat, lon, 700.0, heading if heading is not None else 0.0)
    origin = _find_freight_hub(md, origin_off_lat, origin_off_lon, seed, "log_origin", deadline, "Origin")
    if not origin:
        origin = _find_freight_hub(md, lat, lon, seed, "log_origin_local", deadline, "Origin")
    if not origin:
        return {"ok": False, "error": "No drivable road found near origin"}
    o_name, o_snap = origin
    stops = [_make_stop(1, "loading", o_name, o_snap, zone_radius=15.0)]

    # 2. Destination hub from targeted towns in [min_km, max_km] (zero Overpass!)
    dest = None
    dest_town = ""
    towns = _towns_in_band(stops[0]["lat"], stops[0]["lon"], min_km, max_km, heading, seed, f"log_dest:{tier}")
    for _, tlat, tlon, tname in towns[:4]:
        if time.monotonic() > deadline:
            break
        hub = _find_freight_hub(md, tlat, tlon, seed, f"log_hub:{tname}", deadline, tname)
        if hub and dist_m(stops[0]["lat"], stops[0]["lon"], hub[1]["lat"], hub[1]["lon"]) >= min_km * 950.0:
            dest = hub
            dest_town = tname
            break

    if not dest:
        base_brg = heading if heading is not None else float(_stable_index(seed, f"log_hbrg:{tier}", 360))
        target_m = (115.0 if is_long else 50.0) * 1000.0
        for rot in (0.0, 45.0, -45.0, 90.0, -90.0, 180.0):
            if time.monotonic() > deadline:
                break
            alat, alon = offset_latlon(stops[0]["lat"], stops[0]["lon"], target_m, (base_brg + rot) % 360.0)
            hub = _find_freight_hub(md, alat, alon, seed, f"log_off:{rot}", deadline, "Freight Hub")
            if hub:
                dest = hub
                break

    if not dest:
        return {"ok": False, "error": "Could not find a freight destination in range"}

    # Optional midpoint stop on Regional Haul (50 km, 2-3 stops)
    if tier == "regional" and _stable_index(seed, "reg_mid", 2) == 1 and time.monotonic() < deadline - 0.35:
        mlat = 0.5 * (stops[0]["lat"] + dest[1]["lat"])
        mlon = 0.5 * (stops[0]["lon"] + dest[1]["lon"])
        mid = _find_freight_hub(md, mlat, mlon, seed, "log_mid", deadline, "Midpoint")
        if mid and dist_m(stops[0]["lat"], stops[0]["lon"], mid[1]["lat"], mid[1]["lon"]) >= 8000.0:
            stops.append(_make_stop(2, "delivery", mid[0], mid[1], zone_radius=15.0))

    d_name, d_snap = dest
    d_addr = d_snap.get("road") or ""
    if dest_town:
        d_addr = f"{d_addr}, {dest_town}" if d_addr else dest_town
    stops.append(_make_stop(len(stops) + 1, "delivery", d_name, d_snap, address=d_addr, zone_radius=15.0))
    return {
        "ok": True,
        "mode": "logistics",
        "tier": tier,
        "title": f"{stops[0]['name']} -> {stops[-1]['name']}",
        "source": "overture",
        "estimatedKm": _route_estimate_km(lat, lon, stops),
        "stops": stops,
    }


def generate_job(md, net=None, *, mode, tier, lat, lon, heading=None, seed=0, deadline_s=DEADLINE_S):
    """Generate a global, deterministic Transport Mode job within deadline_s."""
    req, err = validate_request({
        "mode": mode, "tier": tier, "lat": lat, "lon": lon, "heading": heading, "seed": seed,
    })
    if req is None:
        return {"ok": False, "mode": str(mode or ""), "tier": str(tier or ""), "stops": [], "error": err}
    if md is None:
        return {"ok": False, "mode": req["mode"], "tier": req["tier"], "stops": [],
                "error": "No map data available (enable Roads in settings)"}
    deadline = time.monotonic() + max(0.2, float(deadline_s))
    try:
        if req["mode"] == "taxi":
            res = _generate_taxi(md, req, deadline)
        elif req["mode"] == "bus":
            res = _generate_bus(md, net, req, deadline)
        else:
            if req["tier"] in ("local", "city"):
                res = _generate_logistics_short(md, req, deadline)
            else:
                res = _generate_logistics_haul(md, req, deadline)
    except Exception as e:
        log.warning("transport job %s/%s failed: %s: %s", req["mode"], req["tier"], type(e).__name__, e)
        res = {"ok": False, "error": f"{type(e).__name__}: {e}"[:160]}
    res.setdefault("mode", req["mode"])
    res.setdefault("tier", req["tier"])
    res.setdefault("stops", [])
    return res
