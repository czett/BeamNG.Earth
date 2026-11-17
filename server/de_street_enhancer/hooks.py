"""Orchestration hooks connecting `de_street_enhancer` cleanly to tile workers."""

import logging
import math
import numpy as np

from . import classifier
from . import furniture_de
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
    hn_targets = classifier.collect_housenumbers(items, suppress_ids=suppress_ids)
    if not targets and not hn_targets:
        return None, None, set()

    entries: list[tuple[str, object]] = [
        (f"shop|{t.spec_brand.key}|{t.label}", ("shop", t.spec_brand, t.label))
        for t in targets
    ]
    # Compactly pack up to 4 unique house numbers per 512x64 atlas slot (128x64 each).
    unique_nums = sorted({h.number for h in hn_targets})
    hn_groups: list[tuple[str, list[str]]] = []
    for i in range(0, len(unique_nums), 4):
        chunk = unique_nums[i : i + 4]
        g_key = f"hngrid|{i // 4}|" + ",".join(chunk)
        hn_groups.append((g_key, chunk))
        entries.append((g_key, ("hngrid", chunk, None)))

    def _render_shop_or_hn(item):
        kind, a, b = item
        if kind == "hngrid":
            return texture_atlas.render_housenumber_grid(a)
        return texture_atlas.render_shop_fascia(a, b)

    mat_name, _dds, vfs_tex, uv_map, _img = texture_atlas.pack_atlas(
        entries,
        _render_shop_or_hn,
        out_dir,
        vfs_dir,
        prefix="sh",
    )
    if not mat_name or not vfs_tex:
        return None, None, set()

    # Slice individual house number UVs from their packed 4x1 grid slots.
    for g_key, chunk in hn_groups:
        slot_uv = uv_map.get(g_key)
        if slot_uv is None:
            continue
        for col, num in enumerate(chunk):
            uv_map[f"hn|{num}"] = texture_atlas.uv_subrect(
                slot_uv,
                col * 0.25 + 0.008,
                0.06,
                (col + 1) * 0.25 - 0.008,
                0.94,
            )

    # Clear legacy generic sign bands so enhanced brand panels never z-fight.
    for spec, _, _ in items:
        if id(spec) in suppress_ids:
            spec.sign = None

    shop_blob = placement.encode_shop_and_housenumbers_mesh(targets, hn_targets, mat_name, uv_map)
    if shop_blob is None:
        return None, None, set()

    if targets:
        face = {
            mat_name: {
                "texture": vfs_tex,
                "emissive": True,
                "nits": 35,
                "glowColor": "1 0.94 0.84",
            }
        }
    else:
        face = {mat_name: {"texture": vfs_tex, "emissive": False}}
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

    if near_roads and out_dir is not None and vfs_dir is not None:
        posts = (
            placement.plan_street_signs(
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
            if street_names
            else []
        )
        furn_plan = furniture_de.plan_de_street_furniture(
            md,
            frame,
            box,
            near_roads,
            walks,
            props,
            drives,
            garage_drives,
            rings,
            ground,
            items=items,
            tx=tx,
            ty=ty,
        )
        if furn_plan.suppressed_recycle_xy and isinstance(props, list):
            props[:] = [
                r
                for r in props
                if not (
                    str(r[0]) == "recyclebin"
                    and any(math.hypot(float(r[1]) - sx, float(r[2]) - sy) < 5.0 for sx, sy in furn_plan.suppressed_recycle_xy)
                )
            ]

        if posts or furn_plan.has_any:
            entries: list[tuple[str, object]] = [
                (f"street|{variant}|{name}", ("street", name, variant))
                for p in posts
                for name, _d, _z, variant in p.blades
            ]
            if furn_plan.has_any:
                entries.append((furniture_de.FURNITURE_SWATCH_KEY, ("swatch", None, None)))
                for stop in furn_plan.bus_stops:
                    entries.append((f"busstop|{stop.name}", ("busstop", stop.name, None)))
                for fp in furn_plan.fuel_pylons:
                    entries.append((
                        f"fuel|{fp.brand_key}|{fp.e10}|{fp.e5}|{fp.diesel}",
                        ("fuel", fp, None),
                    ))

            def _render_street_slot(item):
                kind, a, b = item
                if kind == "swatch":
                    return texture_atlas.render_furniture_swatch()
                if kind == "busstop":
                    return texture_atlas.render_bus_stop_panel(a)
                if kind == "fuel":
                    return texture_atlas.render_fuel_pylon(a.brand_key, a.brand_label, a.e10, a.e5, a.diesel)
                return texture_atlas.render_street_plate(a, variant=b)

            mat_name, _dds, vfs_tex, uv_map, _img = texture_atlas.pack_atlas(
                entries,
                _render_street_slot,
                out_dir,
                vfs_dir,
                prefix="st",
            )
            if mat_name and vfs_tex:
                street_blob = placement.encode_streets_and_furniture_mesh(posts, furn_plan, mat_name, uv_map, (x0, y0, 0.0))
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
