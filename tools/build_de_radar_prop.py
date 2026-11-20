"""Build German 3D speed-camera pillar prop (`bne_de_radar.dae` + `main.materials.json`).

Solid galvanized base + tall dark anthracite Blitzersäule / Starenkasten radar housing +
prominent crimson-red flash lens + simple collision mesh. Uses pure PBR material colors
(no external DDS textures required).
"""

import json
from pathlib import Path
import sys
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from build_rail_crossing_props import Mesh, write_dae  # noqa: E402

VFS = "/levels/beamng_earth/art/shapes/beamngEarth/de_radars"
OUT = ROOT / "mod/beamng_earth" / VFS.lstrip("/")
PREFIX = "bne_de_radar_"


def _box(mesh: Mesh, mat: str, x: float, y: float, z: float, dx: float, dy: float, dz: float) -> None:
    mesh.box(PREFIX + mat, (x, y, z), (dx * 0.5, dy * 0.5, dz * 0.5))


def build_pillar() -> tuple[Mesh, Mesh]:
    """2.65 m tall German radar pillar (Poliscan / Starenkasten silhouette).

    Local -Y faces approaching traffic (consistent with `fr_radars` props).
    """
    m = Mesh(12)
    # Concrete / galvanized base plinth (z = -0.10..0.28 m)
    _box(m, "post", 0.0, 0.0, 0.09, 0.44, 0.44, 0.38)
    # Lower mounting pedestal / post (z = 0.28..1.18 m)
    m.cylinder(PREFIX + "post", 0.0, 0.0, 0.26, 1.20, 0.14)
    # Main dark anthracite radar housing column (z = 1.18..2.54 m)
    _box(m, "housing", 0.0, 0.0, 1.86, 0.42, 0.36, 1.36)
    # Subtle weather cap / sun visor (z = 2.54..2.65 m)
    _box(m, "post", 0.0, -0.02, 2.595, 0.46, 0.44, 0.11)
    # High-contrast reflective silver/red safety collar ring on lower housing
    _box(m, "stripe", 0.0, 0.0, 1.32, 0.432, 0.372, 0.07)
    # Dark optical sensor slit bezel (upper measurement window, faces -Y)
    _box(m, "glass", 0.0, -0.184, 2.28, 0.30, 0.024, 0.16)
    # Prominent crimson-red camera flash lens window (z = 1.98 m, faces -Y)
    _box(m, "housing", 0.0, -0.182, 1.98, 0.24, 0.022, 0.24)
    _box(m, "lens_red", 0.0, -0.194, 1.98, 0.18, 0.016, 0.18)
    # Lower secondary camera aperture
    _box(m, "glass", 0.0, -0.184, 1.66, 0.22, 0.020, 0.14)

    col = Mesh(4)
    _box(col, "post", 0.0, 0.0, 1.32, 0.44, 0.40, 2.64)
    return m, col


def _material(name: str, rgba: list[float], metallic: float, roughness: float, emissive: list[float] | None = None) -> dict:
    stage = {
        "baseColorFactor": rgba,
        "metallicFactor": metallic,
        "roughnessFactor": roughness,
    }
    if emissive is not None:
        stage["emissiveFactor"] = emissive
    return {
        "name": name,
        "mapTo": name,
        "class": "Material",
        "persistentId": str(uuid.uuid5(uuid.NAMESPACE_URL, f"beamngEarth:{name}")),
        "Stages": [stage, {}, {}, {}],
        "groundType": "METAL",
        "materialTag0": "beamng",
        "materialTag1": "beamngEarth",
        "version": 1.5,
    }


def write_assets() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    vis, col = build_pillar()
    write_dae(OUT / "bne_de_radar.dae", "bne_de_radar", [(2, vis)], col)

    mats = {
        PREFIX + "post": _material(PREFIX + "post", [0.64, 0.67, 0.70, 1.0], 0.72, 0.42),
        PREFIX + "housing": _material(PREFIX + "housing", [0.16, 0.18, 0.21, 1.0], 0.35, 0.55),
        PREFIX + "glass": _material(PREFIX + "glass", [0.05, 0.06, 0.08, 1.0], 0.15, 0.12),
        PREFIX + "lens_red": _material(PREFIX + "lens_red", [0.82, 0.08, 0.08, 1.0], 0.10, 0.14, emissive=[0.22, 0.02, 0.02]),
        PREFIX + "stripe": _material(PREFIX + "stripe", [0.88, 0.14, 0.12, 1.0], 0.10, 0.38),
    }
    (OUT / "main.materials.json").write_text(json.dumps(mats, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    write_assets()
    print(f"Wrote {OUT / 'bne_de_radar.dae'} and main.materials.json")
