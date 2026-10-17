"""What a model can do, as data.

Capabilities are never hard-coded into feature code. Features ask the resolver whether
a configured model supports something (``speech_to_text``, ``realtime`` ...) and the
answer comes from, in order of precedence: the user's own override on the model
configuration, an optional remote capability service, and finally built-in heuristics.
``None`` always means unknown, which is different from ``False``.
"""

from __future__ import annotations

from collections.abc import Mapping
from typing import Any

from pydantic import BaseModel, ConfigDict
from pydantic.alias_generators import to_camel

FLAGS: tuple[str, ...] = (
    "chat",
    "tool_calling",
    "vision",
    "audio_input",
    "audio_output",
    "speech_to_text",
    "text_to_speech",
    "realtime",
)


class ModelCapabilities(BaseModel):
    model_config = ConfigDict(
        extra="ignore", populate_by_name=True, alias_generator=to_camel
    )

    chat: bool | None = None
    tool_calling: bool | None = None
    vision: bool | None = None
    audio_input: bool | None = None
    audio_output: bool | None = None
    speech_to_text: bool | None = None
    text_to_speech: bool | None = None
    realtime: bool | None = None
    # Which layers contributed, highest precedence first (informational).
    sources: list[str] = []

    def supports(self, flag: str) -> bool:
        """Only an explicit ``True`` counts; unknown is not support."""
        return getattr(self, flag, None) is True

    def known(self) -> dict[str, bool]:
        return {
            flag: value
            for flag in FLAGS
            if (value := getattr(self, flag)) is not None
        }

    def overlaid_by(self, higher: "ModelCapabilities", source: str) -> "ModelCapabilities":
        """Return a copy where every flag ``higher`` knows replaces this one."""
        merged: dict[str, Any] = {**self.known(), **higher.known()}
        sources = list(higher.sources or ([source] if higher.known() else []))
        sources += [item for item in self.sources if item not in sources]
        return ModelCapabilities(**merged, sources=sources)

    @classmethod
    def from_override(cls, value: Any) -> "ModelCapabilities":
        """Parse the user's stored override; anything malformed is ignored."""
        if not isinstance(value, Mapping):
            return cls()
        flags = {
            flag: item
            for flag, item in ((f, value.get(f, value.get(to_camel(f)))) for f in FLAGS)
            if isinstance(item, bool)
        }
        return cls(**flags, sources=["override"] if flags else [])
