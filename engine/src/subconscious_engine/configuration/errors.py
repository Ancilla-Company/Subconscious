"""Errors raised by encrypted model configuration persistence."""


class ModelConfigurationStoreError(RuntimeError):
    """Encrypted model data could not be read or safely updated."""


# Compatibility with the reference implementation's public exception name.
ModelConfigurationStoreException = ModelConfigurationStoreError
