"""Location-aware live & local radio station resolver for BeamNG.Earth.

Two-tier station resolution:
  1. Tier 1 (Curated Regional & City/Metro Presets): instant, zero-latency fallback
     with sub-regional city/metro lineups (e.g. Dortmund/Ruhr, Cologne/Rhine,
     Munich/Upper Bavaria), German state lineups (DE-BW, DE-BE, DE-HH, DE-HE,
     DE-NI, DE-SN, DE-NW, DE-BY), international regions (AT, CH, IT, FR, NL,
     UK, US), and a global fallback.
  2. Tier 2 (Dynamic Geo / City Local Radio Lookup): queries Radio-Browser JSON
     API using player lat/lon radius + resolved municipality/state name, guarded
     by a strict 1.5 s timeout, HTTPS/MP3/AAC filter, and bounded spatial LRU
     cache (256 cells) so offline or headless runs never stall.
"""
from collections import OrderedDict
import json
import logging
import math
import time
import urllib.error
import urllib.parse
import urllib.request

log = logging.getLogger("earthd.location_radio")

RADIO_BROWSER_URL = "https://de1.api.radio-browser.info/json/stations/search"
USER_AGENT = "BeamNG.Earth/1.0 (+https://github.com/TecnaGamer/BeamNG.Earth)"
API_TIMEOUT_S = 1.5
CACHE_MAX = 256
CACHE_TTL_S = 1800.0
MAX_STATIONS = 12
GEO_CELL_DEG = 0.05  # ~5 km spatial cache cell
ALLOWED_CODECS = ("MP3", "AAC", "AAC+", "OGG", "OPUS", "FLAC")


def _st(sid, name, freq, genre, scope, url, region_code, city="", country="", fallbacks=()):
    return {
        "id": sid,
        "name": name,
        "frequency": freq,
        "genre": genre,
        "scope": scope,
        "streamUrl": url,
        "fallbackUrls": list(fallbacks),
        "regionCode": region_code,
        "city": city,
        "country": country,
        "source": "preset",
    }


# ---------------------------------------------------------------------------
# Tier 1: Curated Sub-Regional Metro & Regional Presets
# ---------------------------------------------------------------------------

METRO_ZONES = (
    {
        "code": "DE-NW-DO",
        "label": "Dortmund · NRW",
        "country": "DE",
        "lat": 51.5136,
        "lon": 7.4653,
        "radius_km": 32.0,
        "aliases": ("dortmund", "bochum", "hagen", "witten", "unna", "castrop-rauxel", "luenen", "lünen"),
        "stations": [
            _st("de-nw-do-radio912", "Radio 91.2", "91.2 MHz", "Pop / Local", "local",
                "https://stream.lokalradio.nrw/444z27c", "DE-NW-DO", "Dortmund", "DE",
                ("https://radio912.cast.addradio.de/radio912/simulcast/high/stream.mp3",)),
            _st("de-nw-1live", "1LIVE", "106.7 MHz", "Pop / Charts", "regional",
                "https://wdr-1live-live.icecastssl.wdr.de/wdr/1live/live/mp3/128/stream.mp3", "DE-NW", "Cologne", "DE"),
            _st("de-nw-wdr2", "WDR 2 Ruhrgebiet", "87.8 MHz", "Adult Hits / News", "regional",
                "https://wdr-wdr2-ruhrgebiet.icecastssl.wdr.de/wdr/wdr2/ruhrgebiet/mp3/128/stream.mp3", "DE-NW", "Dortmund", "DE"),
            _st("de-nw-wdr4", "WDR 4", "101.3 MHz", "Oldies / Classic Hits", "regional",
                "https://wdr-wdr4-live.icecastssl.wdr.de/wdr/wdr4/live/mp3/128/stream.mp3", "DE-NW", "Cologne", "DE"),
            _st("de-nw-essen", "Radio Essen", "102.2 MHz", "Pop / Local", "local",
                "https://stream.lokalradio.nrw/444z29v", "DE-NW-DO", "Essen", "DE"),
        ],
    },
    {
        "code": "DE-NW-K",
        "label": "Cologne · NRW",
        "country": "DE",
        "lat": 50.9375,
        "lon": 6.9603,
        "radius_km": 38.0,
        "aliases": ("köln", "koeln", "cologne", "leverkusen", "bonn", "düsseldorf", "duesseldorf", "bergisch gladbach"),
        "stations": [
            _st("de-nw-k-radiokoeln", "Radio Köln", "107.1 MHz", "Pop / Local", "local",
                "https://stream.lokalradio.nrw/444z372", "DE-NW-K", "Cologne", "DE"),
            _st("de-nw-1live-k", "1LIVE", "102.4 MHz", "Pop / Charts", "regional",
                "https://wdr-1live-live.icecastssl.wdr.de/wdr/1live/live/mp3/128/stream.mp3", "DE-NW", "Cologne", "DE"),
            _st("de-nw-wdr2-k", "WDR 2 Rheinland", "100.4 MHz", "Adult Hits / News", "regional",
                "https://wdr-wdr2-rheinland.icecastssl.wdr.de/wdr/wdr2/rheinland/mp3/128/stream.mp3", "DE-NW", "Cologne", "DE"),
            _st("de-nw-k-antennedus", "Antenne Düsseldorf", "104.2 MHz", "Pop / Local", "local",
                "https://stream.lokalradio.nrw/444z239", "DE-NW-K", "Düsseldorf", "DE"),
            _st("de-nw-wdr4-k", "WDR 4", "100.0 MHz", "Oldies / Classic Hits", "regional",
                "https://wdr-wdr4-live.icecastssl.wdr.de/wdr/wdr4/live/mp3/128/stream.mp3", "DE-NW", "Cologne", "DE"),
        ],
    },
    {
        "code": "DE-BY-M",
        "label": "Munich · Bavaria",
        "country": "DE",
        "lat": 48.1351,
        "lon": 11.5820,
        "radius_km": 45.0,
        "aliases": ("münchen", "muenchen", "munich", "dachau", "freising", "starnberg", "rosenheim", "bad tölz"),
        "stations": [
            _st("de-by-m-gong963", "Radio Gong 96.3", "96.3 MHz", "Pop / Local", "local",
                "https://radiogong-live.cast.addradio.de/radiogong/live/mp3/high", "DE-BY-M", "Munich", "DE"),
            _st("de-by-bayern3", "Bayern 3", "97.3 MHz", "Pop / Charts", "regional",
                "https://dispatcher.rndfnk.com/br/br3/live/mp3/mid", "DE-BY", "Munich", "DE"),
            _st("de-by-antenne", "Antenne Bayern", "101.3 MHz", "Pop / Adult Hits", "regional",
                "https://stream.antenne.de/antenne/stream/mp3", "DE-BY", "Munich", "DE"),
            _st("de-by-m-alpenwelle", "Radio Alpenwelle", "91.7 MHz", "Adult Hits / Local", "local",
                "https://stream.alpenwelle.de/alpenwelle.mp3", "DE-BY-M", "Bad Tölz", "DE"),
            _st("de-by-br24", "BR24", "90.0 MHz", "News / Talk", "regional",
                "https://dispatcher.rndfnk.com/br/br24/live/mp3/mid", "DE-BY", "Munich", "DE"),
        ],
    },
)


REGION_PRESETS = {
    "DE-NW": {
        "label": "North Rhine-Westphalia",
        "country": "DE",
        "stations": [
            _st("de-nw-1live", "1LIVE", "106.7 MHz", "Pop / Charts", "regional",
                "https://wdr-1live-live.icecastssl.wdr.de/wdr/1live/live/mp3/128/stream.mp3", "DE-NW", "Cologne", "DE"),
            _st("de-nw-wdr2", "WDR 2", "99.2 MHz", "Adult Hits / News", "regional",
                "https://wdr-wdr2-rheinland.icecastssl.wdr.de/wdr/wdr2/rheinland/mp3/128/stream.mp3", "DE-NW", "Cologne", "DE"),
            _st("de-nw-wdr4", "WDR 4", "101.3 MHz", "Oldies / Classic Hits", "regional",
                "https://wdr-wdr4-live.icecastssl.wdr.de/wdr/wdr4/live/mp3/128/stream.mp3", "DE-NW", "Cologne", "DE"),
            _st("de-nw-wdr5", "WDR 5", "88.8 MHz", "News / Talk", "regional",
                "https://wdr-wdr5-live.icecastssl.wdr.de/wdr/wdr5/live/mp3/128/stream.mp3", "DE-NW", "Cologne", "DE"),
        ],
    },
    "DE-BY": {
        "label": "Bavaria",
        "country": "DE",
        "stations": [
            _st("de-by-bayern3", "Bayern 3", "97.3 MHz", "Pop / Charts", "regional",
                "https://dispatcher.rndfnk.com/br/br3/live/mp3/mid", "DE-BY", "Munich", "DE"),
            _st("de-by-antenne", "Antenne Bayern", "101.3 MHz", "Pop / Adult Hits", "regional",
                "https://stream.antenne.de/antenne/stream/mp3", "DE-BY", "Munich", "DE"),
            _st("de-by-bayern1", "Bayern 1", "91.3 MHz", "Classic Hits / Oldies", "regional",
                "https://dispatcher.rndfnk.com/br/br1/obb/mp3/mid", "DE-BY", "Munich", "DE"),
            _st("de-by-br24", "BR24", "90.0 MHz", "News / Talk", "regional",
                "https://dispatcher.rndfnk.com/br/br24/live/mp3/mid", "DE-BY", "Munich", "DE"),
        ],
    },
    "DE-BW": {
        "label": "Baden-Württemberg",
        "country": "DE",
        "stations": [
            _st("de-bw-swr3", "SWR3", "92.2 MHz", "Pop / Charts", "regional",
                "https://liveradio.swr.de/sw282p3/swr3/play.mp3", "DE-BW", "Stuttgart", "DE"),
            _st("de-bw-swr1", "SWR1 BW", "94.7 MHz", "Classic Hits", "regional",
                "https://liveradio.swr.de/sw282p3/swr1bw/play.mp3", "DE-BW", "Stuttgart", "DE"),
            _st("de-bw-bigfm", "bigFM", "89.5 MHz", "Urban / Dance", "regional",
                "https://streams.bigfm.de/bigfm-deutschland-128-mp3", "DE-BW", "Stuttgart", "DE"),
            _st("de-bw-dasding", "DASDING", "90.8 MHz", "Pop / Electronic", "regional",
                "https://liveradio.swr.de/sw282p3/dasding/play.mp3", "DE-BW", "Stuttgart", "DE"),
        ],
    },
    "DE-BE": {
        "label": "Berlin",
        "country": "DE",
        "stations": [
            _st("de-be-radioeins", "radioeins", "95.8 MHz", "Indie / Alternative", "local",
                "https://dispatcher.rndfnk.com/rbb/radioeins/live/mp3/mid", "DE-BE", "Berlin", "DE"),
            _st("de-be-fritz", "Fritz", "102.6 MHz", "Pop / Electronic", "local",
                "https://dispatcher.rndfnk.com/rbb/fritz/live/mp3/mid", "DE-BE", "Berlin", "DE"),
            _st("de-be-1046rtl", "104.6 RTL", "104.6 MHz", "Pop / Charts", "local",
                "https://stream.104.6rtl.com/rtl-live/mp3-128", "DE-BE", "Berlin", "DE"),
            _st("de-be-fluxfm", "FluxFM", "100.6 MHz", "Indie / Electronic", "local",
                "https://streams.fluxfm.de/live/mp3-320/audio/", "DE-BE", "Berlin", "DE"),
        ],
    },
    "DE-HH": {
        "label": "Hamburg",
        "country": "DE",
        "stations": [
            _st("de-hh-ndr2", "NDR 2", "87.6 MHz", "Pop / Adult Hits", "regional",
                "https://icecast.ndr.de/ndr/ndr2/hamburg/mp3/128/stream.mp3", "DE-HH", "Hamburg", "DE"),
            _st("de-hh-njoy", "N-JOY", "94.2 MHz", "Pop / Charts", "regional",
                "https://icecast.ndr.de/ndr/njoy/live/mp3/128/stream.mp3", "DE-HH", "Hamburg", "DE"),
            _st("de-hh-rhh", "Radio Hamburg", "103.6 MHz", "Pop / Local", "local",
                "https://stream.radiohamburg.de/rhh-live/mp3-128", "DE-HH", "Hamburg", "DE"),
            _st("de-hh-903", "NDR 90,3", "90.3 MHz", "Classic Hits / Local", "local",
                "https://icecast.ndr.de/ndr/ndr903/hamburg/mp3/128/stream.mp3", "DE-HH", "Hamburg", "DE"),
        ],
    },
    "DE-HE": {
        "label": "Hesse",
        "country": "DE",
        "stations": [
            _st("de-he-hr3", "hr3", "89.3 MHz", "Pop / Charts", "regional",
                "https://dispatcher.rndfnk.com/hr/hr3/live/mp3/mid", "DE-HE", "Frankfurt", "DE"),
            _st("de-he-ffh", "HIT RADIO FFH", "105.9 MHz", "Pop / Adult Hits", "regional",
                "https://mp3.ffh.de/radioffh/hqlivestream.mp3", "DE-HE", "Frankfurt", "DE"),
            _st("de-he-youfm", "YOU FM", "90.4 MHz", "Pop / Urban", "regional",
                "https://dispatcher.rndfnk.com/hr/youfm/live/mp3/mid", "DE-HE", "Frankfurt", "DE"),
            _st("de-he-hr1", "hr1", "94.4 MHz", "Classic Hits", "regional",
                "https://dispatcher.rndfnk.com/hr/hr1/live/mp3/mid", "DE-HE", "Frankfurt", "DE"),
        ],
    },
    "DE-NI": {
        "label": "Lower Saxony",
        "country": "DE",
        "stations": [
            _st("de-ni-ndr2", "NDR 2 Niedersachsen", "96.2 MHz", "Pop / Adult Hits", "regional",
                "https://icecast.ndr.de/ndr/ndr2/niedersachsen/mp3/128/stream.mp3", "DE-NI", "Hanover", "DE"),
            _st("de-ni-ffn", "radio ffn", "101.9 MHz", "Pop / Charts", "regional",
                "https://stream.ffn.de/ffn/mp3-192/", "DE-NI", "Hanover", "DE"),
            _st("de-ni-antenne", "Antenne Niedersachsen", "103.8 MHz", "Adult Hits", "regional",
                "https://stream.antenne.com/antenne-nds/mp3-128", "DE-NI", "Hanover", "DE"),
            _st("de-ni-ndr1", "NDR 1 Niedersachsen", "90.9 MHz", "Oldies / Classic Hits", "regional",
                "https://icecast.ndr.de/ndr/ndr1niedersachsen/hannover/mp3/128/stream.mp3", "DE-NI", "Hanover", "DE"),
        ],
    },
    "DE-SN": {
        "label": "Saxony",
        "country": "DE",
        "stations": [
            _st("de-sn-mdrjump", "MDR JUMP", "90.4 MHz", "Pop / Charts", "regional",
                "https://mdr-284320-0.sslcast.mdr.de/mdr/284320/0/mp3/high/stream.mp3", "DE-SN", "Leipzig", "DE"),
            _st("de-sn-psr", "RADIO PSR", "102.9 MHz", "Pop / Adult Hits", "regional",
                "https://streams.radiopsr.de/psr-live/mp3-128", "DE-SN", "Leipzig", "DE"),
            _st("de-sn-sputnik", "MDR SPUTNIK", "104.4 MHz", "Pop / Electronic", "regional",
                "https://mdr-284330-0.sslcast.mdr.de/mdr/284330/0/mp3/high/stream.mp3", "DE-SN", "Halle", "DE"),
            _st("de-sn-mdrsachsen", "MDR SACHSEN", "92.2 MHz", "Classic Hits", "regional",
                "https://mdr-284280-0.sslcast.mdr.de/mdr/284280/0/mp3/high/stream.mp3", "DE-SN", "Dresden", "DE"),
        ],
    },
    "DE": {
        "label": "Germany",
        "country": "DE",
        "stations": [
            _st("de-dlf", "Deutschlandfunk", "102.8 MHz", "News / Talk", "national",
                "https://st01.sslstream.dlf.de/dlf/01/128/mp3/stream.mp3", "DE", "Cologne", "DE"),
            _st("de-dlfnova", "Deutschlandfunk Nova", "106.1 MHz", "Indie / Electronic", "national",
                "https://st03.sslstream.dlf.de/dlf/03/128/mp3/stream.mp3", "DE", "Cologne", "DE"),
            _st("de-1live", "1LIVE", "106.7 MHz", "Pop / Charts", "regional",
                "https://wdr-1live-live.icecastssl.wdr.de/wdr/1live/live/mp3/128/stream.mp3", "DE", "Cologne", "DE"),
            _st("de-bayern3", "Bayern 3", "97.3 MHz", "Pop / Adult Hits", "regional",
                "https://dispatcher.rndfnk.com/br/br3/live/mp3/mid", "DE", "Munich", "DE"),
        ],
    },
    "AT": {
        "label": "Austria",
        "country": "AT",
        "stations": [
            _st("at-oe3", "Hitradio Ö3", "99.9 MHz", "Pop / Charts", "national",
                "https://orf-live.ors-shoutcast.at/oe3-q2a", "AT", "Vienna", "AT"),
            _st("at-fm4", "Radio FM4", "103.8 MHz", "Alternative / Indie", "national",
                "https://orf-live.ors-shoutcast.at/fm4-q2a", "AT", "Vienna", "AT"),
            _st("at-oe1", "Ö1", "92.0 MHz", "Classical / Culture", "national",
                "https://orf-live.ors-shoutcast.at/oe1-q2a", "AT", "Vienna", "AT"),
            _st("at-kronehit", "kronehit", "105.8 MHz", "Pop / Dance", "national",
                "https://secureonair.krone.at/kronehit.mp3", "AT", "Vienna", "AT"),
        ],
    },
    "CH": {
        "label": "Switzerland",
        "country": "CH",
        "stations": [
            _st("ch-srf3", "Radio SRF 3", "105.6 MHz", "Pop / Rock", "national",
                "https://stream.srg-ssr.ch/m/drs3/mp3_128", "CH", "Zurich", "CH"),
            _st("ch-srf1", "Radio SRF 1", "94.6 MHz", "Adult Hits / News", "national",
                "https://stream.srg-ssr.ch/m/drs1/mp3_128", "CH", "Zurich", "CH"),
            _st("ch-virus", "Radio SRF Virus", "100.3 MHz", "Alternative / Urban", "national",
                "https://stream.srg-ssr.ch/m/drsvirus/mp3_128", "CH", "Basel", "CH"),
            _st("ch-swissjazz", "Radio Swiss Jazz", "101.8 MHz", "Jazz", "national",
                "https://stream.srg-ssr.ch/m/rsj/mp3_128", "CH", "Bern", "CH"),
        ],
    },
    "IT": {
        "label": "Italy",
        "country": "IT",
        "stations": [
            _st("it-rai1", "Rai Radio 1", "89.7 MHz", "News / Talk", "national",
                "https://icestreaming.rai.it/1.mp3", "IT", "Rome", "IT"),
            _st("it-rai2", "Rai Radio 2", "91.7 MHz", "Pop / Entertainment", "national",
                "https://icestreaming.rai.it/2.mp3", "IT", "Rome", "IT"),
            _st("it-rtl1025", "RTL 102.5", "102.5 MHz", "Pop / Charts", "national",
                "https://streamingv2.shoutcast.com/rtl-1025", "IT", "Milan", "IT"),
            _st("it-rds", "RDS 100% Grandi Successi", "103.0 MHz", "Pop / Adult Hits", "national",
                "https://icstream.rds.radio/rds", "IT", "Rome", "IT"),
        ],
    },
    "FR": {
        "label": "France",
        "country": "FR",
        "stations": [
            _st("fr-inter", "France Inter", "87.8 MHz", "Talk / Variety", "national",
                "https://icecast.radiofrance.fr/franceinter-midfi.mp3", "FR", "Paris", "FR"),
            _st("fr-fip", "FIP", "105.1 MHz", "Eclectic / Jazz", "national",
                "https://icecast.radiofrance.fr/fip-midfi.mp3", "FR", "Paris", "FR"),
            _st("fr-nrj", "NRJ France", "100.3 MHz", "Pop / Charts", "national",
                "https://scdn.nrjaudio.fm/adwz2/fr/30001/mp3_128.mp3", "FR", "Paris", "FR"),
            _st("fr-skyrock", "Skyrock", "96.0 MHz", "Urban / Hip-Hop", "national",
                "https://icecast.skyrock.net/s/natio_mp3_128k", "FR", "Paris", "FR"),
        ],
    },
    "NL": {
        "label": "Netherlands",
        "country": "NL",
        "stations": [
            _st("nl-npo2", "NPO Radio 2", "92.6 MHz", "Adult Hits / Pop", "national",
                "https://icecast.omroep.nl/radio2-bb-mp3", "NL", "Hilversum", "NL"),
            _st("nl-npo3fm", "NPO 3FM", "96.8 MHz", "Pop / Alternative", "national",
                "https://icecast.omroep.nl/3fm-bb-mp3", "NL", "Hilversum", "NL"),
            _st("nl-538", "Radio 538", "102.1 MHz", "Pop / Dance", "national",
                "https://playerservices.streamtheworld.com/api/livestream-redirect/RADIO538.mp3", "NL", "Amsterdam", "NL"),
            _st("nl-qmusic", "Qmusic NL", "100.4 MHz", "Pop / Charts", "national",
                "https://icecast-qmusicnl-cdp.triple-it.nl/Qmusic_nl_live_96.mp3", "NL", "Amsterdam", "NL"),
        ],
    },
    "UK": {
        "label": "United Kingdom",
        "country": "GB",
        "stations": [
            _st("uk-bbcr1", "BBC Radio 1", "98.8 MHz", "Pop / Charts", "national",
                "https://as-hls-ww-live.akamaized.net/pool_904/live/ww/bbc_radio_one/bbc_radio_one.isml/bbc_radio_one-audio%3d96000.norewind.m3u8",
                "UK", "London", "GB",
                ("https://stream.live.vc.bbcmedia.co.uk/bbc_radio_one",)),
            _st("uk-capital", "Capital FM London", "95.8 MHz", "Pop / Charts", "local",
                "https://media-ice.musicradio.com/CapitalMP3", "UK", "London", "GB"),
            _st("uk-heart", "Heart UK", "106.2 MHz", "Adult Hits", "national",
                "https://media-ice.musicradio.com/HeartUKMP3", "UK", "London", "GB"),
            _st("uk-radiox", "Radio X", "104.9 MHz", "Indie / Rock", "national",
                "https://media-ice.musicradio.com/RadioXUKMP3", "UK", "London", "GB"),
        ],
    },
    "US": {
        "label": "United States",
        "country": "US",
        "stations": [
            _st("us-kexp", "KEXP 90.3 Seattle", "90.3 MHz", "Indie / Alternative", "regional",
                "https://kexp-mp3-128.streamguys1.com/kexp128.mp3", "US", "Seattle", "US"),
            _st("us-kcrw", "KCRW 89.9 Los Angeles", "89.9 MHz", "Eclectic / News", "regional",
                "https://kcrw.streamguys1.com/kcrw_192k_mp3_e24", "US", "Los Angeles", "US"),
            _st("us-somafm-groove", "SomaFM Groove Salad", "101.5 MHz", "Ambient / Chill", "national",
                "https://ice2.somafm.com/groovesalad-128-mp3", "US", "San Francisco", "US"),
            _st("us-somafm-indie", "SomaFM Indie Pop Rocks!", "104.7 MHz", "Indie / Pop", "national",
                "https://ice2.somafm.com/indiepop-128-mp3", "US", "San Francisco", "US"),
        ],
    },
    "GLOBAL": {
        "label": "Global Radio",
        "country": "",
        "stations": [
            _st("global-fip", "FIP", "105.1 MHz", "Eclectic / Jazz", "global",
                "https://icecast.radiofrance.fr/fip-midfi.mp3", "GLOBAL", "Paris", "FR"),
            _st("global-somafm-groove", "SomaFM Groove Salad", "101.5 MHz", "Ambient / Chill", "global",
                "https://ice2.somafm.com/groovesalad-128-mp3", "GLOBAL", "San Francisco", "US"),
            _st("global-swissjazz", "Radio Swiss Jazz", "101.8 MHz", "Jazz", "global",
                "https://stream.srg-ssr.ch/m/rsj/mp3_128", "GLOBAL", "Bern", "CH"),
            _st("global-kexp", "KEXP 90.3", "90.3 MHz", "Indie / Alternative", "global",
                "https://kexp-mp3-128.streamguys1.com/kexp128.mp3", "GLOBAL", "Seattle", "US"),
        ],
    },
}

COUNTRY_ALIASES = {
    "DE": "DE", "DEU": "DE", "GERMANY": "DE", "DEUTSCHLAND": "DE",
    "AT": "AT", "AUT": "AT", "AUSTRIA": "AT", "ÖSTERREICH": "AT",
    "CH": "CH", "CHE": "CH", "SWITZERLAND": "CH", "SCHWEIZ": "CH", "SUISSE": "CH",
    "IT": "IT", "ITA": "IT", "ITALY": "IT", "ITALIA": "IT",
    "FR": "FR", "FRA": "FR", "FRANCE": "FR",
    "NL": "NL", "NLD": "NL", "NETHERLANDS": "NL", "NEDERLAND": "NL",
    "UK": "UK", "GB": "UK", "GBR": "UK", "UNITED KINGDOM": "UK",
    "US": "US", "USA": "US", "UNITED STATES": "US",
}

DE_STATE_ALIASES = {
    "NORTH RHINE-WESTPHALIA": "DE-NW", "NORDRHEIN-WESTFALEN": "DE-NW", "NRW": "DE-NW", "DE-NW": "DE-NW",
    "BAVARIA": "DE-BY", "BAYERN": "DE-BY", "DE-BY": "DE-BY",
    "BADEN-WÜRTTEMBERG": "DE-BW", "BADEN-WUERTTEMBERG": "DE-BW", "DE-BW": "DE-BW",
    "BERLIN": "DE-BE", "DE-BE": "DE-BE",
    "HAMBURG": "DE-HH", "DE-HH": "DE-HH",
    "HESSE": "DE-HE", "HESSEN": "DE-HE", "DE-HE": "DE-HE",
    "LOWER SAXONY": "DE-NI", "NIEDERSACHSEN": "DE-NI", "DE-NI": "DE-NI",
    "SAXONY": "DE-SN", "SACHSEN": "DE-SN", "DE-SN": "DE-SN",
}

# Coarse fallback bounding boxes (s, w, n, e, code) when place_names/country isn't loaded yet
FALLBACK_BOXES = (
    (52.34, 13.08, 52.68, 13.77, "DE-BE"),
    (53.39, 9.73, 53.74, 10.33, "DE-HH"),
    (50.32, 5.86, 52.53, 9.46, "DE-NW"),
    (47.27, 8.98, 50.56, 13.84, "DE-BY"),
    (47.53, 7.51, 49.79, 10.49, "DE-BW"),
    (49.39, 7.77, 51.66, 10.24, "DE-HE"),
    (51.30, 6.65, 53.89, 11.60, "DE-NI"),
    (50.17, 11.87, 51.68, 15.04, "DE-SN"),
    (47.27, 5.86, 55.06, 15.04, "DE"),
    (46.37, 9.53, 49.02, 17.16, "AT"),
    (45.82, 5.95, 47.81, 10.49, "CH"),
    (50.75, 3.35, 53.56, 7.22, "NL"),
    (41.33, -5.14, 51.09, 9.56, "FR"),
    (36.64, 6.63, 47.09, 18.52, "IT"),
    (49.90, -8.65, 60.86, 1.77, "UK"),
    (24.39, -125.0, 49.39, -66.93, "US"),
)


def _haversine_km(lat1, lon1, lat2, lon2):
    r = 6371.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp = math.radians(lat2 - lat1)
    dl = math.radians(lon2 - lon1)
    a = math.sin(dp / 2.0) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2.0) ** 2
    return 2.0 * r * math.asin(min(1.0, math.sqrt(a)))


def _norm_country(country):
    if not country:
        return ""
    return COUNTRY_ALIASES.get(str(country).strip().upper(), "")


def _norm_region_code(country, region):
    c = _norm_country(country)
    r = str(region or "").strip()
    if r:
        up = r.upper()
        if up in REGION_PRESETS:
            return up
        if up in DE_STATE_ALIASES:
            return DE_STATE_ALIASES[up]
        if c == "DE":
            for k, code in DE_STATE_ALIASES.items():
                if k in up:
                    return code
    return c


def _region_from_coords(lat, lon):
    for s, w, n, e, code in FALLBACK_BOXES:
        if s <= lat <= n and w <= lon <= e:
            return code
    return "GLOBAL"


def resolve_tier1(lat, lon, place="", region="", country=""):
    """Return (region_code, region_label, preset_stations) from Tier 1 curated presets."""
    place_l = str(place or "").strip().lower()
    norm_country = _norm_country(country)

    # 1. Check sub-regional metro/city zones first (by radius or locality alias)
    best_metro = None
    best_dist = 1e9
    for mz in METRO_ZONES:
        d = _haversine_km(lat, lon, mz["lat"], mz["lon"])
        alias_hit = bool(place_l and any(a in place_l for a in mz["aliases"]))
        if d <= mz["radius_km"] or (alias_hit and d <= 120.0):
            if d < best_dist:
                best_dist = d
                best_metro = mz
    if best_metro is not None:
        return best_metro["code"], best_metro["label"], [dict(s) for s in best_metro["stations"]]

    # 2. Check state/country code from metadata, else coarse coordinate bounding boxes
    code = _norm_region_code(norm_country, region)
    if not code or code not in REGION_PRESETS:
        code = _region_from_coords(lat, lon)
    preset = REGION_PRESETS.get(code) or REGION_PRESETS["GLOBAL"]
    label = preset["label"]
    if place:
        label = f"{place} · {label}" if label and label != place else place
    return code, label, [dict(s) for s in preset["stations"]]


# ---------------------------------------------------------------------------
# Tier 2: Dynamic Geo / City Local Radio Lookup (Radio-Browser JSON API)
# ---------------------------------------------------------------------------

class SpatialRadioCache:
    """Bounded LRU spatial cache keyed by ~5 km rounded grid cells."""

    def __init__(self, max_entries=CACHE_MAX, ttl_s=CACHE_TTL_S):
        self.max_entries = max(1, int(max_entries))
        self.ttl_s = float(ttl_s)
        self._data = OrderedDict()

    @staticmethod
    def key_for(lat, lon):
        return (round(float(lat) / GEO_CELL_DEG), round(float(lon) / GEO_CELL_DEG))

    def get(self, key, now=None):
        now = time.monotonic() if now is None else now
        entry = self._data.get(key)
        if entry is None:
            return None
        ts, stations = entry
        if now - ts > self.ttl_s:
            self._data.pop(key, None)
            return None
        self._data.move_to_end(key)
        return [dict(s) for s in stations]

    def put(self, key, stations, now=None):
        now = time.monotonic() if now is None else now
        self._data[key] = (now, [dict(s) for s in stations])
        self._data.move_to_end(key)
        while len(self._data) > self.max_entries:
            self._data.popitem(last=False)

    def clear(self):
        self._data.clear()


_DEFAULT_CACHE = SpatialRadioCache()


def _default_fetch(url, timeout=API_TIMEOUT_S):
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8", errors="replace"))


def _synthetic_fm(seed_text):
    """Deterministic realistic FM frequency (87.6 .. 107.9 MHz) when API lacks one."""
    h = 0
    for ch in seed_text:
        h = (h * 33 + ord(ch)) & 0xFFFF
    step = h % 204  # 87.6 + 0.1 * step -> 87.6 .. 107.9
    return f"{87.6 + step * 0.1:.1f} MHz"


def _clean_genre(tags):
    if not tags:
        return "Local Radio"
    parts = [p.strip().title() for p in str(tags).split(",") if p.strip()]
    filtered = [p for p in parts if len(p) <= 22 and not p.isdigit()]
    if not filtered:
        return "Local Radio"
    return " / ".join(filtered[:2])


def _normalize_api_station(row, region_code, fallback_city, fallback_country):
    if not isinstance(row, dict):
        return None
    url = str(row.get("url_resolved") or row.get("url") or "").strip()
    if not url.startswith("https://"):
        return None
    codec = str(row.get("codec") or "").strip().upper()
    if codec and codec not in ALLOWED_CODECS:
        return None
    name = str(row.get("name") or "").strip()
    if not name or len(name) > 80:
        return None
    uid = str(row.get("stationuuid") or name).strip()[:36]
    city = str(row.get("state") or fallback_city or "").strip()
    cc = str(row.get("countrycode") or fallback_country or "").strip().upper()
    return {
        "id": f"rb-{uid}",
        "name": name,
        "frequency": _synthetic_fm(name),
        "genre": _clean_genre(row.get("tags")),
        "scope": "local",
        "streamUrl": url,
        "fallbackUrls": [],
        "regionCode": region_code,
        "city": city,
        "country": cc,
        "source": "live",
    }


def query_radio_browser(lat, lon, place="", region_code="", country="", fetch=None, timeout=API_TIMEOUT_S):
    """Query Radio-Browser JSON API for nearby HTTPS MP3/AAC local stations."""
    fetcher = fetch or _default_fetch
    params = {
        "lat": f"{lat:.4f}",
        "long": f"{lon:.4f}",
        "radius": "65000",
        "limit": "12",
        "order": "votes",
        "reverse": "true",
        "hidebroken": "true",
    }
    if country and len(country) == 2:
        params["countrycode"] = country.upper()
    url = f"{RADIO_BROWSER_URL}?{urllib.parse.urlencode(params)}"
    rows = fetcher(url, timeout=timeout)
    if not isinstance(rows, list):
        return []
    out = []
    for row in rows:
        st = _normalize_api_station(row, region_code, place, country)
        if st is not None:
            out.append(st)
    return out


def _dedupe_merge(tier1, tier2, limit=MAX_STATIONS):
    """Merge Tier 1 curated stations and Tier 2 live local stations without duplicates."""
    merged = []
    seen_urls = set()
    seen_names = set()

    def add(st):
        url_key = st["streamUrl"].rstrip("/").lower()
        name_key = "".join(ch for ch in st["name"].lower() if ch.isalnum())
        if url_key in seen_urls or name_key in seen_names:
            return False
        seen_urls.add(url_key)
        seen_names.add(name_key)
        merged.append(st)
        return True

    # Keep Tier 1 local stations first, then Tier 2 live local stations, then Tier 1 regional/national
    for st in tier1:
        if st.get("scope") == "local":
            add(st)
    for st in tier2:
        if len(merged) >= limit:
            break
        add(st)
    for st in tier1:
        if len(merged) >= limit:
            break
        add(st)
    return merged[:limit]


# ---------------------------------------------------------------------------
# Public Request Validation & Resolution
# ---------------------------------------------------------------------------

def validate_request(msg):
    """Validate a radio_stations_request message. Returns (req_dict, None) or (None, error)."""
    if not isinstance(msg, dict):
        return None, "invalid message"
    try:
        lat = float(msg["lat"])
        lon = float(msg["lon"])
    except (KeyError, TypeError, ValueError):
        return None, "bad coordinates"
    if not (math.isfinite(lat) and math.isfinite(lon) and -90.0 <= lat <= 90.0 and -180.0 <= lon <= 180.0):
        return None, "coordinates out of range"
    return {
        "lat": lat,
        "lon": lon,
        "place": str(msg.get("place") or "").strip()[:120],
        "region": str(msg.get("region") or "").strip()[:120],
        "country": str(msg.get("country") or "").strip()[:80],
        "online": msg.get("online", True) is not False,
    }, None


def resolve_stations(lat, lon, place="", region="", country="", online=True, offline=False,
                     fetch=None, cache=None, timeout=API_TIMEOUT_S):
    """Resolve two-tier local + regional radio lineup for (lat, lon)."""
    code, label, tier1 = resolve_tier1(lat, lon, place=place, region=region, country=country)
    norm_country = _norm_country(country) or (tier1[0]["country"] if tier1 else "")
    cache_obj = _DEFAULT_CACHE if cache is None else cache
    tier2 = []
    source = "preset"

    if online and not offline:
        ckey = cache_obj.key_for(lat, lon)
        cached = cache_obj.get(ckey)
        if cached is not None:
            tier2 = cached
            if tier2:
                source = "live+preset"
        else:
            try:
                tier2 = query_radio_browser(
                    lat, lon, place=place, region_code=code, country=norm_country,
                    fetch=fetch, timeout=timeout,
                )
                cache_obj.put(ckey, tier2)
                if tier2:
                    source = "live+preset"
            except Exception as e:
                log.debug("radio-browser lookup skipped (%s: %s)", type(e).__name__, e)
                tier2 = []

    stations = _dedupe_merge(tier1, tier2, limit=MAX_STATIONS)
    return {
        "ok": True,
        "regionCode": code,
        "regionLabel": label,
        "country": norm_country,
        "place": place,
        "source": source,
        "stations": stations,
    }
