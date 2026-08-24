/// A raw-source parse failure with a stable machine-readable code (surfaced
/// by the import confirmation UI) plus diagnostic detail for logs.
class SourceParseException implements Exception {
  const SourceParseException(this.code, [this.detail = '']);

  /// One of:
  /// - `empty_body` — no visible content
  /// - `no_blocks` — content produced no blocks
  /// - `raw_html` — HTML block or inline HTML (both platforms reject)
  /// - `empty_text_block` — heading without readable text
  /// - `link_reference_definition` — mobile subset rejects `[label]: url`
  /// - `autolink` — mobile subset rejects `<scheme:...>` autolinks
  /// - `html_entity` — mobile subset rejects `&entity;` references
  /// - `nesting_depth` — quote/list nesting beyond 4
  /// - `resource_limit` — a frozen MarkdownLimits value was exceeded
  final String code;
  final String detail;

  @override
  String toString() => 'SourceParseException($code$detail)';
}

/// Non-fatal parse finding surfaced on the import confirmation page.
class SourceParseWarning {
  const SourceParseWarning({required this.code, this.blockIndex});

  final String code;

  /// Block position the warning refers to (1-based like the PC parse index).
  final int? blockIndex;
}
