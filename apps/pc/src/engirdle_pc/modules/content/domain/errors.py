class ContentError(Exception):
    """Base content domain error."""


class ContentNotFound(ContentError):
    """The requested article revision does not exist."""


class InvalidContent(ContentError):
    """The supplied article or structure is invalid."""


class ImmutableRevision(ContentError):
    """The requested operation would mutate a frozen revision."""
