"""Helpers for the redacted ``/models`` catalog."""

import asyncio
from collections.abc import Iterable

from subconscious_engine.capabilities import CapabilityResolver, ModelCapabilities

from .models import ModelConfigurationDto, ModelDto


ECHO_MODEL = ModelDto(
    id="echo",
    name="Echo (dev)",
    provider="subconscious",
    description="Echoes the last user message back; no credentials required.",
    capabilities=ModelCapabilities(chat=True, sources=["builtin"]),
)


def build_model_catalog(configurations: Iterable[ModelConfigurationDto]) -> list[ModelDto]:
    """Project redacted configurations into the chat model catalog."""

    result = [
        ModelDto(
            id=item.id,
            name=item.alias if item.alias and item.alias.strip() else item.model,
            provider=item.provider,
            description=item.model if item.alias and item.alias.strip() else None,
        )
        for item in configurations
    ]
    result.append(ECHO_MODEL)
    return result


async def build_model_catalog_with_capabilities(
    configurations: Iterable[ModelConfigurationDto], resolver: CapabilityResolver
) -> list[ModelDto]:
    """The catalog with each model's resolved capabilities attached."""

    items = list(configurations)
    resolved = await asyncio.gather(
        *(resolver.resolve(item.provider, item.model, item.capabilities) for item in items)
    )
    return [
        model.model_copy(update={"capabilities": capabilities})
        for model, capabilities in zip(build_model_catalog(items)[: len(items)], resolved)
    ] + [ECHO_MODEL]


async def model_catalog(store: object) -> list[ModelDto]:
    """Build a catalog from any store implementing the asynchronous list method."""

    configurations = await store.list()  # type: ignore[attr-defined]
    return build_model_catalog(configurations)
