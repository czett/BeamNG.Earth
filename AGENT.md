# Mission: Modular Germany (DE) Street-Level Immersion Enhancer

You are working on a personal fork of `BeamNG.Earth` (v1.10.1-beta) to elevate German towns and cities (especially Bavaria and NRW, scalable across all of Germany via Overture/OSM data) significantly closer to a realistic street-level experience.

## 1. Environment & Explicit Test Binaries
- **Python Interpreter:** Always use `.venv/bin/python` (do NOT invoke system `python3`).
- **Lua Runtime:** Always use `luajit` for Lua tests (do NOT use `lupa`).
- **Native Rust Module:** `server/earthfast.abi3.so` is prebuilt for Linux x86-64. Prefer implementing new logic in Python (`server/de_street_enhancer/`) and Lua (`mod/beamng_earth/`) so no Rust recompilation is needed—unless a clear bottleneck requires modifying `native/earthfast` (if touched, verify with `.venv/bin/python tools/build_native.py`).

## 2. Core Architectural Rules & Guardrails
- **Non-Destructive & Toggleable:** Follow the exact pattern in `server/experimental.py` and the mod's settings/env system (`BNE_DE_STREET_IMMERSION`, default `on` or toggleable in Experimental settings). Keep existing default behavior 100% intact when disabled.
- **Minimal Core Diff:** Place all new classification, texture generation, and placement logic inside a dedicated module (`server/de_street_enhancer/`), hooking cleanly into the existing tile/building/road serialization pipeline.
- **Reuse Existing DE Systems:** Inspect how German border checks, German road/town/junction signs, building `shopfronts`, and street furniture are already implemented, and reuse those utilities rather than duplicating logic.
- **No Live Network Calls in Tests:** Never hit live Overpass/Overture/tile endpoints during automated tests. Use local synthetic/fixture OSM & Overture payloads representing German cities (e.g., Munich/Bavaria & Cologne/NRW).

## 3. Target Features to Implement (All of Germany)

### Feature A: 3D Street Name Signs at Intersections (`Straßennamensschilder`)
- At intersections where two or more named drivable roads (`highway=*` with `name`) meet within Germany's border:
- Dynamically render crisp German street name signs (white rectangular sign with black border and black `D-DIN` or bundled `DejaVu Sans Bold` lettering, e.g. `"Maximilianstraße"`, `"Hohe Straße"`, `"Hauptstraße"`) onto a cached dynamic atlas or per-tile texture.
- Mount them on existing corner street lamps/poles where present, or spawn a slim sign post at the kerb corner oriented readable to approaching traffic, avoiding carriageway/sidewalk overlap.

### Feature B: Procedural German Commercial Brand & Shop Signs (`Ladenschilder` on `shopfronts`)
- Inspect how buildings currently generate `shopfronts` and parse `brand` / `shop` / `amenity` tags from OSM/Overture.
- Build a curated German brand styling registry (covering top German chains across Bavaria, NRW & nationwide: `REWE`, `EDEKA`, `ALDI` / `ALDI Süd` / `ALDI Nord`, `Lidl`, `Netto`, `PENNY`, `Kaufland`, `dm`, `Rossmann`, `Müller`, `Sparkasse`, `Volksbank` / `VR-Bank`, `Deutsche Bank`, `Postbank`, `DHL` / `Deutsche Post`, `Aral`, `Shell`, `Esso`, `JET`, `TotalEnergies`, `Apotheke`, `Bäckerei`, `Metzgerei`, `OBI`, `Hornbach`, `Bauhaus`, `MediaMarkt`, `Saturn`, `IKEA`, `McDonald's`, `Burger King`, `BackWerk`, plus local `amenity=restaurant` / `cafe`).
- For buildings with a matching `brand` (or fallback `name` when `shop=*` or `amenity` is commercial), dynamically generate a clean fascia sign texture (brand background color, contrasting typography, subtle emissive night glow) and attach it to the street-facing `shopfront` facade above ground-floor windows.

### Feature C: Residential Front-Yard Hedges, Fences & Yard Ground Detail (`Vorgärten & Einfriedungen`)
- For German residential buildings (`building=detached`, `house`, `semidetached_house`, `terrace`) and explicit OSM `barrier=hedge` / `barrier=fence` / `barrier=wall` ways:
- Generate low 3D hedges or fences along mapped barriers or inferred street-facing front-yard boundaries (respecting driveway gaps where `highway=service` / `footway` intersects), and apply clean residential yard/paving ground detail where aerial imagery is blurry up close.

## 4. Mandatory Self-Verification Loop (Before Finishing)
1. **Python Unit & Integration Tests:** Write comprehensive tests in `server/tests/test_de_street_enhancer.py` covering:
   - German border detection & feature toggle (`on` vs `off`).
   - Intersection street-name extraction & sign texture/atlas generation (verifying non-empty pixel output, valid UV/mesh coordinates, and collision-free placement).
   - Brand sign matching (both known DE brands like `REWE`/`Sparkasse` and custom `name` fallbacks like `"Bäckerei Huber"`).
   - Residential hedge/fence generation and driveway clearance.
   - Run: `PYTHONPATH=server .venv/bin/python -m unittest server/tests/test_de_street_enhancer.py`
2. **Lua Mod Tests:** Add/update tests in `mod/tests/` if Lua tile loaders or material definitions were touched, and run:
   - `cd mod/tests && for f in test_*.lua; do luajit "$f"; done`
3. **Visual Diagnostic Artifact:** Generate a local preview in `/tmp/de_enhancer_preview/` containing sample rendered sign textures (street name signs + brand fascia signs) and a 2D top-down plot of a test German intersection with placed signs and hedges.
4. **Clean Workspace & Summary:** Ensure `git status` contains no stray temporary files inside the repo, and write a concise `DESIGN_DE_ENHANCER.md` documenting the architecture, modified files, and toggle flags.
