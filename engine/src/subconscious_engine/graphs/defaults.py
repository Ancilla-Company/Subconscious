"""Load configured graph files with packaged defaults as the fallback."""

from importlib.resources import files
from pathlib import Path

from .schema import GraphKind, GraphSchema


def load_graph_schema(
    kind: GraphKind | str, override: Path | None = None
) -> GraphSchema:
    graph_kind = GraphKind(kind)
    if override is not None and override.is_file():
        text = override.read_text(encoding="utf-8")
    else:
        name = "conscious.json" if graph_kind is GraphKind.FOREGROUND else "subconscious.json"
        text = files("subconscious_engine.graphs").joinpath(name).read_text(encoding="utf-8")
    schema = GraphSchema.model_validate_json(text)
    if schema.kind is not graph_kind:
        raise ValueError(f"Expected a {graph_kind.value} graph, got {schema.kind.value}.")
    return schema
