# Germany (`DE`) Street-Level Immersion Enhancer (`DESIGN_DE_ENHANCER.md`)

## 1. Overview & Motivation
`BeamNG.Earth` already localizes German road markings, town signs (`Ortstafeln`), direction signs, Autobahn signage, and German junction signs (`StVO Zeichen 205/206/301/306/307`). This module fills the missing eye-level urban and suburban immersion layers inside Germany (`server/germany.py` borders):

1. **Feature A — German Street Name Signs (`Straßennamensschilder`):** Double-sided RAL 5010 dark-blue plates with white DIN 1451 (`D-DIN` / `D-DINCondensed`) lettering mounted onto existing street lamps/utility poles at junctions or dedicated galvanized posts.
2. **Feature B — Commercial Brands & Illuminated Shopfront Fascias (`Ladenschilder & Filialen`):** Authentic German retailers (`REWE`, `EDEKA`, `ALDI SÜD` / `ALDI`, `Lidl`, `PENNY`, `Netto`, `Kaufland`, `dm`, `ROSSMANN`, `Apotheke` with Gothic `'A'` + cross badge, `Sparkasse`, `Volksbank`, `DHL Paketshop`, `Bäckerei`, `BackWerk`, `Kamps`, `Döner & Imbiss`, `OBI`) matched against Overture `places` POIs or deterministically assigned to commercial facades, rendered to a per-tile emissive DDS atlas, and dynamically controlled by `nightlights.lua`.
3. **Feature C — Residential Front-Yard Hedges & Fences (`Vorgärten & Einfriedungen`):** Clipped low residential hedges (`fr_hedge`) and German front-yard fencing (`fr_fence_wood`, `fr_fence_rails`, `fr_fence_mesh`, `fr_fence_slats`, `fr_fence_iron`) placed behind sidewalks with front-door path and driveway cutouts, superseding default US wood fences (`fence` / `eca_bld_wood_fence_c`) in Germany.

---

## 2. Toggle & Zero-Overhead Guarantees
- Controlled by `BNE_DE_STREET_IMMERSION` (exposed as `expDeStreetImmersion` in **Settings → Experimental** via `server/experimental.py`, `settings.lua`, and `earthSettingsStore.js`, default `off` / `false`).
- Top-level adapter `server/de_enhancer.py` checks `os.environ.get("BNE_DE_STREET_IMMERSION", "off")` and satisfies `server/tests/test_experimental.py` and `revisit.source_closure`.
- When **disabled** or **outside Germany** (`germany.touches` / `germany.contains` / `germany.de_at`):
  - `cache_parts()` returns `()`, leaving default `revisit` (`roadsg`, `roads`), `decisions.vkey`, and `v131_golden.json` untouched.
  - Zero `places` attribute scans, zero `.dds` texture encodes, zero `.cdae` writes, and zero Lua `Material` instantiations occur.
- When **enabled**, `cache_parts()` hashes `PACKAGE_VERSION`, `de_street_enhancer/*.py` content, and `germany.signature()` into `"roads"` and `"roadsg"` keys so code edits automatically invalidate cached German tiles cleanly.

---

## 3. Architecture & File Layout
- `server/de_enhancer.py` — Top-level bridge for switch checks, border gating, cache keys, and Stage 1 (`prepare_shops`) / Stage 2 (`finish_streets_and_yards`) entry hooks.
- `server/de_street_enhancer/`:
  - `brand_registry.py` — ~20 curated German brand profiles, Wikidata Q-IDs, aliases, and the `ALDI_BORDER_LAT = 51.55` regional split between `ALDI SÜD` and `ALDI Nord`.
  - `classifier.py` — On-demand per-cell memoized Overture `places` extractor (without inflating global `mapdata.slim_places`), spatial POI-to-building matcher, outward wall ray-clearance courtyard rejection, and residential yard classifier.
  - `texture_atlas.py` — Pillow DIN typography (`D-DIN-Bold.otf`, `D-DIN.ttf`, `D-DINCondensed.ttf`, `DejaVuSans-Bold.ttf` fallback), German street suffix shortening, vector emblem rendering, 4-pixel-padded `1024x512` / `1024x1024` shelf atlases (`512x64` slots), and atomic DXT1 DDS output via `imagery.write_dds` (avoiding `TextureCooker` deadlocks on runtime `.png` files).
  - `placement.py` — Split-normal closed `.cdae` mesh builders (`destreets` multi-material `[bne_sign_metal, bne_de_st_<h>]`, `deshops` `[bne_sign_metal, bne_de_sh_<h>]`), pole mounting vs acute-corner bisector setback safety, `de_z*` junction sign clearance (`>= 1.15 m`), and residential front-yard fence/hedge layout with driveway/door cutouts.
  - `hooks.py` — Unified Stage 1 / Stage 2 coordinators.
- `server/blockworker.py`, `server/earthd.py`, `server/roads.py`, `server/buildings.py`:
  - `buildings.road_tile(..., before_parts=...)` runs Stage 1 after `doors()` and suppresses legacy `buildings._signs()` boxes (`spec.sign = None`) only on enhanced buildings.
  - `roads.write_tile` serializes optional `destreets`, `deshops` into `CONTENT_WHATS` `.cdae` files and attaches `deFaces`.
  - `blockworker._town_face_files` captures `"de_*"` DDS textures alongside `"town*"` inside `revisit` `"roadsg"` blobs.
- `mod/beamng_earth/lua/ge/extensions/beamngEarth/deEnhancer.lua`, `roads.lua`, `nightlights.lua`:
  - `destreets` and `deshops` render with `collisionType = 'None'` (`renderOnly = true`) so physics collision rebuilds stay unaffected.
  - `deEnhancer.retain` / `release` / `sweep` reference-count runtime Materials and delete unused Materials (`m:delete()`) after queued `TSStatic` removals finish.
  - `nightlights.addDynamic` toggles shop fascia lightbox illumination cleanly between daytime (`-1` nits) and dusk/night (`35` nits).

---

## 4. Verification & Diagnostics
- **Python Unit & Integration Tests:**
  ```bash
  PYTHONPATH=server .venv/bin/python -m unittest server/tests/test_de_street_enhancer.py server/tests/test_experimental.py
  ```
- **Lua Runtime Tests:**
  ```bash
  cd mod/tests && for f in test_*.lua; do luajit "$f" || exit 1; done
  ```
- **Visual Diagnostic Previews (`/tmp/de_enhancer_preview/`):**
  ```bash
  .venv/bin/python tools/preview_de_enhancer.py
  ```
  Produces `street_signs_atlas.png`, `shop_fascias_atlas.png`, and `intersection_topdown.png` for autonomous visual inspection of kerning, umlauts/Eszett, emblems, intersection clearances, and driveway gaps.
