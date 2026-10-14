"""Dependency-free hive error type (importable from the API layer without cycles)."""


class HiveError(Exception):
    """A safe, user-presentable hive error."""

    def __init__(self, message: str, status_code: int = 400) -> None:
        super().__init__(message)
        self.message = message
        self.status_code = status_code
