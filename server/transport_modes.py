"""Global, deterministic Transport Modes (Taxi, Bus, Logistics) job and route-stop generation.

Generates multi-stop transport jobs anywhere on Earth using:
  - Overture z14 MapData cells (roads, places, buildings, land_use, infrastructure)
  - Natural Earth populated places (randomplace.towns()) for zero-network regional/long-haul hubs
  - Bounded single-shot Overpass queries for OSM route=bus relations (with TTL cache and deterministic local fallback)

All coordinates are snapped onto drivable ground roads (excluding footway/cycleway/pedestrian/steps/path/service-only
and bridges/tunnels via roads.ground_parts) so the client GPS and kerbside zone markers always sit on valid roads.
"""
import functools
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
LOGISTICS_SITE_SUBCLASSES = frozenset({"parking_aisle", "driveway", "alley", ""})
NON_VEHICLE_SUBCLASSES = frozenset({"sidewalk", "crosswalk", "cycle_crossing", "footway", "steps", "path", "pedestrian"})
_ROAD_HALF_W = {
    "motorway": 5.5, "trunk": 4.5, "primary": 4.0, "secondary": 3.75,
    "tertiary": 3.25, "residential": 3.0, "unclassified": 2.75,
    "living_street": 2.5, "service": 2.0, "unknown": 2.5,
}
SITE_SEARCH_M = 60.0
BLD_CLEAR_M = 2.5

MODES = ("taxi", "bus", "logistics", "parcel")
TIERS = {
    "taxi": {
        "short": {"min_km": 1.0, "max_km": 3.5, "label": "Short Ride (1-3.5 km)"},
        "city": {"min_km": 4.0, "max_km": 12.0, "label": "City Ride (4-12 km)"},
        "regional": {"min_km": 20.0, "max_km": 50.0, "label": "Regional Ride (20-50 km)"},
        "long": {"min_km": 55.0, "max_km": 110.0, "label": "Airport / Long Ride (55-110 km)"},
    },
    "bus": {
        "partial": {"min_stops": 4, "max_stops": 6, "label": "Partial Route (4-6 stops)"},
        "full": {"min_stops": 6, "max_stops": 60, "label": "Full Line (complete OSM route=bus)"},
    },
    "logistics": {
        "local": {"target_km": 3.0, "min_stops": 2, "max_stops": 4, "label": "Local Van (3 km, 2-4 stops)"},
        "city": {"target_km": 10.0, "min_stops": 4, "max_stops": 6, "label": "City Delivery (10 km, 4-6 stops)"},
        "regional": {"target_km": 50.0, "min_stops": 2, "max_stops": 4, "label": "Regional Haul (50 km, 2-4 stops)"},
        "long": {"target_km": 115.0, "min_stops": 2, "max_stops": 2, "label": "Long Haul (100 km+)"},
    },
    "parcel": {
        "local": {"target_km": 3.0, "min_stops": 5, "max_stops": 7, "label": "Local Round (3 km, 5-7 stops)"},
        "city": {"target_km": 8.0, "min_stops": 8, "max_stops": 12, "label": "City Round (8 km, 8-12 stops)"},
        "regional": {"target_km": 25.0, "min_stops": 6, "max_stops": 10, "label": "Regional Round (25 km, 6-10 stops)"},
        "long": {"target_km": 60.0, "min_stops": 5, "max_stops": 8, "label": "Long Route (60 km, 5-8 stops)"},
    },
}

RESIDENTIAL_BUILDING_CLASSES = frozenset({
    "house", "detached", "semidetached_house", "terrace", "apartments",
    "residential", "bungalow", "cabin", "farm", "duplex",
})
PARCEL_ROAD_CLASSES = frozenset({
    "residential", "living_street", "unclassified", "tertiary", "secondary", "unknown",
})
PARCEL_HOUSEHOLD_RECIPIENTS = (
    "Fam. Weber", "M. Gruber", "K. Hoffmann", "S. Bauer", "Fam. Wagner",
    "T. Richter", "A. Klein", "Fam. Schröder", "L. Neumann", "H. Schwarz",
    "Fam. Zimmermann", "J. Braun", "E. Hartmann", "Fam. Krüger", "N. Werner", "C. Schäfer",
)
PARCEL_BUSINESS_RECIPIENTS = (
    "Praxis Dr. König", "Kanzlei Huber", "Büro Schneider", "Atelier Maier",
    "Steuerbüro Wolf", "Studio Berger", "Praxis Dr. Becker", "Architekturbüro Koch",
)

VEHICLE_CLASSES = ("car", "van", "box_truck", "semi")
CARGO_BANDS = {
    "car": (80, 350),
    "van": (400, 1400),
    "box_truck": (2500, 8000),
    "semi": (12000, 26000),
}
SEMI_BOBTAIL_BAND = (2500, 6000)
CARGO_CATALOG = {
    "car": [
        ("parcels", "Courier Parcels"),
        ("medical", "Medical Supplies"),
        ("auto_parts", "Express Auto Parts"),
        ("documents", "Priority Documents"),
    ],
    "van": [
        ("groceries", "Fresh Produce & Dry Goods"),
        ("hardware", "Hardware & Trade Supplies"),
        ("appliances", "Small Appliances"),
        ("electronics", "Retail Electronics"),
    ],
    "box_truck": [
        ("pallets", "Palletized Retail Stock"),
        ("beverages", "Beverage Pallets"),
        ("hvac", "HVAC Equipment"),
        ("furniture", "Commercial Furniture"),
    ],
    "semi": [
        ("dry_goods", "Containerized Dry Goods"),
        ("machinery", "Industrial Machinery"),
        ("steel", "Structural Steel"),
        ("bulk_food", "Bulk Foodstuffs"),
    ],
}

TRAILER_CANDIDATES = {
    "fifthwheel": {
        "fuel": ("tanker", "dryvan", "container"),
        "fuel_drums": ("dryvan", "flatbed", "container"),
        "food": ("reefer", "dryvan", "container"),
        "groceries": ("reefer", "dryvan", "container"),
        "chilled_food": ("reefer", "dryvan", "container"),
        "bulk_food": ("reefer", "dryvan", "container"),
        "beverages": ("dryvan", "reefer", "container"),
        "medical": ("reefer", "dryvan", "container"),
        "pharma": ("reefer", "dryvan", "container"),
        "hardware": ("flatbed", "container", "dryvan"),
        "timber": ("flatbed", "log_trailer", "container"),
        "steel": ("flatbed", "dryvan", "container"),
        "machinery": ("flatbed", "lowboy", "dryvan", "container"),
        "industrial": ("flatbed", "container", "dryvan", "frameless_dump"),
        "aggregates": ("frameless_dump", "flatbed", "container"),
        "retail": ("dryvan", "container", "reefer", "flatbed"),
        "dry_goods": ("dryvan", "container", "reefer", "flatbed"),
        "pallets": ("dryvan", "container", "flatbed", "reefer"),
        "general": ("dryvan", "container", "flatbed", "reefer"),
        "default": ("dryvan", "flatbed", "container", "reefer", "frameless_dump", "tanker"),
    },
    "towhitch": {
        "heavy": ("boxutility_large", "cargotrailer", "boxutility", "tsfb"),
        "light": ("boxutility", "boxutility_large", "tsfb", "cargotrailer"),
    },
}

TRAILER_LABELS = {
    "dryvan": "Dry Van Trailer",
    "reefer": "Reefer Trailer",
    "tanker": "Tanker Trailer",
    "flatbed": "Flatbed Trailer",
    "container": "Container Trailer",
    "frameless_dump": "Dump Trailer",
    "log_trailer": "Log Trailer",
    "lowboy": "Lowboy Trailer",
    "boxtrailer": "Box Trailer",
    "boxutility": "Utility Trailer",
    "boxutility_large": "Large Utility Trailer",
    "cargotrailer": "Cargo Trailer",
    "tsfb": "Flatbed Utility Trailer",
}

DOMAIN_CARGO_CATALOG = {
    "food": {
        "car": [("chilled_parcels", "Fresh Food & Bakery Boxes"), ("beverages", "Cafe & Beverage Crates")],
        "van": [("groceries", "Fresh Produce & Dry Goods"), ("chilled_food", "Chilled Food & Dairy"), ("beverages", "Beverage Pallets")],
        "box_truck": [("groceries", "Fresh Produce & Dry Goods"), ("beverages", "Beverage Pallets"), ("chilled_food", "Chilled Food & Dairy")],
        "semi": [("bulk_food", "Refrigerated Food Pallets"), ("beverages", "Palletized Beverages"), ("groceries", "Fresh Produce & Dry Goods")],
    },
    "medical": {
        "car": [("medical", "Medical & Pharmacy Supplies"), ("lab_samples", "Diagnostic & Hygiene Kits")],
        "van": [("medical", "Medical & Hygiene Supplies"), ("pharma", "Temperature-Controlled Pharma")],
        "box_truck": [("medical", "Medical & Hygiene Supplies"), ("pharma", "Palletized Medical Supplies")],
        "semi": [("pharma", "Palletized Medical & Hygiene Supplies"), ("medical", "Hospital Supply Pallets")],
    },
    "hardware": {
        "car": [("auto_parts", "Express Auto & Trade Parts"), ("tools", "Hand Tools & Fasteners")],
        "van": [("hardware", "Tools, Timber & Building Supplies"), ("auto_parts", "Workshop Parts & Lubricants"), ("landscaping", "Timber & Landscaping Materials")],
        "box_truck": [("hardware", "Tools & Building Materials"), ("timber", "Packaged Timber & Framing"), ("hvac", "HVAC & Workshop Equipment")],
        "semi": [("timber", "Packaged Timber & Building Materials"), ("machinery", "Workshop & Construction Equipment"), ("steel", "Structural Hardware & Framing")],
    },
    "fuel": {
        "car": [("lubricants", "Packaged Lubricants & Forecourt Stock")],
        "van": [("lubricants", "Packaged Lubricants & Forecourt Stock")],
        "box_truck": [("fuel_drums", "Lubricant Drums & Station Stock")],
        "semi": [("fuel", "Bulk Fuel & Lubricants")],
    },
    "retail": {
        "car": [("parcels", "Courier Parcels"), ("documents", "Priority Documents")],
        "van": [("appliances", "Small Appliances"), ("electronics", "Retail Electronics")],
        "box_truck": [("pallets", "Palletized Retail Stock"), ("furniture", "Commercial Furniture")],
        "semi": [("dry_goods", "Containerized Retail Goods"), ("pallets", "General Palletized Freight")],
    },
    "industrial": {
        "car": [("auto_parts", "Express Industrial Parts"), ("parcels", "Courier Parcels")],
        "van": [("hardware", "Trade & Maintenance Supplies"), ("pallets", "Light Palletized Freight")],
        "box_truck": [("pallets", "General Palletized Freight"), ("hvac", "Industrial Equipment")],
        "semi": [("dry_goods", "Containerized Dry Goods"), ("machinery", "Industrial Machinery"), ("steel", "Structural Steel"), ("pallets", "General Palletized Freight")],
    },
    "general": {
        "car": [("parcels", "Courier Parcels"), ("documents", "Priority Documents")],
        "van": [("pallets", "General Palletized Freight"), ("electronics", "Retail & Office Supplies")],
        "box_truck": [("pallets", "General Palletized Freight"), ("dry_goods", "Palletized Mixed Freight")],
        "semi": [("pallets", "General Palletized Freight"), ("dry_goods", "Containerized Dry Goods")],
    },
}

_FOOD_TOKENS = frozenset({
    "supermarket", "grocery", "grocery_store", "convenience", "convenience_store", "bakery", "butcher", "deli",
    "greengrocer", "restaurant", "fast_food", "fast_food_restaurant", "casual_eatery", "cafe", "coffee_shop",
    "bar", "pub", "beverages", "food", "market", "farmers_market",
})
_MEDICAL_TOKENS = frozenset({
    "pharmacy", "chemist", "hospital", "clinic", "doctors", "dentist", "veterinary", "medical_supply",
    "health_and_medical", "healthcare",
})
_HARDWARE_TOKENS = frozenset({
    "hardware", "hardware_store", "building_supply_store", "diy", "doityourself", "trade", "craft", "carpenter",
    "plumber", "electrician", "car_repair", "auto_repair", "auto_parts_store", "tire_shop", "garden_centre",
    "landscaping", "lumber", "construction", "tyres",
})
_FUEL_TOKENS = frozenset({"fuel", "gas_station", "petrol_station", "oil_depot"})
_RETAIL_TOKENS = frozenset({
    "department_store", "shopping_mall", "shopping", "electronics_store", "furniture_store", "post_office",
    "retail", "commercial", "office", "clothes", "books",
})
_INDUSTRIAL_TOKENS = frozenset({
    "industrial", "warehouse", "factory", "manufacture", "depot", "storage", "hangar", "logistics_service",
    "freight_forwarding_service", "wholesale", "wholesale_store", "distribution_service",
})

BUS_CAPACITY = 40
BUS_PAX_MASS_KG = 75.0
BIDIRECTIONAL_ROAD_CLASSES = frozenset({"service", "unclassified", "track", "living_street"})
TAXI_HUB_CATS = frozenset({"airport", "train_station", "bus_station", "subway_station", "ferry_terminal", "hotel", "hospital"})
BUS_HUB_KEYWORDS = ("station", "terminal", "hub", "central", "bahnhof", "gare", "airport", "interchange", "transit center")

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
_req_tls = threading.local()
_towns_cache = None  # (ts_id, ts_len, lats_np, lons_np, names_tuple)

_CLOSED_STATUSES = frozenset({"permanently_closed", "temporarily_closed", "closed"})
_LAND_USE_CLASSES = frozenset({"industrial", "commercial", "retail"})
_PARKING_CLASSES = frozenset({"parking", "parking_space"})
_UNPAVED_SURFACES = frozenset({"grass", "dirt", "mud", "sand"})
_BUS_STOP_CLASSES = frozenset({"bus_stop", "platform", "bus_station", "stop_position"})
_BUS_HUB_CATS = frozenset({"bus_station", "station", "terminal"})
_SUBURB_SUBTYPES = frozenset({"neighborhood", "macrohood", "hamlet"})
_LOGISTICS_ALL_BLD_CLASSES = LOGISTICS_COMMERCIAL_CLASSES | LOGISTICS_HUB_CLASSES
_ADDR_HN_KEYS = ("housenumber", "number", "addr_housenumber", "addr:housenumber")
_ADDR_ST_KEYS = ("street", "addr_street", "addr:street")
_ADDR_LOC_KEYS = ("locality", "city", "addr_city", "addr:city")
_CARGO_DOMAIN_TAG_KEYS = ("amenity", "shop", "craft", "industrial", "building", "landuse", "healthcare")
_SECTOR_TAG_KEYS = ("amenity", "shop", "craft", "industrial", "landuse", "healthcare", "tourism", "railway", "public_transport", "aeroway")
_CARGO_NAME_MEDICAL = ("pharmacy", "hospital", "clinic", "medical", "apotheke")
_CARGO_NAME_FOOD = ("supermarket", "grocery", "bakery", "restaurant", "cafe", "bistro", "market")
_CARGO_NAME_HARDWARE = ("hardware", "timber", "lumber", "builder", "auto parts", "garage", "repair")
_CARGO_NAME_FUEL = ("fuel", "petrol", "shell", "bp ", "chevron", "exxon")
_CARGO_NAME_INDUSTRIAL = ("industrial", "warehouse", "logistics", "freight", "factory")
_TAXI_HUB_NAME_WORDS = ("airport", "station", "terminal", "hotel", "hospital")
_TAXI_TRANSIT_WORDS = ("airport", "station", "terminal", "ferry", "train", "rail")
_TAXI_VIP_WORDS = ("hotel", "resort", "museum", "theatre", "theater", "palace", "restaurant")
_DOMAIN_PRIORITY = {"fuel": 5, "medical": 4, "food": 4, "hardware": 3, "retail": 2, "industrial": 1, "general": 0}
_CARGO_TIER_BANDS = {"local": (0.05, 0.55), "city": (0.30, 0.75), "regional": (0.55, 0.90), "long": (0.70, 1.00)}

# Interactive OSM Fuel Stations
_FUEL_PLACE_CATS = frozenset({"gas_station", "fueling_station", "fuel", "petrol_station"})
_FUEL_INFRA_CLASSES = frozenset({"fuel", "gas_station", "fueling_station", "petrol_station"})
_FUEL_BRAND_CANON = {
    "aral": "Aral",
    "shell": "Shell",
    "esso": "Esso",
    "jet": "Jet",
    "omv": "OMV",
    "bp": "BP",
    "total": "TotalEnergies",
    "totalenergies": "TotalEnergies",
    "total energies": "TotalEnergies",
    "agip": "Agip",
    "eni": "Eni",
    "avia": "Avia",
    "bft": "bft",
    "hem": "HEM",
    "star": "Star",
    "exxon": "Exxon",
    "mobil": "Mobil",
    "chevron": "Chevron",
    "texaco": "Texaco",
    "sunoco": "Sunoco",
    "valero": "Valero",
    "marathon": "Marathon",
    "sheetz": "Sheetz",
    "circle k": "Circle K",
    "7-eleven": "7-Eleven",
    "eneos": "ENEOS",
    "q1": "Q1",
    "oil!": "OIL!",
    "gulf": "Gulf",
    "arco": "Arco",
    "conoco": "Conoco",
    "phillips 66": "Phillips 66",
    "speedway": "Speedway",
    "wawa": "Wawa",
    "casey's": "Casey's",
    "love's": "Love's",
    "racetrac": "RaceTrac",
    "maverik": "Maverik",
}
_FUEL_BRAND_WIKIDATA = {
    "Q565734": "Aral",
    "Q110716465": "Shell",
    "Q867662": "Esso",
    "Q568940": "Jet",
    "Q152057": "BP",
    "Q154037": "TotalEnergies",
    "Q377915": "Agip",
    "Q565594": "Eni",
    "Q300147": "Avia",
    "Q1009104": "bft",
    "Q109675651": "Exxon",
    "Q109676002": "Mobil",
    "Q319642": "Chevron",
    "Q775060": "Texaco",
    "Q1423218": "Sunoco",
    "Q1283291": "Valero",
    "Q458363": "Marathon",
    "Q7492551": "Sheetz",
    "Q3268010": "Circle K",
    "Q259340": "7-Eleven",
    "Q1640290": "ENEOS",
    "Q2121146": "Q1",
    "Q2007561": "OIL!",
}
FUEL_DEDUP_M = 35.0
FUEL_DEFAULT_RADIUS_M = 1500.0
FUEL_MAX_STATIONS = 16


def _get_req_cache():
    return getattr(_req_tls, "cache", None)


def _towns_arrays():
    global _towns_cache
    ts = randomplace.towns() or ()
    n = len(ts)
    if n == 0:
        return None
    ts_id = id(ts)
    cached = _towns_cache
    if cached is not None and cached[0] == ts_id and cached[1] == n:
        return cached[2], cached[3], cached[4]
    lats = np.array([t[0] for t in ts], dtype=np.float64)
    lons = np.array([t[1] for t in ts], dtype=np.float64)
    names = tuple(t[2] for t in ts)
    _towns_cache = (ts_id, n, lats, lons, names)
    return lats, lons, names


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


def _clean_vehicle(raw):
    if not isinstance(raw, dict):
        return None
    coupler = str(raw.get("coupler") or "none").strip().lower()
    if coupler not in ("none", "towhitch", "fifthwheel"):
        coupler = "none"
    mass_kg = raw.get("massKg")
    try:
        mass_kg = float(mass_kg) if mass_kg is not None else None
        if mass_kg is not None and not (math.isfinite(mass_kg) and 100.0 <= mass_kg <= 120000.0):
            mass_kg = None
    except (TypeError, ValueError):
        mass_kg = None
    vclass = str(raw.get("class") or "").strip().lower()
    if vclass not in VEHICLE_CLASSES:
        if coupler == "fifthwheel" or (mass_kg is not None and mass_kg >= 7000.0):
            vclass = "semi"
        elif mass_kg is not None and mass_kg >= 3800.0:
            vclass = "box_truck"
        elif mass_kg is not None and mass_kg >= 2200.0:
            vclass = "van"
        else:
            vclass = "car"
    tmodels = None
    raw_tm = raw.get("trailerModels")
    if isinstance(raw_tm, dict):
        tmodels = {}
        for ck in ("fifthwheel", "towhitch"):
            lst = raw_tm.get(ck)
            if isinstance(lst, list):
                cleaned = [str(m).strip().lower() for m in lst if isinstance(m, str) and m.strip()][:24]
                if cleaned:
                    tmodels[ck] = cleaned
        if not tmodels:
            tmodels = None
    return {
        "class": vclass,
        "massKg": round(mass_kg, 1) if mass_kg is not None else None,
        "coupler": coupler,
        "hasTrailer": bool(raw.get("hasTrailer")),
        "trailerModels": tmodels,
    }


def compute_dwell_target_s(mode, tier, kind, stop_type="kerbside", name="", cats=(), cargo_kg=0.0, seed=0, idx=1, leg_kind=None):
    """Compute realistic job- and cargo-scaled dwell duration (seconds) for a stop."""
    mode = str(mode or "").lower()
    tier = str(tier or "").lower()
    kind = str(kind or "").lower()
    lk = str(leg_kind or "").lower()
    nm = str(name or "").lower()
    cat_set = {str(c or "").lower() for c in (cats or ())}
    if mode == "taxi":
        is_hub = bool(cat_set & TAXI_HUB_CATS) or any(k in nm for k in _TAXI_HUB_NAME_WORDS)
        if kind == "pickup":
            return 2.5 if is_hub else (2.0 if _stable_index(seed, f"tdw:{idx}", 2) == 0 else 2.2)
        return 3.0 if (is_hub or tier in ("regional", "long")) else (2.4 if _stable_index(seed, f"tdw:{idx}", 2) == 0 else 2.6)
    if mode == "bus":
        is_hub = bool(cat_set & _BUS_HUB_CATS) or any(k in nm for k in BUS_HUB_KEYWORDS)
        if is_hub:
            return round(4.5 + 0.5 * _stable_index(seed, f"bdw:{idx}", 2), 1)
        return round(3.0 + 0.2 * _stable_index(seed, f"bdw:{idx}", 5), 1)
    if mode == "parcel":
        return 2.5
    # Logistics: trailer hookup/unhook and deadhead check-ins take ~2.5 s; solo cargo scales 3.5-8.0 s
    if lk in ("loaded_trailer", "deadhead") or kind == "deadhead":
        return 2.5
    kg = max(0.0, float(cargo_kg or 0.0))
    if lk == "loaded_solo":
        kg = min(8000.0, kg)
    if kg <= 1400.0:
        lo, hi = 3.5, 4.5
        frac = min(1.0, kg / 1400.0)
    elif kg <= 8000.0:
        lo, hi = 6.0, 8.0
        frac = min(1.0, (kg - 1400.0) / 6600.0)
    else:
        lo, hi = 9.0, 12.0
        frac = min(1.0, (kg - 8000.0) / 18000.0)
    base = lo + (hi - lo) * frac
    if kind == "delivery":
        base = max(lo, base * 0.92)
    return round(min(hi, max(lo, base)), 1)


@functools.lru_cache(maxsize=2048)
def _classify_poi_cargo_domain_cached(cat, tax, bld_class, tag_vals, nm):
    tokens = []
    if cat:
        tokens.append(cat)
    if tax:
        tokens.append(tax)
    if bld_class:
        tokens.append(bld_class)
    for val in tag_vals:
        if val:
            tokens.append(val)

    for tok_set, dom in (
        (_FUEL_TOKENS, "fuel"),
        (_MEDICAL_TOKENS, "medical"),
        (_FOOD_TOKENS, "food"),
        (_HARDWARE_TOKENS, "hardware"),
        (_RETAIL_TOKENS, "retail"),
        (_INDUSTRIAL_TOKENS, "industrial"),
    ):
        for t in tokens:
            if t in tok_set:
                return dom

    if nm:
        if any(w in nm for w in _CARGO_NAME_MEDICAL):
            return "medical"
        if any(w in nm for w in _CARGO_NAME_FOOD):
            return "food"
        if any(w in nm for w in _CARGO_NAME_HARDWARE):
            return "hardware"
        if any(w in nm for w in _CARGO_NAME_FUEL):
            return "fuel"
        if any(w in nm for w in _CARGO_NAME_INDUSTRIAL):
            return "industrial"
    return "general"


def classify_poi_cargo_domain(cat="", tax="", bld_class="", tags=None, name=""):
    """Classify an Overture/OSM POI into a semantic cargo domain ('food'|'medical'|'hardware'|'fuel'|'retail'|'industrial'|'general')."""
    c = str(cat or "").strip().lower()
    tx = str(tax or "").strip().lower()
    bc = str(bld_class or "").strip().lower()
    if isinstance(tags, dict) and tags:
        tag_vals = tuple(str(tags.get(k) or "").strip().lower() for k in _CARGO_DOMAIN_TAG_KEYS)
    else:
        tag_vals = ()
    nm = str(name or "").strip().lower()
    return _classify_poi_cargo_domain_cached(c, tx, bc, tag_vals, nm)


_SECTOR_TOKEN_RULES = (
    ("Train / Transit Station", frozenset({
        "train_station", "subway_station", "metro_station", "light_rail_station",
        "railway_station", "station", "halt", "ferry_terminal", "airport",
        "aerodrome", "bus_station", "public_transport",
    })),
    ("Bus Stop", frozenset({"bus_stop", "platform", "stop_position"})),
    ("Supermarket", frozenset({"supermarket", "grocery_store", "hypermarket"})),
    ("Bakery", frozenset({"bakery"})),
    ("Pharmacy", frozenset({"pharmacy", "chemist"})),
    ("Hospital / Clinic", frozenset({"hospital", "clinic", "doctors", "medical_center"})),
    ("Fuel Station", frozenset({"fuel", "gas_station", "charging_station", "petrol_station"})),
    ("Hotel", frozenset({"hotel", "motel", "hostel", "resort", "lodging", "guest_house"})),
    ("Restaurant / Inn", frozenset({
        "restaurant", "fast_food", "fast_food_restaurant", "casual_eatery",
        "cafe", "coffee_shop", "bar", "pub", "biergarten", "bistro", "inn",
    })),
    ("Workshop / Hardware", frozenset({
        "hardware_store", "doityourself", "building_supply_store", "auto_repair",
        "car_repair", "auto_parts_store", "workshop", "garage", "carpenter", "craft",
    })),
    ("Logistics Depot", frozenset({
        "warehouse", "depot", "freight_forwarding_service", "logistics_service",
        "distribution_service", "courier_service", "industrial", "factory",
        "manufacture", "storage", "hangar", "wholesale", "wholesale_store",
    })),
    ("Retail Store", frozenset({
        "convenience_store", "department_store", "shopping_mall", "furniture_store",
        "electronics_store", "retail", "commercial", "mall", "market",
        "farmers_market", "deli", "post_office",
    })),
)

_SECTOR_NAME_KEYWORDS = (
    ("Train / Transit Station", ("bahnhof", "station", "terminal", "airport", "ferry")),
    ("Pharmacy", ("pharmacy", "apotheke", "chemist")),
    ("Bakery", ("bakery", "bäckerei", "backerei", "boulangerie", "patisserie")),
    ("Supermarket", ("supermarket", "grocery", "edeka", "rewe", "aldi", "lidl", "kaufland")),
    ("Fuel Station", ("fuel", "petrol", "shell", "aral", "esso", "total", "tankstelle")),
    ("Hotel", ("hotel", "motel", "hostel", "resort")),
    ("Restaurant / Inn", ("restaurant", "gasthof", "wirtshaus", "bistro", "cafe", "café", "pizzeria")),
    ("Workshop / Hardware", ("hardware", "workshop", "werkstatt", "garage", "auto parts", "bauhaus", "obi")),
    ("Logistics Depot", ("warehouse", "logistics", "freight", "depot", "spedition", "industrial")),
)


@functools.lru_cache(maxsize=2048)
def _derive_sector_label_cached(cat, tax, bld_class, tag_vals, nm, kind, stop_type):
    tokens = []
    if cat:
        tokens.append(cat)
    if tax:
        tokens.append(tax)
    if bld_class:
        tokens.append(bld_class)
    for val in tag_vals:
        if val:
            tokens.append(val)

    for label, tok_set in _SECTOR_TOKEN_RULES:
        for t in tokens:
            if t in tok_set:
                return label

    if nm:
        for label, words in _SECTOR_NAME_KEYWORDS:
            if any(w in nm for w in words):
                return label

    if kind == "bus_stop":
        return "Bus Stop"
    if stop_type == "loading_bay" and kind in ("loading", "delivery"):
        return "Logistics Depot"
    return ""


def derive_sector_label(cat="", tax="", bld_class="", tags=None, name="", kind="", stop_type=""):
    """Derive a clean human-readable business/POI sector label from Overture/OSM metadata."""
    c = str(cat or "").strip().lower()
    tx = str(tax or "").strip().lower()
    bc = str(bld_class or "").strip().lower()
    if isinstance(tags, dict) and tags:
        tag_vals = tuple(str(tags.get(k) or "").strip().lower() for k in _SECTOR_TAG_KEYS)
    else:
        tag_vals = ()
    nm = str(name or "").strip().lower()
    return _derive_sector_label_cached(c, tx, bc, tag_vals, nm, kind, stop_type)


def generate_cargo_manifest(vehicle, tier, seed, dest_domain="general"):
    """Select realistic, destination-matched cargo type and tonnage for the player's vehicle."""
    v = vehicle or {"class": "van", "coupler": "none", "hasTrailer": False}
    vclass = v.get("class") if v.get("class") in VEHICLE_CLASSES else "van"
    coupler = v.get("coupler") or "none"
    has_trailer = bool(v.get("hasTrailer"))
    tier_l = str(tier or "local").lower()

    if coupler == "towhitch" and not has_trailer:
        roll = _stable_index(seed, f"towhitch_var:{tier_l}", 100)
        thresh = 60 if tier_l == "local" else 75
        use_trailer = roll < thresh
        if use_trailer:
            lo, hi = (800, 2400) if vclass != "car" else (450, 1200)
        else:
            lo, hi = (350, 1400) if vclass != "car" else (80, 350)
    else:
        use_trailer = (coupler == "fifthwheel") or has_trailer
        lo, hi = CARGO_BANDS[vclass]
        if vclass == "semi" and coupler != "fifthwheel" and not has_trailer:
            lo, hi = SEMI_BOBTAIL_BAND

    f_lo, f_hi = _CARGO_TIER_BANDS.get(tier_l, (0.25, 0.75))
    u = _stable_index(seed, f"cargo_w:{vclass}:{tier_l}", 101) / 100.0
    frac = f_lo + (f_hi - f_lo) * u
    raw_kg = lo + (hi - lo) * frac
    mass_kg = int(max(lo, min(hi, round(raw_kg / 10.0) * 10)))

    dom = dest_domain if dest_domain in DOMAIN_CARGO_CATALOG else "general"
    catalog = DOMAIN_CARGO_CATALOG[dom].get(vclass) or DOMAIN_CARGO_CATALOG["general"][vclass]
    ctype, clabel = catalog[_stable_index(seed, f"cargo_t:{dom}:{vclass}:{tier_l}", len(catalog))]
    return {
        "type": ctype,
        "label": clabel,
        "domain": dom,
        "massKg": mass_kg,
        "vehicleClass": vclass,
        "useTrailer": bool(use_trailer),
    }


_FRAGILE_LABEL = "Zerbrechlich · Sanft fahren (+35% Bonus)"
_HAZMAT_LABEL = "Gefahrgut · Vorsichtig fahren (+50% Bonus)"


def assign_cargo_sensitivity(mode, tier, domain="general", cargo_type="", seed=0):
    """Deterministically assign standard/fragile/hazmat sensitivity on city+ tiers.

    Hazmat is exclusive to commercial logistics jobs and never spawned on
    residential parcel deliveries; parcel deliveries can still spawn fragile.
    """
    mode_l = str(mode or "").lower()
    tier_l = str(tier or "").lower()
    if mode_l not in ("logistics", "parcel") or tier_l not in ("city", "regional", "long"):
        return {"cargoSensitivity": "standard", "sensitivityLabel": "", "hazardBonusMult": 0.0}

    roll = _stable_index(seed, f"cargo_sens:{mode_l}:{tier_l}:{domain}:{cargo_type}", 100)
    if mode_l == "logistics" and roll < 20:
        sens = "hazmat"
        mult = 0.50
        label = _HAZMAT_LABEL
    elif (mode_l == "logistics" and roll < 55) or (mode_l == "parcel" and roll < 35):
        sens = "fragile"
        mult = 0.35
        label = _FRAGILE_LABEL
    else:
        sens = "standard"
        mult = 0.0
        label = ""
    return {"cargoSensitivity": sens, "sensitivityLabel": label, "hazardBonusMult": mult}


def pick_trailer_model(coupler, cargo_type, cargo_domain, tier, seed, installed_models=None):
    """Select an appropriate trailer JBeam model and display label for a leg."""
    coupler = str(coupler or "none").lower()
    if coupler not in ("fifthwheel", "towhitch"):
        return None, None
    installed = None
    if isinstance(installed_models, dict):
        cand = installed_models.get(coupler)
        if isinstance(cand, (list, tuple)) and cand:
            installed = [str(m).lower() for m in cand if m]
    if coupler == "fifthwheel":
        fw = TRAILER_CANDIDATES["fifthwheel"]
        base_list = list(fw.get(cargo_type) or fw.get(cargo_domain) or fw["default"])
        if installed is not None:
            avail = [m for m in base_list if m in installed]
            if not avail:
                avail = list(installed)
        else:
            avail = base_list
        if not avail:
            return None, None
        if len(avail) > 1 and cargo_type != "fuel" and cargo_domain != "fuel":
            model = avail[_stable_index(seed, f"fw_m:{cargo_type}:{cargo_domain}", min(2, len(avail)))]
        else:
            model = avail[0]
    else:
        tw = TRAILER_CANDIDATES["towhitch"]
        tier_l = str(tier or "local").lower()
        base_list = list(tw["heavy"] if tier_l in ("city", "regional", "long") else tw["light"])
        if installed is not None:
            avail = [m for m in base_list if m in installed]
            if not avail:
                avail = list(installed)
        else:
            avail = base_list
        if not avail:
            return None, None
        model = avail[_stable_index(seed, f"tw_m:{tier_l}:{cargo_type}", len(avail))]
    label = TRAILER_LABELS.get(model) or f"{model.replace('_', ' ').title()} Trailer"
    return model, label


def validate_request(msg):
    """Validate incoming transport_job dict -> (cleaned_dict, None) or (None, error_str)."""
    if not isinstance(msg, dict):
        return None, "invalid request"
    mode = str(msg.get("mode") or "").strip().lower()
    if mode not in TIERS:
        return None, f"unknown mode {mode!r}"
    tier = str(msg.get("tier") or "").strip().lower()
    if mode == "taxi" and tier == "neighborhood":
        tier = "short"
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
    vehicle = _clean_vehicle(msg.get("vehicle"))
    return {"mode": mode, "tier": tier, "lat": lat, "lon": lon, "heading": heading, "seed": seed, "vehicle": vehicle}, None


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
    rc = _get_req_cache()
    if rc is not None:
        ck = (id(md), key, layer)
        cells_map = rc["cells"]
        if ck in cells_map:
            return cells_map[ck]
    if not md.has(key, layer) and time.monotonic() > deadline:
        return None
    try:
        res = md.cell(key, layers=(layer,), kind="demand").layers.get(layer)
    except Exception as e:
        log.debug("transport cell %s/%s: %s: %s", key, layer, type(e).__name__, e)
        res = None
    if rc is not None:
        rc["cells"][(id(md), key, layer)] = res
    return res


def _col(attrs, name, n):
    v = attrs.get(name) if attrs else None
    return v if v is not None else [""] * n


def _tags_dict(attrs, i):
    tags = attrs.get("tags") if attrs else None
    if tags is None:
        return {}
    rc = _get_req_cache()
    if rc is not None:
        tk = (id(attrs), i)
        tags_map = rc["tags"]
        if tk in tags_map:
            return tags_map[tk]
    raw = tags[i]
    out = {}
    if isinstance(raw, dict):
        out = {str(k).lower(): str(v).lower() for k, v in raw.items()}
    else:
        try:
            parsed = json.loads(str(raw))
            if isinstance(parsed, dict):
                out = {str(k).lower(): str(v).lower() for k, v in parsed.items()}
        except (TypeError, ValueError):
            pass
    if rc is not None:
        rc["tags"][(id(attrs), i)] = out
    return out


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
                    if not nm or st in _CLOSED_STATUSES:
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
                        "tags": _tags_dict(attrs, i),
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
                    bld_out.append({"name": nm, "class": cls, "tags": _tags_dict(attrs, i), "lat": pt[0], "lon": pt[1]})
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
                    if cls not in _LAND_USE_CLASSES and lu_tag not in _LAND_USE_CLASSES:
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


def _point_in_ring(px, py, ring_xy):
    """Ray-casting point-in-polygon test on (k, 2) local ENU ring."""
    if len(ring_xy) < 3:
        return False
    x = ring_xy[:, 0]
    y = ring_xy[:, 1]
    x2 = np.roll(x, -1)
    y2 = np.roll(y, -1)
    cond = (y > py) != (y2 > py)
    if not cond.any():
        return False
    dy = np.where(cond, y2 - y, 1.0)
    x_int = x[cond] + (py - y[cond]) * (x2[cond] - x[cond]) / dy[cond]
    return bool(np.count_nonzero(px < x_int) & 1)


def _min_dist_ring_m(px, py, ring_xy):
    """Minimum Euclidean distance in metres from (px, py) to closed polygon boundary segments."""
    if len(ring_xy) < 2:
        return float("inf")
    if len(ring_xy) >= 3 and not np.allclose(ring_xy[0], ring_xy[-1]):
        pts = np.vstack([ring_xy, ring_xy[:1]])
    else:
        pts = ring_xy
    a, b = pts[:-1], pts[1:]
    ab = b - a
    L2 = np.maximum((ab * ab).sum(1), 1e-12)
    t = np.clip(((px - a[:, 0]) * ab[:, 0] + (py - a[:, 1]) * ab[:, 1]) / L2, 0.0, 1.0)
    dx = a[:, 0] + t * ab[:, 0] - px
    dy = a[:, 1] + t * ab[:, 1] - py
    return float(np.sqrt((dx * dx + dy * dy).min()))


def _building_polys(md, lat, lon, radius_m=140.0, deadline=None, bld_cells=None):
    """Collect nearby building footprints as (bbox, outer_xy, hole_xys) in local ENU metres around (lat, lon)."""
    if md is None:
        return []
    if deadline is None:
        deadline = time.monotonic() + DEADLINE_S
    if bld_cells is None:
        keys = _cells_around(lat, lon, radius_m, max_cells=4)
        bld_cells = [_cell_layer(md, key, "buildings", deadline) for key in keys]
    k = _cos_lat(lat)
    out = []
    seen = set()
    for f in bld_cells:
        if f is None or not len(f.ids):
            continue
        for i in range(len(f.ids)):
            fid = str(f.ids[i])
            if fid in seen:
                continue
            seen.add(fid)
            parts = f.parts(i) if hasattr(f, "parts") else None
            if not parts:
                continue
            for part in parts:
                if not part or len(part[0]) < 3:
                    continue
                outer = np.asarray(part[0], np.float64)
                oxy = np.stack([(outer[:, 0] - lon) * M_LAT * k, (outer[:, 1] - lat) * M_LAT], axis=1)
                bx0, by0 = float(oxy[:, 0].min()), float(oxy[:, 1].min())
                bx1, by1 = float(oxy[:, 0].max()), float(oxy[:, 1].max())
                if bx1 < -radius_m or bx0 > radius_m or by1 < -radius_m or by0 > radius_m:
                    continue
                holes = []
                for hring in part[1:]:
                    if len(hring) >= 3:
                        ha = np.asarray(hring, np.float64)
                        holes.append(np.stack([(ha[:, 0] - lon) * M_LAT * k, (ha[:, 1] - lat) * M_LAT], axis=1))
                out.append(((bx0, by0, bx1, by1), oxy, holes))
    return out


def _point_clear_of_buildings_xy(px, py, bld_polys, min_clear_m=BLD_CLEAR_M):
    """True when (px, py) in local ENU metres is >= min_clear_m outside every building footprint."""
    for (bx0, by0, bx1, by1), outer, holes in bld_polys:
        if px < bx0 - min_clear_m or px > bx1 + min_clear_m or py < by0 - min_clear_m or py > by1 + min_clear_m:
            continue
        inside = _point_in_ring(px, py, outer) and not any(_point_in_ring(px, py, h) for h in holes)
        if inside:
            return False
        if _min_dist_ring_m(px, py, outer) < min_clear_m:
            return False
    return True


def _clear_of_buildings(clat, clon, ref_lat, ref_lon, bld_polys, min_clear_m=BLD_CLEAR_M,
                        bearing=None, half_l=0.0, half_w=0.0):
    """Verify (clat, clon) is >= min_clear_m outside all building polygons (and bay corners clear of walls)."""
    if not bld_polys:
        return True
    k = _cos_lat(ref_lat)
    px = (clon - ref_lon) * M_LAT * k
    py = (clat - ref_lat) * M_LAT
    if not _point_clear_of_buildings_xy(px, py, bld_polys, min_clear_m):
        return False
    if bearing is not None and half_l > 0.0 and half_w > 0.0:
        rad = math.radians(float(bearing))
        fx, fy = dmath.sin(rad), dmath.cos(rad)
        rx, ry = fy, -fx
        for sl in (-1.0, 1.0):
            for sw in (-1.0, 1.0):
                cx = px + sl * half_l * fx + sw * half_w * rx
                cy = py + sl * half_l * fy + sw * half_w * ry
                if not _point_clear_of_buildings_xy(cx, cy, bld_polys, 0.5):
                    return False
    return True


def _apply_curb_offset(snapped, poi_lat=None, poi_lon=None, ref_lat=None, ref_lon=None, bld_polys=None):
    """Offset a road-snapped stop to the right-hand curb/bay edge along road bearing, clear of buildings."""
    if not snapped:
        return None
    brg = float(snapped.get("bearing") or 0.0) % 360.0
    slat, slon = float(snapped["lat"]), float(snapped["lon"])
    # On two-way roads, orient bearing so the right-hand curb (+90 deg) faces the POI/platform side
    if poi_lat is not None and poi_lon is not None and not snapped.get("oneway"):
        if dist_m(slat, slon, poi_lat, poi_lon) >= 1.5:
            to_poi = bearing_deg(slat, slon, poi_lat, poi_lon)
            right_brg = (brg + 90.0) % 360.0
            if _heading_diff(right_brg, to_poi) > 90.0:
                brg = (brg + 180.0) % 360.0
    half_w = _ROAD_HALF_W.get(str(snapped.get("roadClass") or "").lower(), 2.75)
    target_off = max(1.6, min(3.5, half_w - 0.7))
    right_brg = (brg + 90.0) % 360.0
    rlat, rlon = (ref_lat, ref_lon) if (ref_lat is not None and ref_lon is not None) else (slat, slon)

    chosen_lat, chosen_lon = slat, slon
    for frac in (1.0, 0.7, 0.4, 0.0):
        off = target_off * frac
        clat, clon = offset_latlon(slat, slon, off, right_brg) if off > 0.0 else (slat, slon)
        if not bld_polys or _clear_of_buildings(clat, clon, rlat, rlon, bld_polys, BLD_CLEAR_M):
            chosen_lat, chosen_lon = clat, clon
            break
    return {
        **snapped,
        "lat": round(float(chosen_lat), 6),
        "lon": round(float(chosen_lon), 6),
        "bearing": round(brg, 1),
        "stopType": snapped.get("stopType") or "kerbside",
    }


def _snap_site_aisle(md, poi_lat, poi_lon, road_cells, bld_polys, max_dist_m=SITE_SEARCH_M):
    """Snap to a drivable on-site service / parking_aisle / driveway segment within max_dist_m, clear of buildings."""
    k = _cos_lat(poi_lat)
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
            sc = _road_subclass(f, i)
            if sc in NON_VEHICLE_SUBCLASSES:
                continue
            if not (c == "service" or sc in ("parking_aisle", "driveway")):
                continue
            for ring in _ground_rings(f, i):
                arr = np.asarray(ring, np.float64)
                if len(arr) < 2:
                    continue
                xy = np.stack([(arr[:, 0] - poi_lon) * M_LAT * k, (arr[:, 1] - poi_lat) * M_LAT], axis=1)
                diffs = np.diff(xy, axis=0)
                seg_lens = np.hypot(diffs[:, 0], diffs[:, 1])
                s = np.r_[0.0, np.cumsum(seg_lens)]
                if s[-1] < 5.0:
                    continue
                d, j, t = _seg_nearest(xy, np.zeros(2))
                if d > max_dist_m:
                    continue
                end_clr = min(6.0, s[-1] * 0.2)
                at0 = min(max(s[j] + t * (s[j + 1] - s[j]), end_clr), s[-1] - end_clr)
                cand_s = [at0, s[-1] * 0.5, end_clr, s[-1] - end_clr]
                for at in cand_s:
                    qx = float(np.interp(at, s, xy[:, 0]))
                    qy = float(np.interp(at, s, xy[:, 1]))
                    cd = math.hypot(qx, qy)
                    if cd > max_dist_m:
                        continue
                    sj = max(0, min(len(diffs) - 1, int(np.searchsorted(s, at) - 1)))
                    seg_dx, seg_dy = float(diffs[sj, 0]), float(diffs[sj, 1])
                    brg = (math.degrees(math.atan2(seg_dx, seg_dy)) + 360.0) % 360.0 if (seg_dx * seg_dx + seg_dy * seg_dy) > 1e-6 else 0.0
                    slat = float(poi_lat + qy / M_LAT)
                    slon = float(poi_lon + qx / (M_LAT * k))
                    if not _clear_of_buildings(slat, slon, poi_lat, poi_lon, bld_polys, BLD_CLEAR_M, brg, 3.5, 1.5):
                        continue
                    prio_pen = 0.0 if sc in ("parking_aisle", "driveway") else 6.0
                    score = cd + prio_pen
                    if best is None or score < best[0]:
                        rname = _clean(name_col[i]) or ("Loading Bay" if sc == "driveway" else "Service Bay")
                        best = (score, {
                            "lat": round(slat, 6), "lon": round(slon, 6),
                            "road": rname, "roadClass": c or "service",
                            "bearing": round(brg, 1), "snapDistM": round(cd, 1),
                            "stopType": "loading_bay",
                        })
                    break
    return best[1] if best else None


def _snap_parking_lot(md, poi_lat, poi_lon, infra_cells, land_cells, road_cells, bld_polys, max_dist_m=SITE_SEARCH_M):
    """Find a clear loading/parking bay inside a mapped parking lot polygon within max_dist_m."""
    k = _cos_lat(poi_lat)
    best = None
    for cells in (infra_cells, land_cells):
        for f in cells:
            if f is None or not len(f.ids):
                continue
            attrs = getattr(f, "attrs", {}) or {}
            n = len(f.ids)
            cls_col = _col(attrs, "class", n)
            surf_col = _col(attrs, "surface", n)
            name_col = _col(attrs, "name", n)
            for i in range(n):
                cls = str(cls_col[i] or "").strip().lower()
                tags = _tags_dict(attrs, i)
                if cls not in _PARKING_CLASSES and tags.get("amenity") != "parking":
                    continue
                if str(surf_col[i] or "").strip().lower() in _UNPAVED_SURFACES:
                    continue
                parts = f.parts(i) if hasattr(f, "parts") else None
                if not parts or not parts[0] or len(parts[0][0]) < 3:
                    continue
                outer = np.asarray(parts[0][0], np.float64)
                oxy = np.stack([(outer[:, 0] - poi_lon) * M_LAT * k, (outer[:, 1] - poi_lat) * M_LAT], axis=1)
                if oxy[:, 0].max() < -max_dist_m or oxy[:, 0].min() > max_dist_m or oxy[:, 1].max() < -max_dist_m or oxy[:, 1].min() > max_dist_m:
                    continue
                pts = np.vstack([oxy, oxy[:1]]) if not np.allclose(oxy[0], oxy[-1]) else oxy
                edges = np.diff(pts, axis=0)
                elens = np.hypot(edges[:, 0], edges[:, 1])
                if not len(elens) or elens.max() < 3.0:
                    continue
                li = int(elens.argmax())
                brg = (math.degrees(math.atan2(float(edges[li, 0]), float(edges[li, 1]))) + 360.0) % 360.0
                cx, cy = float(oxy[:, 0].mean()), float(oxy[:, 1].mean())
                cands = [(0.0, 0.0)]
                _, nj, nt = _seg_nearest(pts, np.zeros(2))
                ex = float(pts[nj, 0] + nt * edges[nj, 0])
                ey = float(pts[nj, 1] + nt * edges[nj, 1])
                in_dx, in_dy = cx - ex, cy - ey
                in_len = math.hypot(in_dx, in_dy)
                if in_len > 1.0:
                    cands.append((ex + (in_dx / in_len) * min(4.0, in_len * 0.5), ey + (in_dy / in_len) * min(4.0, in_len * 0.5)))
                cands.extend([(cx * 0.5, cy * 0.5), (cx, cy)])
                for px, py in cands:
                    d = math.hypot(px, py)
                    if d > max_dist_m:
                        continue
                    if not _point_in_ring(px, py, oxy):
                        continue
                    slat = float(poi_lat + py / M_LAT)
                    slon = float(poi_lon + px / (M_LAT * k))
                    if not _clear_of_buildings(slat, slon, poi_lat, poi_lon, bld_polys, BLD_CLEAR_M, brg, 3.5, 1.5):
                        continue
                    near_road = snap_to_road(md, slat, slon, radius_m=85.0, classes=LOGISTICS_FALLBACK_CLASSES, road_cells=road_cells)
                    if not near_road:
                        continue
                    if best is None or d < best[0]:
                        nm = _clean(name_col[i]) or near_road.get("road") or "Loading Lot"
                        best = (d, {
                            "lat": round(slat, 6), "lon": round(slon, 6),
                            "road": nm, "roadClass": "service",
                            "bearing": round(brg, 1), "snapDistM": round(d, 1),
                            "stopType": "loading_bay",
                        })
                    break
    return best[1] if best else None


def _snap_building_perimeter_bay(md, poi_lat, poi_lon, road_cells, bld_polys, max_dist_m=SITE_SEARCH_M):
    """Place a loading bay outside the road-facing perimeter of a nearby building (>= 2.5 m clear of all walls)."""
    if not bld_polys:
        return None
    road_ref = snap_to_road(md, poi_lat, poi_lon, radius_m=120.0, classes=LOGISTICS_FALLBACK_CLASSES, road_cells=road_cells)
    if not road_ref:
        return None
    k = _cos_lat(poi_lat)
    rx = (road_ref["lon"] - poi_lon) * M_LAT * k
    ry = (road_ref["lat"] - poi_lat) * M_LAT

    best = None
    for (bx0, by0, bx1, by1), outer, _ in bld_polys:
        if bx1 < -max_dist_m or bx0 > max_dist_m or by1 < -max_dist_m or by0 > max_dist_m:
            continue
        pts = np.vstack([outer, outer[:1]]) if not np.allclose(outer[0], outer[-1]) else outer
        for j in range(len(pts) - 1):
            ax, ay = float(pts[j, 0]), float(pts[j, 1])
            bx, by = float(pts[j + 1, 0]), float(pts[j + 1, 1])
            ex, ey = bx - ax, by - ay
            elen = math.hypot(ex, ey)
            if elen < 6.0:
                continue
            mx, my = 0.5 * (ax + bx), 0.5 * (ay + by)
            nx, ny = -ey / elen, ex / elen
            if _point_in_ring(mx + nx * 1.0, my + ny * 1.0, outer):
                nx, ny = -nx, -ny
            if _point_in_ring(mx + nx * 1.0, my + ny * 1.0, outer):
                continue
            px, py = mx + nx * 4.5, my + ny * 4.5
            d_poi = math.hypot(px, py)
            if d_poi > max_dist_m:
                continue
            if math.hypot(px - rx, py - ry) < 4.5:
                continue
            brg = (math.degrees(math.atan2(ex, ey)) + 360.0) % 360.0
            slat = float(poi_lat + py / M_LAT)
            slon = float(poi_lon + px / (M_LAT * k))
            if not _clear_of_buildings(slat, slon, poi_lat, poi_lon, bld_polys, BLD_CLEAR_M, brg, 3.5, 1.5):
                continue
            to_road = math.hypot(rx - px, ry - py)
            score = d_poi + 0.35 * to_road
            if best is None or score < best[0]:
                best = (score, {
                    "lat": round(slat, 6), "lon": round(slon, 6),
                    "road": road_ref.get("road") or "Loading Bay",
                    "roadClass": road_ref.get("roadClass") or "service",
                    "bearing": round(brg, 1), "snapDistM": round(d_poi, 1),
                    "stopType": "loading_bay",
                })
    return best[1] if best else None


def _snap_logistics_spot(md, poi_lat, poi_lon, deadline, road_cells=None, bld_cells=None, infra_cells=None, land_cells=None):
    """Resolve Logistics stop: prefer on-site aisle/driveway -> parking lot -> building perimeter -> kerbside."""
    keys = _cells_around(poi_lat, poi_lon, 180.0, max_cells=4)
    if road_cells is None:
        road_cells = [_cell_layer(md, key, "roads", deadline) for key in keys]
    if bld_cells is None:
        bld_cells = [_cell_layer(md, key, "buildings", deadline) for key in keys]
    bld_polys = _building_polys(md, poi_lat, poi_lon, radius_m=140.0, deadline=deadline, bld_cells=bld_cells)

    site = _snap_site_aisle(md, poi_lat, poi_lon, road_cells, bld_polys, max_dist_m=SITE_SEARCH_M)
    if site:
        return site

    if infra_cells is None:
        infra_cells = [_cell_layer(md, key, "infrastructure", deadline) for key in keys]
    if land_cells is None:
        land_cells = [_cell_layer(md, key, "land_use", deadline) for key in keys]
    lot = _snap_parking_lot(md, poi_lat, poi_lon, infra_cells, land_cells, road_cells, bld_polys, max_dist_m=SITE_SEARCH_M)
    if lot:
        return lot

    perim = _snap_building_perimeter_bay(md, poi_lat, poi_lon, road_cells, bld_polys, max_dist_m=SITE_SEARCH_M)
    if perim:
        return perim

    snapped = snap_to_road(md, poi_lat, poi_lon, radius_m=300.0, classes=LOGISTICS_FALLBACK_CLASSES,
                           deadline=deadline, road_cells=road_cells)
    if not snapped:
        return None
    curb = _apply_curb_offset(snapped, poi_lat, poi_lon, poi_lat, poi_lon, bld_polys)
    curb["stopType"] = "kerbside"
    return curb


def _resolve_locality(md, lat, lon, deadline, town_hint="", cell_cache=None):
    """Resolve nearest town/village and optional district/suburb (e.g. 'Sindelsdorf' or 'Penzberg · Dittenried')."""
    rc = _get_req_cache()
    lk = None
    if rc is not None:
        lk = (id(md), round(lat, 3), round(lon, 3), town_hint)
        if lk in rc["locality"]:
            return rc["locality"][lk]

    keys = _cells_around(lat, lon, 1200.0, max_cells=4)

    def _get_layer(k, layer):
        if cell_cache is not None:
            ck = (k, layer)
            if ck in cell_cache:
                return cell_cache[ck]
        f = _cell_layer(md, k, layer, deadline) if (md is not None and (md.has(k, layer) or time.monotonic() <= deadline)) else None
        if cell_cache is not None:
            cell_cache[(k, layer)] = f
        return f

    best_town = None    # (dist_m, name)
    best_suburb = None  # (dist_m, name)
    for k in keys:
        tp = _get_layer(k, "town_points")
        if tp is not None and len(getattr(tp, "ids", ())):
            attrs = getattr(tp, "attrs", {}) or {}
            n = len(tp.ids)
            names = _col(attrs, "name", n)
            subtypes = _col(attrs, "subtype", n)
            for i in range(n):
                nm = _clean(names[i])
                if not nm:
                    continue
                pt = _feature_center(tp, i)
                if not pt:
                    continue
                d = dist_m(lat, lon, pt[0], pt[1])
                st = str(subtypes[i] or "").strip().lower()
                if st in _SUBURB_SUBTYPES and d <= 2500.0:
                    if best_suburb is None or d < best_suburb[0]:
                        best_suburb = (d, nm)
                elif d <= 8000.0:
                    if best_town is None or d < best_town[0]:
                        best_town = (d, nm)

        hd = _get_layer(k, "hoods")
        if hd is not None and len(getattr(hd, "ids", ())):
            attrs = getattr(hd, "attrs", {}) or {}
            n = len(hd.ids)
            names = _col(attrs, "name", n)
            for i in range(n):
                nm = _clean(names[i])
                if not nm:
                    continue
                pt = _feature_center(hd, i)
                if not pt:
                    continue
                d = dist_m(lat, lon, pt[0], pt[1])
                if d <= 2500.0 and (best_suburb is None or d < best_suburb[0]):
                    best_suburb = (d, nm)

    town_name = best_town[1] if best_town else _clean(town_hint)
    if not town_name:
        ta = _towns_arrays()
        if ta is not None:
            t_lats, t_lons, t_names = ta
            dlat_b = 15000.0 / M_LAT
            dlon_b = 15000.0 / (M_LAT * _cos_lat(lat))
            cand_idx = np.flatnonzero((np.abs(t_lats - lat) <= dlat_b) & (np.abs(t_lons - lon) <= dlon_b))
            best_ne = None
            for idx_t in cand_idx.tolist():
                d = dist_m(lat, lon, float(t_lats[idx_t]), float(t_lons[idx_t]))
                if d <= 15000.0 and (best_ne is None or d < best_ne[0]):
                    best_ne = (d, t_names[idx_t])
            if best_ne:
                town_name = _clean(best_ne[1])

    suburb_name = best_suburb[1] if best_suburb else ""
    if town_name and suburb_name and town_name.lower() != suburb_name.lower():
        res_loc = f"{town_name} · {suburb_name}"
    else:
        res_loc = town_name or suburb_name or ""
    if lk is not None:
        rc["locality"][lk] = res_loc
    return res_loc


def _enrich_stops_locality(md, stops, deadline):
    """Populate optional 'locality' on every stop in-place using a shared cell cache."""
    if not stops:
        return stops
    cache = {}
    for s in stops:
        hint = s.get("locality") or ""
        loc = _resolve_locality(md, s["lat"], s["lon"], deadline, town_hint=hint, cell_cache=cache)
        if loc:
            s["locality"] = loc
        else:
            s.pop("locality", None)
    return stops


def _make_stop(idx, kind, name, snapped, address="", zone_radius=12.0, stop_type=None, dwell_target_s=None, poi_domain=None, locality="", sector_label=""):
    road = snapped.get("road") or ""
    road_cls = str(snapped.get("roadClass") or "").strip().lower()
    addr = address or road or f"{snapped['lat']:.5f}, {snapped['lon']:.5f}"
    st = stop_type or snapped.get("stopType") or "kerbside"
    bidir = (road_cls in BIDIRECTIONAL_ROAD_CLASSES) or (st == "loading_bay")
    stop = {
        "index": int(idx),
        "kind": kind,
        "stopType": st,
        "name": _clean(name) or road or f"Stop {idx}",
        "address": addr,
        "lat": round(float(snapped["lat"]), 6),
        "lon": round(float(snapped["lon"]), 6),
        "road": road,
        "roadClass": road_cls,
        "bidirectional": bool(bidir),
        "bearing": round(float(snapped.get("bearing") or 0.0), 1),
        "zoneRadius": float(zone_radius),
    }
    if dwell_target_s is not None:
        stop["dwellTargetS"] = round(float(dwell_target_s), 1)
    if poi_domain:
        stop["_poiDomain"] = poi_domain
    loc_clean = _clean(locality)
    if loc_clean:
        stop["locality"] = loc_clean
    sec_clean = _clean(sector_label)
    if sec_clean:
        stop["sectorLabel"] = sec_clean
    return stop


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
    bld_cells = [_cell_layer(md, k, "buildings", deadline) for k in keys]
    places_out, bld_out, _ = _collect_pois_in_cells(md, keys, ("places", "buildings"), deadline)

    candidates = []
    for p in places_out:
        d = dist_m(ref_lat, ref_lon, p["lat"], p["lon"])
        if min_m <= d <= max_m:
            prio = 2 if (p["cat"] in TAXI_PLACE_CATS or p["tax"] in TAXI_PLACE_CATS) else 1
            sec = derive_sector_label(p["cat"], p["tax"], "", p.get("tags"), p["name"])
            candidates.append((prio, p["conf"], d, p["lat"], p["lon"], p["name"], sec))
    for b in bld_out:
        if not b["name"]:
            continue
        d = dist_m(ref_lat, ref_lon, b["lat"], b["lon"])
        if min_m <= d <= max_m:
            sec = derive_sector_label("", "", b["class"], b.get("tags"), b["name"])
            candidates.append((0, 0.5, d, b["lat"], b["lon"], b["name"], sec))

    candidates.sort(key=lambda c: (-c[0], -c[1], c[5], c[3]))
    if candidates:
        pool = candidates[:min(8, len(candidates))]
        for attempt in range(len(pool)):
            pick = pool[(_stable_index(seed, tag, len(pool)) + attempt) % len(pool)]
            snapped = snap_to_road(md, pick[3], pick[4], radius_m=280.0, deadline=deadline, road_cells=road_cells)
            if snapped and min_m <= dist_m(ref_lat, ref_lon, snapped["lat"], snapped["lon"]) <= max_m * 1.25:
                bld_polys = _building_polys(md, snapped["lat"], snapped["lon"], radius_m=100.0, deadline=deadline, bld_cells=bld_cells)
                curb = _apply_curb_offset(snapped, pick[3], pick[4], snapped["lat"], snapped["lon"], bld_polys)
                if pick[6]:
                    curb["_sector"] = pick[6]
                return pick[5], curb

    # Fallback directly onto drivable ground roads inside the target box
    rc = _road_candidates(md, ref_lat, ref_lon, min_m, max_m, deadline=deadline) if anchor_lat == ref_lat and anchor_lon == ref_lon else []
    if rc:
        pick = rc[_stable_index(seed, tag + ":rc", len(rc))]
        bld_polys = _building_polys(md, pick["lat"], pick["lon"], radius_m=100.0, deadline=deadline, bld_cells=bld_cells)
        return pick["name"], _apply_curb_offset(pick, ref_lat, ref_lon, pick["lat"], pick["lon"], bld_polys)
    snapped = snap_to_road(md, anchor_lat, anchor_lon, radius_m=1500.0, deadline=deadline, road_cells=road_cells)
    if snapped:
        d = dist_m(ref_lat, ref_lon, snapped["lat"], snapped["lon"])
        if d >= max(150.0, min_m * 0.6):
            bld_polys = _building_polys(md, snapped["lat"], snapped["lon"], radius_m=100.0, deadline=deadline, bld_cells=bld_cells)
            return (snapped["road"] or fallback_name), _apply_curb_offset(snapped, anchor_lat, anchor_lon, snapped["lat"], snapped["lon"], bld_polys)
    return None


def _select_taxi_ride_profile(pu_name, do_name, tier, seed):
    """Deterministically select taxi ride archetype (standard/express/vip) and passenger load (1-3 pax, 80-240 kg)."""
    combined = f"{pu_name} {do_name}".lower()
    is_transit_hub = any(k in combined for k in _TAXI_TRANSIT_WORDS)
    is_vip_venue = any(k in combined for k in _TAXI_VIP_WORDS)
    roll = _stable_index(seed, f"taxi_arch:{tier}", 100)
    if is_transit_hub and roll < 55:
        arch = "express"
    elif is_vip_venue and roll < 50:
        arch = "vip"
    elif roll < 28:
        arch = "express"
    elif roll < 52:
        arch = "vip"
    else:
        arch = "standard"

    if arch == "express":
        profile = {"archetype": "express", "label": "Airport / Station Express", "targetMult": 0.80, "fareMult": 1.40, "tipMult": 1.0}
    elif arch == "vip":
        profile = {"archetype": "vip", "label": "VIP Comfort Ride", "targetMult": 1.0, "fareMult": 1.0, "tipMult": 1.35}
    else:
        profile = {"archetype": "standard", "label": "Standard Ride", "targetMult": 1.0, "fareMult": 1.0, "tipMult": 1.0}

    pax_count = 1 + _stable_index(seed, f"taxi_pax:{tier}", 3)
    profile["paxCount"] = pax_count
    profile["paxMassKg"] = pax_count * 80
    return profile


def _towns_in_band(lat, lon, min_km, max_km, heading, seed, tag):
    """Rank Natural Earth populated places in [min_km, max_km], biased gently toward heading."""
    ta = _towns_arrays()
    if ta is None:
        return []
    t_lats, t_lons, t_names = ta
    min_m, max_m = min_km * 1000.0, max_km * 1000.0
    dlat_b = max_m / M_LAT + 0.05
    dlon_b = max_m / (M_LAT * _cos_lat(lat)) + 0.05
    cand_idx = np.flatnonzero((np.abs(t_lats - lat) <= dlat_b) & (np.abs(t_lons - lon) <= dlon_b))
    if not len(cand_idx):
        return []
    hits = []
    mid_m = 0.5 * (min_m + max_m)
    span_m = max(1.0, max_m - min_m)
    for idx_t in cand_idx.tolist():
        tlat, tlon, tname = float(t_lats[idx_t]), float(t_lons[idx_t]), t_names[idx_t]
        d = dist_m(lat, lon, tlat, tlon)
        if min_m <= d <= max_m:
            ang = _heading_diff(heading, bearing_deg(lat, lon, tlat, tlon)) if heading is not None else 0.0
            score = abs(d - mid_m) / span_m + (ang / 180.0) * 0.65
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
        bld_polys = _building_polys(md, snapped["lat"], snapped["lon"], radius_m=100.0, deadline=deadline)
        pickup = (snapped["road"] or "Roadside Pickup", _apply_curb_offset(snapped, lat, lon, snapped["lat"], snapped["lon"], bld_polys))
    pu_name, pu_snap = pickup
    pu_stop = _make_stop(1, "pickup", pu_name, pu_snap, zone_radius=12.0, sector_label=pu_snap.get("_sector", ""))

    # 2. Drop-off in the selected distance tier
    dropoff = None
    base_brg = heading if heading is not None else float(_stable_index(seed, "taxi_brg", 360))
    if tier == "short":
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
    else:  # regional (20-50 km) or long / airport (55-110 km)
        towns = _towns_in_band(pu_stop["lat"], pu_stop["lon"], min_km, max_km, heading, seed, f"taxi_{tier}")
        for _, tlat, tlon, tname in towns[:4]:
            if time.monotonic() > deadline:
                break
            dropoff = _pick_taxi_spot(
                md, tlat, tlon, min_km * 1000.0, max_km * 1000.0,
                pu_stop["lat"], pu_stop["lon"], seed, f"taxi_{tier}:{tname}", deadline, tname,
            )
            if dropoff:
                do_name, do_snap = dropoff
                if tname.lower() not in do_name.lower():
                    dropoff = (do_name, {**do_snap, "_town": tname})
                break
        if not dropoff:
            fallback_lbl = "Airport / Long Destination" if tier == "long" else "Regional Destination"
            for rot in (0.0, 45.0, -45.0, 90.0, -90.0):
                if time.monotonic() > deadline:
                    break
                dist_target = 0.5 * (min_km + max_km) * 1000.0
                alat, alon = offset_latlon(pu_stop["lat"], pu_stop["lon"], dist_target, (base_brg + rot) % 360.0)
                dropoff = _pick_taxi_spot(
                    md, alat, alon, min_km * 1000.0, max_km * 1000.0,
                    pu_stop["lat"], pu_stop["lon"], seed, f"taxi_{tier}_off:{rot}", deadline, fallback_lbl,
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
    do_stop = _make_stop(2, "dropoff", do_name, do_snap, address=do_addr, zone_radius=12.0,
                         locality=town_suffix or "", sector_label=do_snap.get("_sector", ""))
    stops = [pu_stop, do_stop]
    for s in stops:
        s["dwellTargetS"] = compute_dwell_target_s("taxi", tier, s["kind"], s["stopType"], s["name"], seed=seed, idx=s["index"])
    return {
        "ok": True,
        "mode": "taxi",
        "tier": tier,
        "title": f"{pu_stop['name']} -> {do_stop['name']}",
        "source": "overture",
        "estimatedKm": _route_estimate_km(lat, lon, stops),
        "taxi": _select_taxi_ride_profile(pu_stop["name"], do_stop["name"], tier, seed),
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
    out = []
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
            if cls not in _BUS_STOP_CLASSES and tags.get("highway") != "bus_stop":
                continue
            if tags.get("railway") == "platform" and tags.get("bus") != "yes":
                continue
            pt = _feature_center(f, i)
            if not pt:
                continue
            la, lo = pt
            # Deduplicate co-located platforms/stop_positions within 45 m
            if any(dist_m(la, lo, o["lat"], o["lon"]) <= 45.0 for o in out):
                continue
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


def _apply_bus_passengers_and_schedule(stops, lat, lon, tier, seed):
    """Assign deterministic per-stop boarding/alighting (2-12 board, 0-8 alight) and cumulative schedule targets."""
    pax = 0
    sched_s = 0.0
    prev_lat, prev_lon = lat, lon
    n = len(stops)
    for idx, s in enumerate(stops, 1):
        d_m = dist_m(prev_lat, prev_lon, s["lat"], s["lon"])
        leg_s = max(25.0, (d_m * 1.25) / 9.5)
        sched_s += leg_s
        s["targetArrivalS"] = round(sched_s, 1)
        sched_s += float(s.get("dwellTargetS") or 3.5)

        if idx == 1:
            alight = 0
        elif idx == n and tier == "full":
            alight = pax
        else:
            alight = min(pax, _stable_index(seed, f"bus_al:{idx}", 9))
        after_alight = max(0, pax - alight)
        if idx == n and tier == "full":
            board = 0
        else:
            want_board = 2 + _stable_index(seed, f"bus_bd:{idx}", 11)
            board = min(BUS_CAPACITY - after_alight, want_board)
        pax = after_alight + board
        s["paxAlight"] = int(alight)
        s["paxBoard"] = int(board)
        s["paxAfter"] = int(pax)
        prev_lat, prev_lon = s["lat"], s["lon"]
    return {"capacity": BUS_CAPACITY, "paxMassPerPaxKg": BUS_PAX_MASS_KG}


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
        bld_cache = {}
        snapped_stops = []
        for idx, s in enumerate(raw_stops, 1):
            ckeys = _cells_around(s["lat"], s["lon"], 150.0, max_cells=4)
            rcells = []
            bcells = []
            for ckey in ckeys:
                if ckey not in road_cache and time.monotonic() <= deadline:
                    road_cache[ckey] = _cell_layer(md, ckey, "roads", deadline)
                if ckey not in bld_cache and time.monotonic() <= deadline:
                    bld_cache[ckey] = _cell_layer(md, ckey, "buildings", deadline)
                if road_cache.get(ckey) is not None:
                    rcells.append(road_cache[ckey])
                if bld_cache.get(ckey) is not None:
                    bcells.append(bld_cache[ckey])
            snapped = snap_to_road(md, s["lat"], s["lon"], radius_m=150.0, deadline=deadline, road_cells=rcells)
            if snapped:
                bld_polys = _building_polys(md, snapped["lat"], snapped["lon"], radius_m=100.0, deadline=deadline, bld_cells=bcells)
                snapped = _apply_curb_offset(snapped, s["lat"], s["lon"], snapped["lat"], snapped["lon"], bld_polys)
            else:
                snapped = {"lat": s["lat"], "lon": s["lon"], "road": "", "bearing": 0.0, "stopType": "kerbside"}
            snapped_stops.append(_make_stop(
                idx, "bus_stop", s["name"] or f"Stop {idx}", snapped, zone_radius=14.0, stop_type="kerbside",
                dwell_target_s=compute_dwell_target_s("bus", tier, "bus_stop", "kerbside", s["name"], seed=seed, idx=idx),
                sector_label=derive_sector_label(name=s["name"], kind="bus_stop", stop_type="kerbside"),
            ))
        if len(snapped_stops) >= 4:
            bus_meta = _apply_bus_passengers_and_schedule(snapped_stops, lat, lon, tier, seed)
            return {
                "ok": True,
                "mode": "bus",
                "tier": tier,
                "title": chosen_route["name"],
                "routeRef": chosen_route["ref"] or chosen_route["name"],
                "source": "osm_bus",
                "estimatedKm": _route_estimate_km(lat, lon, snapped_stops),
                "bus": bus_meta,
                "stops": snapped_stops,
            }

    # 2. Fallback A: Overture infrastructure transit stops chained along heading
    infra = _infra_bus_stops(md, lat, lon, deadline)
    chain = _chain_stops_by_heading(infra, lat, lon, heading, target_max)
    if len(chain) >= target_min:
        stops = []
        for idx, s in enumerate(chain, 1):
            snapped = snap_to_road(md, s["lat"], s["lon"], radius_m=150.0, deadline=deadline)
            if snapped:
                bld_polys = _building_polys(md, snapped["lat"], snapped["lon"], radius_m=100.0, deadline=deadline)
                snapped = _apply_curb_offset(snapped, s["lat"], s["lon"], snapped["lat"], snapped["lon"], bld_polys)
            else:
                snapped = {"lat": s["lat"], "lon": s["lon"], "road": "", "bearing": 0.0, "stopType": "kerbside"}
            stops.append(_make_stop(
                idx, "bus_stop", s["name"], snapped, zone_radius=14.0, stop_type="kerbside",
                dwell_target_s=compute_dwell_target_s("bus", tier, "bus_stop", "kerbside", s["name"], seed=seed, idx=idx),
                sector_label=derive_sector_label(name=s["name"], kind="bus_stop", stop_type="kerbside"),
            ))
        bus_meta = _apply_bus_passengers_and_schedule(stops, lat, lon, tier, seed)
        return {
            "ok": True,
            "mode": "bus",
            "tier": tier,
            "title": f"Local Transit Chain ({len(stops)} stops)",
            "routeRef": "Local Bus",
            "source": "overture",
            "estimatedKm": _route_estimate_km(lat, lon, stops),
            "bus": bus_meta,
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
            bld_polys = _building_polys(md, snapped["lat"], snapped["lon"], radius_m=100.0, deadline=deadline)
            curb = _apply_curb_offset(snapped, None, None, snapped["lat"], snapped["lon"], bld_polys)
            stops.append(_make_stop(
                idx, "bus_stop", nm, curb, zone_radius=14.0, stop_type="kerbside",
                dwell_target_s=compute_dwell_target_s("bus", tier, "bus_stop", "kerbside", nm, seed=seed, idx=idx),
                sector_label="Bus Stop",
            ))
            base_brg = bearing_deg(cur_lat, cur_lon, curb["lat"], curb["lon"])
            cur_lat, cur_lon = curb["lat"], curb["lon"]
        else:
            cur_lat, cur_lon = alat, alon

    if len(stops) < 2:
        return {"ok": False, "error": "No drivable roads found nearby for a bus route"}
    bus_meta = _apply_bus_passengers_and_schedule(stops, lat, lon, tier, seed)
    return {
        "ok": True,
        "mode": "bus",
        "tier": tier,
        "title": f"Bus Corridor ({len(stops)} stops)",
        "routeRef": "Local Corridor",
        "source": "road_chain",
        "estimatedKm": _route_estimate_km(lat, lon, stops),
        "bus": bus_meta,
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
            dom = classify_poi_cargo_domain(p["cat"], p["tax"], "", p.get("tags"), p["name"])
            sec = derive_sector_label(p["cat"], p["tax"], "", p.get("tags"), p["name"])
            candidates.append((retail, p["conf"], p["lat"], p["lon"], p["name"], dom, sec))
    for b in bld_out:
        if not b["name"]:
            continue
        d = dist_m(lat, lon, b["lat"], b["lon"])
        if 200.0 <= d <= max_r_m and b["class"] in _LOGISTICS_ALL_BLD_CLASSES:
            dom = classify_poi_cargo_domain("", "", b["class"], b.get("tags"), b["name"])
            sec = derive_sector_label("", "", b["class"], b.get("tags"), b["name"])
            candidates.append((1, 0.6, b["lat"], b["lon"], b["name"], dom, sec))

    candidates.sort(key=lambda c: (-c[0], -c[1], c[4], c[2]))
    # Pick spread-out stops sequentially by nearest neighbor from player
    picked = []
    cur_lat, cur_lon = lat, lon
    pool = list(candidates[:80])
    min_gap = 320.0 if tier == "local" else 650.0
    even_choices = list(range(min_stops, max_stops + 1, 2)) or [min_stops]
    want = even_choices[_stable_index(seed, f"n:{tier}", len(even_choices))]
    while pool and len(picked) < want and time.monotonic() <= deadline:
        pool.sort(key=lambda c: (dist_m(cur_lat, cur_lon, c[2], c[3]) - c[0] * 150.0, c[4]))
        nxt = None
        for idx, cand in enumerate(pool):
            if all(dist_m(cand[2], cand[3], prev["lat"], prev["lon"]) >= min_gap for prev in picked):
                nxt = pool.pop(idx)
                break
        if nxt is None:
            break
        snapped = _snap_logistics_spot(md, nxt[2], nxt[3], deadline)
        if snapped:
            stop_idx = len(picked) + 1
            kind = "loading" if (stop_idx % 2 == 1) else "delivery"
            sec = nxt[6] or derive_sector_label(name=nxt[4], kind=kind, stop_type=snapped.get("stopType", ""))
            picked.append(_make_stop(stop_idx, kind, nxt[4], snapped, zone_radius=13.0, poi_domain=nxt[5], sector_label=sec))
            cur_lat, cur_lon = snapped["lat"], snapped["lon"]

    # Road-chain fallback if sparse; always target an even stop count (complete Pickup -> Delivery pairs)
    target_even = max(2, len(picked) + (len(picked) % 2)) if len(picked) >= min_stops else min_stops
    if len(picked) < target_even:
        step_m = (target_km * 1000.0) / max(1, target_even)
        for k in range(len(picked) + 1, target_even + 3):
            if time.monotonic() > deadline or len(picked) >= target_even:
                break
            alat, alon = offset_latlon(cur_lat, cur_lon, step_m, (base_brg + (k % 3 - 1) * 25.0) % 360.0)
            snapped = snap_to_road(md, alat, alon, radius_m=500.0, classes=LOGISTICS_FALLBACK_CLASSES, deadline=deadline)
            if snapped and all(dist_m(snapped["lat"], snapped["lon"], prev["lat"], prev["lon"]) >= 250.0 for prev in picked):
                stop_idx = len(picked) + 1
                kind = "loading" if (stop_idx % 2 == 1) else "delivery"
                nm = f"{snapped['road']} {'Pickup' if kind == 'loading' else 'Drop-off'} {stop_idx}" if snapped.get("road") else f"{'Pickup' if kind == 'loading' else 'Delivery'} Point {stop_idx}"
                bld_polys = _building_polys(md, snapped["lat"], snapped["lon"], radius_m=100.0, deadline=deadline)
                curb = _apply_curb_offset(snapped, None, None, snapped["lat"], snapped["lon"], bld_polys)
                picked.append(_make_stop(stop_idx, kind, nm, curb, zone_radius=13.0, stop_type="kerbside"))
                cur_lat, cur_lon = curb["lat"], curb["lon"]

    if len(picked) > 2 and len(picked) % 2 == 1:
        picked.pop()
    if len(picked) < 2:
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
    bld_cells = [_cell_layer(md, k, "buildings", deadline) for k in keys]
    infra_cells = [_cell_layer(md, k, "infrastructure", deadline) for k in keys]
    land_cells = [_cell_layer(md, k, "land_use", deadline) for k in keys]
    places_out, bld_out, land_out = _collect_pois_in_cells(md, keys, ("places", "buildings", "land_use"), deadline)

    candidates = []
    for lu in land_out:
        prio = 4 if lu["class"] == "industrial" else 2
        nm = lu["name"] or (f"{fallback_label} Industrial Park" if lu["class"] == "industrial" else f"{fallback_label} Commercial Zone")
        dom = classify_poi_cargo_domain("", "", lu["class"], lu.get("tags"), nm)
        sec = derive_sector_label("", "", lu["class"], lu.get("tags"), nm)
        candidates.append((prio, lu["lat"], lu["lon"], nm, dom, sec))
    for b in bld_out:
        if b["class"] in LOGISTICS_HUB_CLASSES:
            nm = b["name"] or f"{fallback_label} Warehouse"
            dom = classify_poi_cargo_domain("", "", b["class"], b.get("tags"), nm)
            sec = derive_sector_label("", "", b["class"], b.get("tags"), nm)
            candidates.append((3, b["lat"], b["lon"], nm, dom, sec))
        elif b["class"] in LOGISTICS_COMMERCIAL_CLASSES and b["name"]:
            dom = classify_poi_cargo_domain("", "", b["class"], b.get("tags"), b["name"])
            sec = derive_sector_label("", "", b["class"], b.get("tags"), b["name"])
            candidates.append((1, b["lat"], b["lon"], b["name"], dom, sec))
    for p in places_out:
        if p["cat"] in LOGISTICS_HUB_CATS or p["tax"] in LOGISTICS_HUB_CATS:
            dom = classify_poi_cargo_domain(p["cat"], p["tax"], "", p.get("tags"), p["name"])
            sec = derive_sector_label(p["cat"], p["tax"], "", p.get("tags"), p["name"])
            candidates.append((3, p["lat"], p["lon"], p["name"], dom, sec))
        elif _is_retail_place(p["cat"], p["tax"]):
            dom = classify_poi_cargo_domain(p["cat"], p["tax"], "", p.get("tags"), p["name"])
            sec = derive_sector_label(p["cat"], p["tax"], "", p.get("tags"), p["name"])
            candidates.append((1, p["lat"], p["lon"], p["name"], dom, sec))

    candidates.sort(key=lambda c: (-c[0], c[3], c[1]))
    if candidates:
        top = candidates[:min(6, len(candidates))]
        for off in range(len(top)):
            pick = top[(_stable_index(seed, tag, len(top)) + off) % len(top)]
            snapped = _snap_logistics_spot(
                md, pick[1], pick[2], deadline,
                road_cells=road_cells, bld_cells=bld_cells,
                infra_cells=infra_cells, land_cells=land_cells,
            )
            if snapped:
                return pick[3], {**snapped, "_poiDomain": pick[4], "_sector": pick[5]}
    snapped = snap_to_road(md, alat, alon, radius_m=1500.0, classes=LOGISTICS_FALLBACK_CLASSES,
                           deadline=deadline, road_cells=road_cells)
    if snapped:
        bld_polys = _building_polys(md, snapped["lat"], snapped["lon"], radius_m=100.0, deadline=deadline, bld_cells=bld_cells)
        curb = _apply_curb_offset(snapped, alat, alon, snapped["lat"], snapped["lon"], bld_polys)
        curb["stopType"] = "kerbside"
        return (curb["road"] or f"{fallback_label} Depot"), curb
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
    stops = [_make_stop(1, "loading", o_name, o_snap, zone_radius=15.0, poi_domain=o_snap.get("_poiDomain"),
                        sector_label=o_snap.get("_sector", ""))]

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

    # Optional midpoint 2-stop cycle (Delivery + next Pickup) on Regional Haul (50 km, 2 or 4 stops)
    if tier == "regional" and _stable_index(seed, "reg_mid", 2) == 1 and time.monotonic() < deadline - 0.35:
        mlat = 0.5 * (stops[0]["lat"] + dest[1]["lat"])
        mlon = 0.5 * (stops[0]["lon"] + dest[1]["lon"])
        mid_del = _find_freight_hub(md, mlat, mlon, seed, "log_mid_del", deadline, "Midpoint")
        if mid_del and dist_m(stops[0]["lat"], stops[0]["lon"], mid_del[1]["lat"], mid_del[1]["lon"]) >= 8000.0:
            brg_next = bearing_deg(mid_del[1]["lat"], mid_del[1]["lon"], dest[1]["lat"], dest[1]["lon"])
            p2_lat, p2_lon = offset_latlon(mid_del[1]["lat"], mid_del[1]["lon"], 950.0, brg_next)
            mid_load = _find_freight_hub(md, p2_lat, p2_lon, seed, "log_mid_load", deadline, "Midpoint Depot")
            if mid_load and dist_m(mid_del[1]["lat"], mid_del[1]["lon"], mid_load[1]["lat"], mid_load[1]["lon"]) >= 300.0:
                stops.append(_make_stop(2, "delivery", mid_del[0], mid_del[1], zone_radius=15.0,
                                        poi_domain=mid_del[1].get("_poiDomain"), sector_label=mid_del[1].get("_sector", "")))
                stops.append(_make_stop(3, "loading", mid_load[0], mid_load[1], zone_radius=15.0,
                                        poi_domain=mid_load[1].get("_poiDomain"), sector_label=mid_load[1].get("_sector", "")))

    d_name, d_snap = dest
    d_addr = d_snap.get("road") or ""
    if dest_town:
        d_addr = f"{d_addr}, {dest_town}" if d_addr else dest_town
    stops.append(_make_stop(len(stops) + 1, "delivery", d_name, d_snap, address=d_addr, zone_radius=15.0,
                            poi_domain=d_snap.get("_poiDomain"), locality=dest_town,
                            sector_label=d_snap.get("_sector", "")))
    return {
        "ok": True,
        "mode": "logistics",
        "tier": tier,
        "title": f"{stops[0]['name']} -> {stops[-1]['name']}",
        "source": "overture",
        "estimatedKm": _route_estimate_km(lat, lon, stops),
        "stops": stops,
    }


def _resolve_route_cargo_domain(stops):
    """Pick the most specific semantic cargo domain from delivery stops (preferring food/medical/fuel/hardware over general)."""
    best_dom = "general"
    best_prio = -1
    deliveries = [s for s in stops if s.get("kind") != "loading"] or stops
    for s in deliveries:
        dom = s.get("_poiDomain") or classify_poi_cargo_domain(name=s.get("name", ""))
        p = _DOMAIN_PRIORITY.get(dom, 0)
        if p > best_prio:
            best_prio = p
            best_dom = dom
    return best_dom


def _apply_logistics_cargo_and_dwell(res, req):
    if not res.get("ok") or not res.get("stops"):
        return res
    stops = res["stops"]
    n_stops = len(stops)
    vehicle = req.get("vehicle") or {"class": "van", "coupler": "none", "hasTrailer": False}
    coupler = vehicle.get("coupler") or "none"
    has_trailer = bool(vehicle.get("hasTrailer"))
    installed_models = vehicle.get("trailerModels")
    tier = req["tier"]
    seed = req["seed"]

    if n_stops == 1:
        stops[0].pop("_poiDomain", None)
        cargo = generate_cargo_manifest(vehicle, tier, seed, dest_domain="general")
        stops[0]["cargoDeltaKg"] = 0
        stops[0]["dwellTargetS"] = compute_dwell_target_s(
            "logistics", tier, stops[0].get("kind"), stops[0].get("stopType"),
            stops[0].get("name"), cargo_kg=cargo["massKg"], seed=seed, idx=stops[0].get("index", 1),
        )
        sens = assign_cargo_sensitivity("logistics", tier, cargo["domain"], cargo["type"], seed)
        cargo.update(sens)
        res["cargo"] = cargo
        res["vehicleClass"] = cargo["vehicleClass"]
        res["legs"] = []
        res.update(sens)
        return res

    # Enforce strict complete 2-stop Pickup -> Delivery cycles (no half-dangling 3-stop splits)
    if n_stops > 2 and n_stops % 2 == 1:
        stops = stops[:-1]
        res["stops"] = stops
        n_stops = len(stops)

    cycles = [(i, [i + 1]) for i in range(0, n_stops - 1, 2)]

    legs = []
    first_cargo = None
    stop_cargo_kg = [0] * n_stops
    stop_leg_kind = {}

    for c_idx, (load_i, del_indices) in enumerate(cycles):
        stops[load_i]["kind"] = "loading"
        for di in del_indices:
            stops[di]["kind"] = "delivery"
        cycle_stops = [stops[di] for di in del_indices]
        cycle_domain = _resolve_route_cargo_domain(cycle_stops)
        cycle_seed = seed if c_idx == 0 else (seed + c_idx * 131)
        cargo = generate_cargo_manifest(vehicle, tier, cycle_seed, dest_domain=cycle_domain)
        if first_cargo is None:
            first_cargo = cargo
        mass_kg = cargo["massKg"]

        if has_trailer:
            leg_kind = "loaded_trailer"
            trl_model, trl_label = None, None
        elif cargo["useTrailer"] and coupler in ("fifthwheel", "towhitch"):
            trl_model, trl_label = pick_trailer_model(
                coupler, cargo["type"], cargo["domain"], tier, seed + c_idx * 97, installed_models,
            )
            leg_kind = "loaded_trailer" if trl_model else "loaded_solo"
        else:
            leg_kind = "loaded_solo"
            trl_model, trl_label = None, None

        stop_leg_kind[load_i] = leg_kind
        n_del = len(del_indices)
        per_del = mass_kg // n_del
        rem = mass_kg - per_del * n_del
        stops[load_i]["cargoDeltaKg"] = mass_kg
        stop_cargo_kg[load_i] = mass_kg

        carried = mass_kg
        prev_idx = load_i
        for d_pos, di in enumerate(del_indices):
            drop_kg = per_del + (rem if d_pos == n_del - 1 else 0)
            stops[di]["cargoDeltaKg"] = -drop_kg
            stop_cargo_kg[di] = carried
            stop_leg_kind[di] = leg_kind
            legs.append({
                "index": len(legs) + 1,
                "fromStop": prev_idx + 1,
                "toStop": di + 1,
                "legKind": leg_kind,
                "cargoType": cargo["type"],
                "cargoLabel": cargo["label"],
                "cargoDomain": cargo["domain"],
                "cargoMassKg": carried,
                "trailerModel": trl_model,
                "trailerLabel": trl_label,
            })
            carried = max(0, carried - drop_kg)
            prev_idx = di

        if c_idx + 1 < len(cycles):
            next_load_i = cycles[c_idx + 1][0]
            legs.append({
                "index": len(legs) + 1,
                "fromStop": del_indices[-1] + 1,
                "toStop": next_load_i + 1,
                "legKind": "deadhead",
                "cargoType": "",
                "cargoLabel": "",
                "cargoDomain": "general",
                "cargoMassKg": 0,
                "trailerModel": None,
                "trailerLabel": None,
            })

    for idx_s, s in enumerate(stops):
        s.pop("_poiDomain", None)
        s["dwellTargetS"] = compute_dwell_target_s(
            "logistics", tier, s.get("kind"), s.get("stopType"),
            s.get("name"), cargo_kg=stop_cargo_kg[idx_s], seed=seed, idx=s.get("index", idx_s + 1),
            leg_kind=stop_leg_kind.get(idx_s),
        )
    sens = assign_cargo_sensitivity(
        "logistics", tier, first_cargo["domain"], first_cargo["type"], seed
    )
    first_cargo.update(sens)
    res["cargo"] = first_cargo
    res["vehicleClass"] = first_cargo["vehicleClass"]
    res["legs"] = legs
    res.update(sens)
    return res


# --------------------------------------------------------------------------- Parcel Courier mode

def _extract_addr_fields(attrs, i, tags):
    """Extract optional real (housenumber, street, locality) from feature attrs or OSM tags."""
    hn = ""
    st = ""
    loc = ""
    if attrs:
        for k in _ADDR_HN_KEYS:
            col = attrs.get(k)
            if col is not None and i < len(col):
                v = _clean(col[i])
                if v:
                    hn = v
                    break
        for k in _ADDR_ST_KEYS:
            col = attrs.get(k)
            if col is not None and i < len(col):
                v = _clean(col[i])
                if v:
                    st = v
                    break
        for k in _ADDR_LOC_KEYS:
            col = attrs.get(k)
            if col is not None and i < len(col):
                v = _clean(col[i])
                if v:
                    loc = v
                    break
    if isinstance(tags, dict):
        if not hn:
            hn = _clean(tags.get("addr:housenumber") or tags.get("housenumber") or "")
        if not st:
            st = _clean(tags.get("addr:street") or tags.get("street") or "")
        if not loc:
            loc = _clean(tags.get("addr:city") or tags.get("addr:suburb") or tags.get("locality") or "")
    return hn, st, loc


def _derive_housenumber(street, bld_lat, bld_lon, snap_lat, snap_lon, bearing, seed, key, explicit_hn=""):
    """Return real housenumber if present, else derive a deterministic street-side house number (e.g. '14' or '27a')."""
    if explicit_hn:
        return explicit_hn
    # Determine side of street: even on right (+90 deg), odd on left (-90 deg)
    is_even = True
    if bld_lat is not None and bld_lon is not None and dist_m(snap_lat, snap_lon, bld_lat, bld_lon) >= 1.5:
        to_bld = bearing_deg(snap_lat, snap_lon, bld_lat, bld_lon)
        right_brg = (float(bearing or 0.0) + 90.0) % 360.0
        is_even = _heading_diff(right_brg, to_bld) <= 90.0
    else:
        is_even = (_stable_index(seed, f"hn_side:{street}:{key}", 2) == 0)
    base = 1 + _stable_index(seed, f"hn_num:{street}:{key}", 34)
    num = base * 2 if is_even else (base * 2 - 1)
    suf_roll = _stable_index(seed, f"hn_suf:{street}:{key}", 100)
    suf = "a" if suf_roll < 12 else ("b" if suf_roll < 18 else "")
    return f"{num}{suf}"


def _pick_parcel_recipient(is_business, poi_name, seed, key):
    """Deterministically pick a German household or business recipient name."""
    if is_business:
        nm = _clean(poi_name)
        if nm and len(nm) <= 32:
            return nm
        return PARCEL_BUSINESS_RECIPIENTS[_stable_index(seed, f"pbiz:{key}", len(PARCEL_BUSINESS_RECIPIENTS))]
    return PARCEL_HOUSEHOLD_RECIPIENTS[_stable_index(seed, f"phhs:{key}", len(PARCEL_HOUSEHOLD_RECIPIENTS))]


def _collect_parcel_candidates(md, keys, deadline):
    """Gather residential address points, residential buildings, and small local businesses in keys."""
    out = []
    seen = set()
    for key in keys:
        if time.monotonic() > deadline:
            break
        # 1. Explicit addresses layer (if present in MapData / tests)
        if md is not None and md.has(key, "addresses"):
            f = _cell_layer(md, key, "addresses", deadline)
            if f is not None and len(f.ids):
                attrs = getattr(f, "attrs", {}) or {}
                for i in range(len(f.ids)):
                    aid = ("a", str(f.ids[i]))
                    if aid in seen:
                        continue
                    pt = _feature_center(f, i)
                    if not pt:
                        continue
                    tags = _tags_dict(attrs, i)
                    hn, st, loc = _extract_addr_fields(attrs, i, tags)
                    seen.add(aid)
                    out.append({
                        "prio": 3 if (hn and st) else 2,
                        "lat": pt[0], "lon": pt[1],
                        "housenumber": hn, "street": st, "locality": loc,
                        "poiName": "", "isBusiness": False,
                        "fid": str(f.ids[i]),
                    })

        # 2. Buildings layer (residential + small commercial/office)
        f = _cell_layer(md, key, "buildings", deadline)
        if f is not None and len(f.ids):
            attrs = getattr(f, "attrs", {}) or {}
            n = len(f.ids)
            names = _col(attrs, "name", n)
            classes = _col(attrs, "class", n)
            subtypes = _col(attrs, "subtype", n)
            for i in range(n):
                bid = ("b", str(f.ids[i]))
                if bid in seen:
                    continue
                cls = str(classes[i] or "").strip().lower()
                sub = str(subtypes[i] or "").strip().lower()
                if cls in LOGISTICS_HUB_CLASSES:
                    continue
                tags = _tags_dict(attrs, i)
                hn, st, loc = _extract_addr_fields(attrs, i, tags)
                is_res = (sub == "residential") or (cls in RESIDENTIAL_BUILDING_CLASSES) or (cls == "" and sub == "")
                is_biz = cls in LOGISTICS_COMMERCIAL_CLASSES
                if not (is_res or is_biz or hn):
                    continue
                pt = _feature_center(f, i)
                if not pt:
                    continue
                seen.add(bid)
                prio = 3 if hn else (2 if is_res else 1)
                out.append({
                    "prio": prio,
                    "lat": pt[0], "lon": pt[1],
                    "housenumber": hn, "street": st, "locality": loc,
                    "poiName": _clean(names[i]),
                    "isBusiness": bool(is_biz and not is_res),
                    "fid": str(f.ids[i]),
                })

        # 3. Places layer (small clinics/offices/shops as occasional business recipients)
        f = _cell_layer(md, key, "places", deadline)
        if f is not None and len(f.ids):
            attrs = getattr(f, "attrs", {}) or {}
            n = len(f.ids)
            names = _col(attrs, "name", n)
            cats = _col(attrs, "basic_category", n)
            status = _col(attrs, "operating_status", n)
            for i in range(n):
                pid = ("p", str(f.ids[i]))
                if pid in seen:
                    continue
                st_op = str(status[i] or "").lower()
                if st_op in _CLOSED_STATUSES:
                    continue
                nm = _clean(names[i])
                if not nm:
                    continue
                pt = _feature_center(f, i)
                if not pt:
                    continue
                tags = _tags_dict(attrs, i)
                hn, st, loc = _extract_addr_fields(attrs, i, tags)
                seen.add(pid)
                out.append({
                    "prio": 2 if hn else 0,
                    "lat": pt[0], "lon": pt[1],
                    "housenumber": hn, "street": st, "locality": loc,
                    "poiName": nm,
                    "isBusiness": True,
                    "cat": str(cats[i] or "").strip().lower(),
                    "fid": str(f.ids[i]),
                })
    return out


def _generate_parcel(md, req, deadline):
    """Generate a Parcel Courier route with real house addresses, recipients, deliveries and return pickups."""
    lat, lon, heading, seed, tier = req["lat"], req["lon"], req["heading"], req["seed"], req["tier"]
    spec = TIERS["parcel"][tier]
    target_km = spec["target_km"]
    min_stops, max_stops = spec["min_stops"], spec["max_stops"]
    want = min_stops + _stable_index(seed, f"parcel_n:{tier}", max_stops - min_stops + 1)
    base_brg = heading if heading is not None else float(_stable_index(seed, f"parcel_brg:{tier}", 360))

    # Build targeted cell pockets
    keys = list(_cells_around(lat, lon, 1400.0, max_cells=4))
    town_hints = {}
    if tier in ("regional", "long"):
        min_t_km = target_km * 0.45
        max_t_km = target_km * 1.15
        towns = _towns_in_band(lat, lon, min_t_km, max_t_km, heading, seed, f"parcel_towns:{tier}")
        for _, tlat, tlon, tname in towns[:2]:
            for k in _cells_around(tlat, tlon, 1100.0, max_cells=3):
                if k not in keys:
                    keys.append(k)
                    town_hints[k] = tname
        if len(keys) <= 4:
            for frac, rot in ((0.45, -15.0), (0.85, 10.0)):
                alat, alon = offset_latlon(lat, lon, target_km * 1000.0 * frac, (base_brg + rot) % 360.0)
                for k in _cells_around(alat, alon, 1100.0, max_cells=3):
                    if k not in keys:
                        keys.append(k)
    elif tier == "city":
        for frac, rot in ((0.35, -20.0), (0.70, 15.0)):
            alat, alon = offset_latlon(lat, lon, target_km * 1000.0 * frac, (base_brg + rot) % 360.0)
            for k in _cells_around(alat, alon, 1100.0, max_cells=3):
                if k not in keys:
                    keys.append(k)
    else:
        alat, alon = offset_latlon(lat, lon, target_km * 1000.0 * 0.55, base_brg)
        for k in _cells_around(alat, alon, 1100.0, max_cells=3):
            if k not in keys:
                keys.append(k)
    keys = keys[:12]

    road_cache = {k: _cell_layer(md, k, "roads", deadline) for k in keys}
    bld_cache = {k: _cell_layer(md, k, "buildings", deadline) for k in keys}
    candidates = _collect_parcel_candidates(md, keys, deadline)

    # Filter & rank candidates within tier reach
    max_r_m = max(2500.0, target_km * 1350.0)
    min_r_m = 80.0
    scored_pool = []
    for c in candidates:
        d = dist_m(lat, lon, c["lat"], c["lon"])
        if min_r_m <= d <= max_r_m:
            scored_pool.append((d, c))
    scored_pool.sort(key=lambda item: (-item[1]["prio"], item[0], item[1]["fid"]))
    pool = [item[1] for item in scored_pool[:96]]

    min_gap = 65.0 if tier == "local" else (110.0 if tier == "city" else 160.0)
    picked = []
    used_addrs = set()
    cur_lat, cur_lon = lat, lon

    while pool and len(picked) < want and time.monotonic() <= deadline:
        pool.sort(key=lambda c: (dist_m(cur_lat, cur_lon, c["lat"], c["lon"]) - c["prio"] * 90.0, c["fid"]))
        cand = None
        for idx_p, item in enumerate(pool):
            if all(dist_m(item["lat"], item["lon"], prev["lat"], prev["lon"]) >= min_gap for prev in picked):
                cand = pool.pop(idx_p)
                break
        if cand is None:
            break

        ckeys = _cells_around(cand["lat"], cand["lon"], 140.0, max_cells=4)
        rcells = [road_cache[ck] for ck in ckeys if ck in road_cache and road_cache[ck] is not None]
        if not rcells:
            rcells = [_cell_layer(md, ck, "roads", deadline) for ck in ckeys]
        bcells = [bld_cache[ck] for ck in ckeys if ck in bld_cache and bld_cache[ck] is not None]
        snapped = snap_to_road(md, cand["lat"], cand["lon"], radius_m=180.0, classes=PARCEL_ROAD_CLASSES,
                               deadline=deadline, road_cells=rcells)
        if not snapped:
            snapped = snap_to_road(md, cand["lat"], cand["lon"], radius_m=240.0, classes=DRIVABLE_CLASSES,
                                   deadline=deadline, road_cells=rcells)
        if not snapped:
            continue
        bld_polys = _building_polys(md, snapped["lat"], snapped["lon"], radius_m=100.0, deadline=deadline, bld_cells=bcells)
        curb = _apply_curb_offset(snapped, cand["lat"], cand["lon"], snapped["lat"], snapped["lon"], bld_polys)
        street = cand["street"] or curb.get("road") or "Hauptstraße"
        hn = _derive_housenumber(
            street, cand["lat"], cand["lon"], curb["lat"], curb["lon"],
            curb.get("bearing", 0.0), seed, f"{len(picked)}:{cand['fid']}", explicit_hn=cand["housenumber"],
        )
        addr_key = (street.lower(), hn.lower())
        if addr_key in used_addrs:
            continue
        used_addrs.add(addr_key)
        stop_idx = len(picked) + 1
        house_addr = f"{street} {hn}".strip()
        recipient = _pick_parcel_recipient(cand["isBusiness"], cand["poiName"], seed, f"{stop_idx}:{cand['fid']}")
        ck_home = mapcells.cell_of(curb["lat"], curb["lon"])
        loc_hint = cand["locality"] or town_hints.get(ck_home, "")
        sec = "Business / Practice" if cand["isBusiness"] else "Residential"
        stop = _make_stop(
            stop_idx, "delivery", house_addr, curb,
            address=f"{recipient} · {house_addr}", zone_radius=11.0,
            stop_type="kerbside", dwell_target_s=2.5,
            locality=loc_hint, sector_label=sec,
        )
        stop["recipient"] = recipient
        picked.append(stop)
        cur_lat, cur_lon = curb["lat"], curb["lon"]

    # Road-chain fallback if building density is sparse
    if len(picked) < min_stops:
        step_m = max(140.0, (target_km * 1000.0) / max(1, want))
        for k in range(len(picked) + 1, want + 8):
            if time.monotonic() > deadline or len(picked) >= want:
                break
            alat, alon = offset_latlon(cur_lat, cur_lon, step_m, (base_brg + ((k % 5) - 2) * 22.0) % 360.0)
            snapped = snap_to_road(md, alat, alon, radius_m=420.0, classes=DRIVABLE_CLASSES, deadline=deadline)
            if snapped and all(dist_m(snapped["lat"], snapped["lon"], prev["lat"], prev["lon"]) >= min_gap for prev in picked):
                bld_polys = _building_polys(md, snapped["lat"], snapped["lon"], radius_m=100.0, deadline=deadline)
                curb = _apply_curb_offset(snapped, None, None, snapped["lat"], snapped["lon"], bld_polys)
                street = curb.get("road") or "Ringstraße"
                stop_idx = len(picked) + 1
                hn = _derive_housenumber(street, None, None, curb["lat"], curb["lon"], curb.get("bearing", 0.0), seed, f"fb:{k}")
                addr_key = (street.lower(), hn.lower())
                if addr_key in used_addrs:
                    hn = f"{int(''.join(ch for ch in hn if ch.isdigit()) or 2) + 2 * stop_idx}"
                    addr_key = (street.lower(), hn.lower())
                used_addrs.add(addr_key)
                house_addr = f"{street} {hn}".strip()
                recipient = _pick_parcel_recipient(False, "", seed, f"fb:{stop_idx}")
                stop = _make_stop(
                    stop_idx, "delivery", house_addr, curb,
                    address=f"{recipient} · {house_addr}", zone_radius=11.0,
                    stop_type="kerbside", dwell_target_s=2.5, sector_label="Residential",
                )
                stop["recipient"] = recipient
                picked.append(stop)
                cur_lat, cur_lon = curb["lat"], curb["lon"]

    if len(picked) < 2:
        return {"ok": False, "error": "No drivable residential streets found nearby for a parcel route"}

    # Assign parcelCount (1-3), parcelAction ('deliver' | occasional 'pickup_return'), and cargoDeltaKg
    n = len(picked)
    deliver_total = 0
    initial_mass_kg = 0
    return_count = 0
    for idx_s, s in enumerate(picked):
        # Occasional return pickup on intermediate stops (never first or last stop)
        is_return = (1 <= idx_s < n - 1) and (_stable_index(seed, f"pret:{tier}:{idx_s}", 100) < 18)
        if is_return:
            p_cnt = 1 + _stable_index(seed, f"prcnt:{idx_s}", 2)
            delta_kg = 6 + _stable_index(seed, f"prkg:{idx_s}", 10)  # +6..+15 kg
            s["kind"] = "pickup"
            s["parcelAction"] = "pickup_return"
            s["parcelCount"] = int(p_cnt)
            s["cargoDeltaKg"] = int(delta_kg)
            return_count += p_cnt
        else:
            p_cnt = 1 + _stable_index(seed, f"pdcnt:{idx_s}", 3)  # 1..3 parcels
            per_p = 7 + _stable_index(seed, f"pdkg:{idx_s}", 4)   # 7..10 kg each
            drop_kg = max(8, min(28, p_cnt * per_p))              # 8..28 kg
            s["kind"] = "delivery"
            s["parcelAction"] = "deliver"
            s["parcelCount"] = int(p_cnt)
            s["cargoDeltaKg"] = -int(drop_kg)
            deliver_total += p_cnt
            initial_mass_kg += drop_kg

    # Annotate monotonic outbound parcelsRemaining & parcelsTotal on every stop
    rem = deliver_total
    for s in picked:
        if s["parcelAction"] == "deliver":
            rem = max(0, rem - s["parcelCount"])
        s["parcelsRemaining"] = int(rem)
        s["parcelsTotal"] = int(deliver_total)

    vehicle = req.get("vehicle") or {"class": "van", "coupler": "none", "hasTrailer": False}
    vclass = vehicle.get("class") if vehicle.get("class") in VEHICLE_CLASSES else "van"
    sens = assign_cargo_sensitivity("parcel", tier, "retail", "parcels", seed)
    tier_title = {"local": "Local Parcel Round", "city": "City Parcel Round", "regional": "Regional Parcel Round", "long": "Long Parcel Route"}
    return {
        "ok": True,
        "mode": "parcel",
        "tier": tier,
        "title": f"{tier_title.get(tier, 'Parcel Round')} ({deliver_total} parcels · {initial_mass_kg} kg)",
        "source": "overture",
        "estimatedKm": _route_estimate_km(lat, lon, picked),
        "vehicleClass": vclass,
        **sens,
        "cargo": {
            "type": "parcels",
            "label": "Courier Parcels",
            "domain": "retail",
            "massKg": int(initial_mass_kg),
            "vehicleClass": vclass,
            "useTrailer": False,
            **sens,
        },
        "parcel": {
            "parcelsTotal": int(deliver_total),
            "initialMassKg": int(initial_mass_kg),
            "returnCount": int(return_count),
        },
        "stops": picked,
    }


def generate_job(md, net=None, *, mode, tier, lat, lon, heading=None, seed=0, vehicle=None, deadline_s=DEADLINE_S):
    """Generate a global, deterministic Transport Mode job within deadline_s."""
    req, err = validate_request({
        "mode": mode, "tier": tier, "lat": lat, "lon": lon, "heading": heading, "seed": seed, "vehicle": vehicle,
    })
    if req is None:
        return {"ok": False, "mode": str(mode or ""), "tier": str(tier or ""), "stops": [], "error": err}
    if md is None:
        return {"ok": False, "mode": req["mode"], "tier": req["tier"], "stops": [],
                "error": "No map data available (enable Roads in settings)"}
    deadline = time.monotonic() + max(0.2, float(deadline_s))
    prev_cache = _get_req_cache()
    _req_tls.cache = {"cells": {}, "tags": {}, "locality": {}}
    try:
        if req["mode"] == "taxi":
            res = _generate_taxi(md, req, deadline)
        elif req["mode"] == "bus":
            res = _generate_bus(md, net, req, deadline)
        elif req["mode"] == "parcel":
            res = _generate_parcel(md, req, deadline)
        else:
            if req["tier"] in ("local", "city"):
                res = _generate_logistics_short(md, req, deadline)
            else:
                res = _generate_logistics_haul(md, req, deadline)
            res = _apply_logistics_cargo_and_dwell(res, req)
        if res.get("ok") and res.get("stops"):
            _enrich_stops_locality(md, res["stops"], deadline)
    except Exception as e:
        log.warning("transport job %s/%s failed: %s: %s", req["mode"], req["tier"], type(e).__name__, e)
        res = {"ok": False, "error": f"{type(e).__name__}: {e}"[:160]}
    finally:
        _req_tls.cache = prev_cache
    res.setdefault("mode", req["mode"])
    res.setdefault("tier", req["tier"])
    res.setdefault("stops", [])
    return res


# --------------------------------------------------------------------------- Nearby OSM Fuel Stations

def validate_fuel_stations_request(msg):
    """Validate incoming fuel_stations_request dict -> (cleaned_dict, None) or (None, error_str)."""
    if not isinstance(msg, dict):
        return None, "invalid request"
    try:
        lat, lon = float(msg["lat"]), float(msg["lon"])
    except (KeyError, TypeError, ValueError):
        return None, "missing or invalid lat/lon"
    if not (math.isfinite(lat) and math.isfinite(lon) and -90.0 <= lat <= 90.0 and -180.0 <= lon <= 180.0):
        return None, "lat/lon out of range"
    radius_m = msg.get("radiusM", FUEL_DEFAULT_RADIUS_M)
    try:
        radius_m = float(radius_m) if radius_m is not None else FUEL_DEFAULT_RADIUS_M
        if not math.isfinite(radius_m):
            radius_m = FUEL_DEFAULT_RADIUS_M
    except (TypeError, ValueError):
        radius_m = FUEL_DEFAULT_RADIUS_M
    radius_m = max(200.0, min(5000.0, radius_m))
    return {"lat": lat, "lon": lon, "radiusM": radius_m}, None


def _canonical_fuel_brand(raw):
    s = _clean(raw)
    if not s:
        return ""
    low = s.lower()
    if low in _FUEL_BRAND_CANON:
        return _FUEL_BRAND_CANON[low]
    for tok, canon in _FUEL_BRAND_CANON.items():
        if len(tok) >= 3 and (low.startswith(tok + " ") or (" " + tok + " ") in (" " + low + " ")):
            return canon
    return ""


def _resolve_fuel_brand_and_name(name="", brand_name="", brand_wikidata="", tags=None):
    """Resolve canonical fuel station (name, brand) from Overture/OSM metadata."""
    tags = tags if isinstance(tags, dict) else {}
    wd = _clean(brand_wikidata)
    brand = _FUEL_BRAND_WIKIDATA.get(wd, "") if wd else ""
    if not brand:
        for cand in (brand_name, tags.get("brand"), tags.get("operator"), name, tags.get("name")):
            brand = _canonical_fuel_brand(cand)
            if brand:
                break
    raw_name = _clean(name) or _clean(tags.get("name")) or _clean(brand_name) or _clean(tags.get("brand")) or _clean(tags.get("operator"))
    if brand:
        if not raw_name or raw_name.lower() in ("fuel", "gas station", "petrol station", "tankstelle", "local fuel station"):
            return brand, brand
        if brand.lower() == raw_name.lower():
            return brand, brand
        return raw_name, brand
    if raw_name and raw_name.lower() not in ("fuel", "gas station", "petrol station", "tankstelle"):
        return raw_name, ""
    return "Local Fuel Station", ""


def _fuel_price_per_liter(lat, lon, station_key):
    """Deterministic regional + per-station fuel price per liter in [$1.72, $1.89]."""
    reg_step = _stable_index(0, f"fuel_reg:{round(lat, 1)}:{round(lon, 1)}", 7)  # 0..6 cents
    st_step = _stable_index(0, f"fuel_st:{station_key}:{round(lat, 4)}:{round(lon, 4)}", 12)  # 0..11 cents
    price = 1.72 + (reg_step + st_step) * 0.01
    return round(min(1.89, max(1.72, price)), 2)


def find_nearby_fuel_stations(md, lat, lon, radius_m=FUEL_DEFAULT_RADIUS_M, deadline_s=1.2):
    """Query Overture/OSM places & infrastructure layers for nearby fuel stations within radius_m.

    Deduplicates stations within 35 m, resolves brand/name, snaps pump bay to nearby aisle/road,
    enriches locality, and assigns deterministic regional fuel pricing ($1.72-$1.89 / L).
    """
    if md is None:
        return []
    try:
        lat, lon = float(lat), float(lon)
    except (TypeError, ValueError):
        return []
    if not (math.isfinite(lat) and math.isfinite(lon) and -90.0 <= lat <= 90.0 and -180.0 <= lon <= 180.0):
        return []
    radius_m = max(100.0, min(5000.0, float(radius_m or FUEL_DEFAULT_RADIUS_M)))
    deadline = time.monotonic() + max(0.2, float(deadline_s))

    prev_cache = _get_req_cache()
    _req_tls.cache = {"cells": {}, "tags": {}, "locality": {}}
    try:
        keys = _cells_around(lat, lon, radius_m, max_cells=9)
        raw_cands = []
        seen_ids = set()

        for key in keys:
            if time.monotonic() > deadline:
                break
            # 1. Overture places layer
            f_pl = _cell_layer(md, key, "places", deadline)
            if f_pl is not None and len(getattr(f_pl, "ids", ())):
                attrs = getattr(f_pl, "attrs", {}) or {}
                n = len(f_pl.ids)
                names = _col(attrs, "name", n)
                cats = _col(attrs, "basic_category", n)
                taxes = _col(attrs, "taxonomy", n)
                brands = _col(attrs, "brand_name", n)
                wikis = _col(attrs, "brand_wikidata", n)
                status = _col(attrs, "operating_status", n)
                for i in range(n):
                    pid = ("p", str(f_pl.ids[i]))
                    if pid in seen_ids:
                        continue
                    if str(status[i] or "").strip().lower() in _CLOSED_STATUSES:
                        continue
                    cat = str(cats[i] or "").strip().lower()
                    tax = str(taxes[i] or "").strip().lower()
                    tags = _tags_dict(attrs, i)
                    is_fuel = (
                        cat in _FUEL_PLACE_CATS
                        or tax in _FUEL_PLACE_CATS
                        or tags.get("amenity") == "fuel"
                        or str(wikis[i] or "").strip() in _FUEL_BRAND_WIKIDATA
                    )
                    if not is_fuel:
                        continue
                    pt = _feature_center(f_pl, i)
                    if not pt:
                        continue
                    d = dist_m(lat, lon, pt[0], pt[1])
                    if d > radius_m:
                        continue
                    seen_ids.add(pid)
                    nm, br = _resolve_fuel_brand_and_name(names[i], brands[i], wikis[i], tags)
                    prio = (2 if br else (1 if nm != "Local Fuel Station" else 0)) + 1
                    raw_cands.append({
                        "fid": str(f_pl.ids[i]),
                        "lat": pt[0], "lon": pt[1],
                        "distM": d, "name": nm, "brand": br, "prio": prio,
                    })

            # 2. Overture/OSM infrastructure layer
            f_in = _cell_layer(md, key, "infrastructure", deadline)
            if f_in is not None and len(getattr(f_in, "ids", ())):
                attrs = getattr(f_in, "attrs", {}) or {}
                n = len(f_in.ids)
                names = _col(attrs, "name", n)
                classes = _col(attrs, "class", n)
                for i in range(n):
                    iid = ("i", str(f_in.ids[i]))
                    if iid in seen_ids:
                        continue
                    cls = str(classes[i] or "").strip().lower()
                    tags = _tags_dict(attrs, i)
                    if cls not in _FUEL_INFRA_CLASSES and tags.get("amenity") != "fuel":
                        continue
                    pt = _feature_center(f_in, i)
                    if not pt:
                        continue
                    d = dist_m(lat, lon, pt[0], pt[1])
                    if d > radius_m:
                        continue
                    seen_ids.add(iid)
                    nm, br = _resolve_fuel_brand_and_name(names[i], "", "", tags)
                    prio = 2 if br else (1 if nm != "Local Fuel Station" else 0)
                    raw_cands.append({
                        "fid": str(f_in.ids[i]),
                        "lat": pt[0], "lon": pt[1],
                        "distM": d, "name": nm, "brand": br, "prio": prio,
                    })

        # Sort closest first (preferring higher metadata richness on ties) and deduplicate within 35 m
        raw_cands.sort(key=lambda c: (c["distM"], -c["prio"], c["name"], c["fid"]))
        dedup = []
        for cand in raw_cands:
            merged = False
            for existing in dedup:
                if dist_m(cand["lat"], cand["lon"], existing["lat"], existing["lon"]) <= FUEL_DEDUP_M:
                    # Preserve strongest brand/name when merging paired places + infra pins
                    if cand["prio"] > existing["prio"]:
                        existing["name"] = cand["name"]
                        existing["brand"] = cand["brand"]
                        existing["prio"] = cand["prio"]
                    elif not existing["brand"] and cand["brand"]:
                        existing["brand"] = cand["brand"]
                        if existing["name"] == "Local Fuel Station":
                            existing["name"] = cand["name"]
                    merged = True
                    break
            if not merged:
                dedup.append(cand)
                if len(dedup) >= FUEL_MAX_STATIONS:
                    break

        # Snap pump bay positions to forecourt aisle / road curb and enrich locality & pricing
        loc_cache = {}
        stations = []
        for st in dedup:
            if time.monotonic() > deadline:
                break
            ckeys = _cells_around(st["lat"], st["lon"], 150.0, max_cells=4)
            rcells = [_cell_layer(md, k, "roads", deadline) for k in ckeys]
            bcells = [_cell_layer(md, k, "buildings", deadline) for k in ckeys]
            bld_polys = _building_polys(md, st["lat"], st["lon"], radius_m=100.0, deadline=deadline, bld_cells=bcells)

            bay = _snap_site_aisle(md, st["lat"], st["lon"], rcells, bld_polys, max_dist_m=45.0)
            if not bay:
                snapped = snap_to_road(
                    md, st["lat"], st["lon"], radius_m=120.0,
                    classes=LOGISTICS_FALLBACK_CLASSES, deadline=deadline, road_cells=rcells,
                )
                if snapped:
                    bay = _apply_curb_offset(snapped, st["lat"], st["lon"], snapped["lat"], snapped["lon"], bld_polys)

            if bay:
                bay_lat = round(float(bay["lat"]), 6)
                bay_lon = round(float(bay["lon"]), 6)
                bay_brg = round(float(bay.get("bearing") or 0.0) % 360.0, 1)
                bay_road = _clean(bay.get("road") or "")
            else:
                bay_lat = round(float(st["lat"]), 6)
                bay_lon = round(float(st["lon"]), 6)
                bay_brg = 0.0
                bay_road = ""

            locality = _resolve_locality(md, bay_lat, bay_lon, deadline, cell_cache=loc_cache)
            sid_hash = hashlib.sha256(f"{st['name']}:{bay_lat:.4f}:{bay_lon:.4f}".encode("utf-8")).hexdigest()[:10]
            price = _fuel_price_per_liter(bay_lat, bay_lon, sid_hash)
            stations.append({
                "id": f"fuel_{sid_hash}",
                "name": st["name"],
                "brand": st["brand"],
                "lat": bay_lat,
                "lon": bay_lon,
                "bearingDeg": bay_brg,
                "distM": round(dist_m(lat, lon, bay_lat, bay_lon), 1),
                "road": bay_road,
                "locality": locality,
                "pricePerLiter": price,
            })

        stations.sort(key=lambda s: (s["distM"], s["name"], s["id"]))
        return stations
    finally:
        _req_tls.cache = prev_cache
