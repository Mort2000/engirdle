class ContentError(Exception):
    """Base content domain error."""


class ContentNotFound(ContentError):
    """The requested article revision does not exist."""


class InvalidContent(ContentError):
    """The supplied article or structure is invalid."""


class ImmutableRevision(ContentError):
    """The requested operation would mutate a frozen revision."""


class UnsupportedMarkdown(InvalidContent):
    """The markdown contains nodes that may not be published (design §13)."""

    code = "unsupported_markdown"


class MarkdownResourceLimit(InvalidContent):
    """A table, code block or nesting depth exceeds the frozen limits (design §13)."""

    code = "markdown_resource_limit"


class NoNarratableContent(InvalidContent):
    """The revision has no narratable sentence for the fixed audio layout (design §13)."""

    code = "no_narratable_content"
