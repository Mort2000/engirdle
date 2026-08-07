class ProductionError(Exception):
    """Base production workflow error."""


class JobNotFound(ProductionError):
    """The requested build job does not exist."""


class InvalidJobState(ProductionError):
    """The requested transition is not allowed from the current job state."""


class AdapterContractError(ProductionError):
    """A replaceable adapter returned data that violates the frozen structure."""
