"""Build German roadwork props (`bne_de_barrier.dae`, `bne_de_sign_123.dae`, `main.materials.json`).

Uses `build_rail_crossing_props.Mesh` & `write_dae` with pure PBR material colors
(no external DDS textures required):
  - `bne_de_barrier`: 2.0 m German Absperrschranke (galvanized legs, red/white striped board, amber warning lamp).
    Runs along local X, front/back faces along +-Y, height 1.15 m.
  - `bne_de_sign_123`: German StVO Zeichen 123 (Arbeitsstelle) triangular warning sign on galvanized post.
    Front face looks along local -Y, height 2.45 m.
"""

import json
from pathlib import Path
import sys
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from build_rail_crossing_props import Mesh, write_dae  # noqa: E402

VFS = "/levels/beamng_earth/art/shapes/beamngEarth/de_roadworks"
OUT = ROOT / "mod/beamng_earth" / VFS.lstrip("/")
PREFIX = "bne_de_rw_"


def _box(mesh: Mesh, mat: str, x: float, y: float, z: float, dx: float, dy: float, dz: float) -> None:
    mesh.box(PREFIX + mat, (x, y, z), (dx * 0.5, dy * 0.5, dz * 0.5))


def build_barrier() -> tuple[Mesh, Mesh]:
    """2.0 m wide x 1.15 m tall German Absperrschranke along local X."""
    m = Mesh(10)
    # Two heavy dark-rubber base feet (z = 0.0..0.10 m)
    _box(m, "rubber", -0.78, 0.0, 0.05, 0.24, 0.48, 0.10)
    _box(m, "rubber", 0.78, 0.0, 0.05, 0.24, 0.48, 0.10)
    # Vertical galvanized stanchions (z = 0.10..1.05 m)
    _box(m, "post", -0.78, 0.0, 0.575, 0.05, 0.05, 0.95)
    _box(m, "post", 0.78, 0.0, 0.575, 0.05, 0.05, 0.95)
    # Red/white alternating plank segments at z = 0.78 m (2.0 m wide, 0.24 m tall)
    seg_w = 2.0 / 5.0
    for i in range(5):
        cx = -0.80 + i * seg_w
        mat = "red" if i % 2 == 0 else "white"
        _box(m, mat, cx, 0.0, 0.78, seg_w, 0.045, 0.24)
    # Lower reflective red/white rail at z = 0.42 m
    for i in range(5):
        cx = -0.80 + i * seg_w
        mat = "white" if i % 2 == 0 else "red"
        _box(m, mat, cx, 0.0, 0.42, seg_w, 0.038, 0.14)
    # Amber Baustellen-Warnleuchte on top left stanchion (z = 1.05..1.15 m)
    _box(m, "amber", -0.78, 0.0, 1.10, 0.10, 0.08, 0.10)

    col = Mesh(4)
    _box(col, "post", 0.0, 0.0, 0.55, 2.0, 0.30, 1.10)
    return m, col


def build_sign_123() -> tuple[Mesh, Mesh]:
    """2.45 m tall German Zeichen 123 (Arbeitsstelle) warning sign facing -Y."""
    m = Mesh(12)
    # Galvanized tubular post (z = -0.10..2.38 m)
    m.cylinder(PREFIX + "post", 0.0, 0.0, -0.10, 2.38, 0.032)
    # Backing plate & triangular sign body (center z = 2.05 m, facing -Y)
    _box(m, "post", 0.0, 0.035, 2.05, 0.72, 0.018, 0.64)
    # Red outer border bands forming triangle silhouette
    _box(m, "red", 0.0, -0.025, 1.77, 0.74, 0.016, 0.075)
    _box(m, "red", -0.18, -0.025, 2.06, 0.38, 0.016, 0.075)
    _box(m, "red", 0.18, -0.025, 2.06, 0.38, 0.016, 0.075)
    _box(m, "red", 0.0, -0.025, 2.36, 0.16, 0.016, 0.12)
    # White inner field + dark worker/shovel icon
    _box(m, "white", 0.0, -0.027, 1.98, 0.46, 0.014, 0.36)
    _box(m, "rubber", -0.05, -0.030, 2.00, 0.08, 0.012, 0.18)
    _box(m, "rubber", 0.08, -0.030, 1.90, 0.14, 0.012, 0.09)

    col = Mesh(4)
    _box(col, "post", 0.0, 0.0, 1.20, 0.12, 0.12, 2.40)
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
    b_vis, b_col = build_barrier()
    write_dae(OUT / "bne_de_barrier.dae", "bne_de_barrier", [(2, b_vis)], b_col)

    s_vis, s_col = build_sign_123()
    write_dae(OUT / "bne_de_sign_123.dae", "bne_de_sign_123", [(2, s_vis)], s_col)

    mats = {
        PREFIX + "post": _material(PREFIX + "post", [0.66, 0.69, 0.72, 1.0], 0.72, 0.40),
        PREFIX + "rubber": _material(PREFIX + "rubber", [0.12, 0.13, 0.15, 1.0], 0.05, 0.75),
        PREFIX + "red": _material(PREFIX + "red", [0.86, 0.10, 0.10, 1.0], 0.08, 0.36),
        PREFIX + "white": _material(PREFIX + "white", [0.92, 0.92, 0.90, 1.0], 0.06, 0.34),
        PREFIX + "amber": _material(PREFIX + "amber", [0.96, 0.62, 0.08, 1.0], 0.10, 0.18, emissive=[0.55, 0.32, 0.02]),
    }
    (OUT / "main.materials.json").write_text(json.dumps(mats, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    write_assets()
    print(f"Wrote de_roadworks assets to {OUT}")
