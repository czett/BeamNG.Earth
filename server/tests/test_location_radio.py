"""Tests for server/location_radio.py and earthd radio_stations_request/result."""
import socket
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import location_radio as lr  # noqa: E402
import modsim  # noqa: E402
import test_protocol_agreement as proto  # noqa: E402
import test_server  # noqa: E402


class LocationRadioUnitTest(unittest.TestCase):
    def test_subregional_dortmund_cologne_munich(self):
        do = lr.resolve_stations(51.5136, 7.4653, place="Dortmund", region="DE-NW", country="DE", online=False)
        self.assertTrue(do["ok"])
        self.assertEqual(do["regionCode"], "DE-NW-DO")
        names_do = [s["name"] for s in do["stations"]]
        self.assertIn("Radio 91.2", names_do)
        self.assertIn("1LIVE", names_do)
        self.assertIn("WDR 2 Ruhrgebiet", names_do)
        self.assertIn("Radio Essen", names_do)
        r912 = next(s for s in do["stations"] if s["name"] == "Radio 91.2")
        self.assertEqual(r912["scope"], "local")
        self.assertEqual(r912["frequency"], "91.2 MHz")

        cgn = lr.resolve_stations(50.9375, 6.9603, place="Köln", region="DE-NW", country="DE", online=False)
        self.assertEqual(cgn["regionCode"], "DE-NW-K")
        names_cgn = [s["name"] for s in cgn["stations"]]
        self.assertIn("Radio Köln", names_cgn)
        self.assertIn("Antenne Düsseldorf", names_cgn)

        muc = lr.resolve_stations(48.1351, 11.5820, place="München", region="DE-BY", country="DE", online=False)
        self.assertEqual(muc["regionCode"], "DE-BY-M")
        names_muc = [s["name"] for s in muc["stations"]]
        self.assertIn("Radio Gong 96.3", names_muc)
        self.assertIn("Bayern 3", names_muc)
        self.assertIn("Radio Alpenwelle", names_muc)

    def test_german_states_and_international_regions(self):
        cases = [
            (48.7758, 9.1829, "Stuttgart", "DE-BW", "DE", "DE-BW", "SWR3"),
            (52.5200, 13.4050, "Berlin", "DE-BE", "DE", "DE-BE", "radioeins"),
            (53.5511, 9.9937, "Hamburg", "DE-HH", "DE", "DE-HH", "NDR 2"),
            (50.1109, 8.6821, "Frankfurt", "DE-HE", "DE", "DE-HE", "hr3"),
            (52.3759, 9.7320, "Hanover", "DE-NI", "DE", "DE-NI", "radio ffn"),
            (51.0504, 13.7373, "Dresden", "DE-SN", "DE", "DE-SN", "MDR JUMP"),
            (48.2082, 16.3738, "Vienna", "", "AT", "AT", "Hitradio Ö3"),
            (47.3769, 8.5417, "Zurich", "", "CH", "CH", "Radio SRF 3"),
            (41.9028, 12.4964, "Rome", "", "IT", "IT", "Rai Radio 1"),
            (48.8566, 2.3522, "Paris", "", "FR", "FR", "France Inter"),
            (52.3676, 4.9041, "Amsterdam", "", "NL", "NL", "NPO Radio 2"),
            (51.5074, -0.1278, "London", "", "GB", "UK", "Capital FM London"),
            (47.6062, -122.3321, "Seattle", "", "US", "US", "KEXP 90.3 Seattle"),
            (-15.0, -140.0, "", "", "", "GLOBAL", "FIP"),
        ]
        for lat, lon, place, reg, cc, want_code, want_station in cases:
            with self.subTest(want_code=want_code):
                res = lr.resolve_stations(lat, lon, place=place, region=reg, country=cc, online=False)
                self.assertEqual(res["regionCode"], want_code)
                self.assertIn(want_station, [s["name"] for s in res["stations"]])
                for st in res["stations"]:
                    self.assertTrue(st["streamUrl"].startswith("https://"), st)

    def test_tier2_filter_dedupe_and_spatial_cache(self):
        cache = lr.SpatialRadioCache(max_entries=2, ttl_s=60.0)
        calls = []

        def fake_fetch(url, timeout=1.5):
            calls.append((url, timeout))
            return [
                # Duplicate of Tier 1 Dortmund Radio 91.2 (same stream URL) -> deduped
                {"stationuuid": "dup1", "name": "Radio 91.2", "url_resolved": "https://stream.lokalradio.nrw/444z27c",
                 "codec": "MP3", "tags": "pop"},
                # Insecure http:// -> filtered out
                {"stationuuid": "http1", "name": "Insecure FM", "url_resolved": "http://example.com/stream.mp3",
                 "codec": "MP3", "tags": "rock"},
                # Unsupported codec -> filtered out
                {"stationuuid": "wma1", "name": "Legacy WMA", "url_resolved": "https://example.com/stream.wma",
                 "codec": "WMA", "tags": "rock"},
                # Valid live local station -> kept
                {"stationuuid": "live1", "name": "CT das radio", "url_resolved": "https://ctdasradio.de/stream.mp3",
                 "codec": "MP3", "tags": "indie,campus,local", "state": "Bochum", "countrycode": "DE"},
            ]

        res1 = lr.resolve_stations(51.5136, 7.4653, place="Dortmund", region="DE-NW", country="DE",
                                   online=True, offline=False, fetch=fake_fetch, cache=cache)
        self.assertEqual(res1["source"], "live+preset")
        names = [s["name"] for s in res1["stations"]]
        self.assertIn("CT das radio", names)
        self.assertNotIn("Insecure FM", names)
        self.assertNotIn("Legacy WMA", names)
        self.assertEqual(names.count("Radio 91.2"), 1)
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][1], lr.API_TIMEOUT_S)

        # Second call in same ~5 km cell hits spatial cache without fetching
        res2 = lr.resolve_stations(51.5140, 7.4660, place="Dortmund", region="DE-NW", country="DE",
                                   online=True, offline=False, fetch=fake_fetch, cache=cache)
        self.assertEqual(len(calls), 1)
        self.assertIn("CT das radio", [s["name"] for s in res2["stations"]])

        # LRU eviction when > max_entries (2)
        lr.resolve_stations(48.1351, 11.5820, online=True, fetch=fake_fetch, cache=cache)
        lr.resolve_stations(52.5200, 13.4050, online=True, fetch=fake_fetch, cache=cache)
        self.assertEqual(len(cache._data), 2)

    def test_tier2_timeout_and_offline_fallback(self):
        cache = lr.SpatialRadioCache()

        def timeout_fetch(url, timeout=1.5):
            raise socket.timeout("timed out")

        res = lr.resolve_stations(51.5136, 7.4653, place="Dortmund", country="DE",
                                  online=True, offline=False, fetch=timeout_fetch, cache=cache)
        self.assertTrue(res["ok"])
        self.assertEqual(res["source"], "preset")
        self.assertIn("Radio 91.2", [s["name"] for s in res["stations"]])

        def fail_if_called(url, timeout=1.5):
            raise AssertionError("fetch must not be called when offline=True")

        res_off = lr.resolve_stations(48.1351, 11.5820, place="Munich", country="DE",
                                      online=True, offline=True, fetch=fail_if_called, cache=cache)
        self.assertTrue(res_off["ok"])
        self.assertEqual(res_off["source"], "preset")
        self.assertIn("Radio Gong 96.3", [s["name"] for s in res_off["stations"]])


class LocationRadioProtocolTest(test_server.ServerHarness):
    def test_radio_stations_roundtrip(self):
        self.c.send({"type": "hello", "protocol": modsim.CORE["PROTOCOL"],
                     "format": modsim.CORE["FORMAT"], "modVersion": "0.4.0"})
        self.c.until(lambda m: m["type"] == "hello", 10)

        self.c.send({"type": "radio_stations_request", "id": 77,
                     "lat": 51.5136, "lon": 7.4653,
                     "place": "Dortmund", "region": "DE-NW", "country": "DE", "online": False})
        m, _ = self.c.until(lambda msg: msg["type"] == "radio_stations_result", 10)
        self.assertEqual(m["id"], 77)
        self.assertTrue(m["ok"])
        self.assertEqual(m["regionCode"], "DE-NW-DO")
        self.assertIn("Radio 91.2", [s["name"] for s in m["stations"]])

        spec = proto.SERVER_TO_MOD["radio_stations_result"]
        self.assertLessEqual(set(m) - {"type"}, set(spec))
        for k, (types, flags) in spec.items():
            if k in m and m[k] is not None:
                self.assertIsInstance(m[k], types, k)

        # Invalid coordinates return ok=False cleanly
        self.c.send({"type": "radio_stations_request", "id": 78, "lat": 999.0, "lon": 0.0})
        err, _ = self.c.until(lambda msg: msg["type"] == "radio_stations_result" and msg["id"] == 78, 10)
        self.assertFalse(err["ok"])
        self.assertTrue(err.get("error"))


if __name__ == "__main__":
    unittest.main()
