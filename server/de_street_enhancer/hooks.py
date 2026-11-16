"""Orchestration hooks connecting `de_street_enhancer` cleanly to tile workers."""

import logging
import numpy as np

from . import classifier
from . import placement
from . import texture_atlas


log = logging.getLogger("earthd.de_enhancer")


def prepare_commercial_fascias(
    md,
    frame,
    tx,
    ty,
    items: list,
    out_dir: str | None,
    vfs_dir: str | None,
) -> tuple[dict | None, bytes | None, set[int]]:
    """Build Germany (`DE`) illuminated shopfront fascia mesh & atlas for one tile.

    Must execute AFTER `buildings.doors(...)` (which populates `spec.street`,
    `spec.front`, `spec.sign`) and BEFORE `buildings.road_tile(...)` (so generic
    flat `buildings._signs()` boxes are suppressed on enhanced walls).

    Returns:
        `(face_entry, shop_cdae_bytes, suppressed_spec_ids)`.
    """
    import roads as roadsmod

    if not items or out_dir is None or vfs_dir is None:
        return None, None, set()

    x0, y0, _, _ = roadsmod.tile_bbox(tx, ty)
    cells = roadsmod.cells_of_tile(frame, tx, ty, 35.0)
    tile_pois = classifier.load_tile_pois(md, frame, cells, x0, y0)
    targets, suppress_ids = classifier.classify_commercial_buildings(items, tile_pois, frame, x0, y0)
    if not targets:
        return None, None, set()

    entries = [(f"shop|{t.spec_brand.key}|{t.label}", (t.spec_brand, t.label)) for t in targets]
    mat_name, _dds, vfs_tex, uv_map, _img = texture_atlas.pack_atlas(
        entries,
        lambda pair: texture_atlas.render_shop_fascia(pair[0], pair[1]),
        out_dir,
        vfs_dir,
        prefix="sh",
    )
    if not mat_name or not vfs_tex:
        return None, None, set()

    # Clear legacy generic sign bands so enhanced brand panels never z-fight.
    for spec, _, _ in items:
        if id(spec) in suppress_ids:
            spec.sign = None

    shop_blob = placement.encode_shop_fascias_mesh(targets, mat_name, uv_map)
    if shop_blob is None:
        return None, None, set()

    face = {
        mat_name: {
            "texture": vfs_tex,
            "emissive": True,
            "nits": 35,
            "glowColor": "1 0.94 0.84",
        }
    }
    return face, shop_blob, suppress_ids


def build_streets_and_yards(
    md,
    frame,
    tx,
    ty,
    box: tuple[float, float, float, float],
    near_roads: list,
    street_names: dict,
    props: list,
    walks: list | None,
    items: list | None,
    drives: list[dict] | None,
    garage_drives: list[dict] | None,
    rings: list[np.ndarray] | None,
    ground,
    out_dir: str | None,
    vfs_dir: str | None,
) -> tuple[dict | None, bytes | None, list[list]]:
    """Build Feature A (street name signs `.cdae` bytes + atlas) and Feature C (residential yard props)."""
    x0, y0, _, _ = box
    street_face = None
    street_blob = None

    if near_roads and street_names and out_dir is not None and vfs_dir is not None:
        posts = placement.plan_street_signs(
            frame,
            near_roads,
            box,
            street_names,
            props,
            ground,
            rings=rings,
            drives=drives,
            style_variant="blue",
        )
        if posts:
            entries = [
                (f"street|{variant}|{name}", (name, variant))
                for p in posts
                for name, _d, _z, variant in p.blades
            ]
            mat_name, _dds, vfs_tex, uv_map, _img = texture_atlas.pack_atlas(
                entries,
                lambda pair: texture_atlas.render_street_plate(pair[0], variant=pair[1]),
                out_dir,
                vfs_dir,
                prefix="st",
            )
            if mat_name and vfs_tex:
                street_blob = placement.encode_street_signs_mesh(posts, mat_name, uv_map, (x0, y0, 0.0))
                if street_blob is not None:
                    street_face = {mat_name: {"texture": vfs_tex, "emissive": False}}

    yard_rows: list[list] = []
    if items and near_roads:
        yard_rows = placement.place_residential_yards(
            frame,
            box,
            items,
            near_roads,
            walks,
            drives or [],
            garage_drives,
            rings or [],
            ground,
            md=md,
        )

    return street_face, street_blob, yard_rows
