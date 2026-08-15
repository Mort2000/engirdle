import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/theme.dart';
import '../../../contracts/readpack_v1/article.dart';
import '../../library/domain/installed_article.dart';
import 'run_spans.dart';

/// One sentence as an independent interaction unit (MOB-READ-001).
///
/// - its own [SelectableText]: long-press starts a selection that can never
///   cross sentence boundaries (跨句选择 is an MVP exclusion);
/// - custom context menu: 词典 / 复制 / 本机翻译 (screen 09);
/// - tap opens the sentence menu unless a selection is active (短按取消优先,
///   UX-A4): routed through [SelectableText.onTap], which fires after the
///   native selection collapse; the outer GestureDetector only covers the
///   container padding that the text hit area does not reach;
/// - v1.1 inline [runs] render as styled TextSpans (emphasis, strong,
///   strikethrough, code, link, image alt, hard breaks) via
///   [buildRunSpans]. Run texts concatenate to [text], so selection offsets
///   stay sentence-local.
///
/// Links: url_launcher is deliberately not a dependency, so a link renders
/// as styled text and a long-press copies the target — and only ever an
/// http/https target; file: and javascript: (or any other scheme) never
/// become actionable.
class SentenceView extends StatefulWidget {
  const SentenceView({
    required this.sentence,
    required this.text,
    required this.style,
    required this.playing,
    required this.selectable,
    required this.onTap,
    required this.onLookup,
    required this.onTranslate,
    required this.onSelectionChanged,
    this.runs,
    this.onLongPressHint,
    super.key,
  });

  final InstalledSentence sentence;

  /// English text in en/bilingual modes; the translation in zh-only mode.
  final String text;

  /// Inline runs for en/bilingual modes; null (or empty) renders [text] as
  /// one plain span (zh-only passes no runs).
  final List<ArticleRun>? runs;

  final TextStyle style;
  final bool playing;

  /// False in zh-only mode (dictionary works on English originals).
  final bool selectable;
  final VoidCallback onTap;

  final void Function(String selection) onLookup;
  final void Function(String selection) onTranslate;
  final void Function(bool hasSelection) onSelectionChanged;

  /// zh-only long-press hint.
  final VoidCallback? onLongPressHint;

  @override
  State<SentenceView> createState() => SentenceViewState();
}

/// Public so the reader page can reach [clearSelection] through a GlobalKey
/// (cross-sentence selection tracking, UX-A4).
class SentenceViewState extends State<SentenceView> {
  /// The context-menu builder is the only public hook to the inner
  /// [EditableTextState]; captured there on first show.
  EditableTextState? _editableTextState;

  /// Link long-press recognizers created by the current build. Recreated on
  /// every build; the previous generation is disposed first.
  final List<LongPressGestureRecognizer> _linkRecognizers = [];

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final recognizer in _linkRecognizers) {
      recognizer.dispose();
    }
    _linkRecognizers.clear();
  }

  /// Collapses any visible selection without touching the text — used by the
  /// reader page for cancel-first taps (constraints §7.3): the page tracks
  /// which sentence owns the live selection and clears it from outside,
  /// because collapsed-selection callbacks arrive too unreliably for that.
  void clearSelection() {
    final editable = _editableTextState;
    if (editable == null || !editable.mounted) return;
    editable.userUpdateTextEditingValue(
      editable.textEditingValue.copyWith(
        selection: const TextSelection.collapsed(offset: -1),
      ),
      SelectionChangedCause.keyboard,
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = PaletteScope.of(context);
    _disposeRecognizers();
    final spans = _buildSpans();
    Widget text;
    if (widget.selectable) {
      text = SelectableText.rich(
        TextSpan(children: spans),
        style: widget.style,
        contextMenuBuilder: _buildContextMenu,
        // §7.3 core gesture: the internal selection gestures outrank the
        // outer GestureDetector in the arena, so the tap must be wired here —
        // this callback fires after the native selection collapse is handled.
        onTap: widget.onTap,
        onSelectionChanged: (selection, cause) {
          widget.onSelectionChanged(!selection.isCollapsed);
        },
      );
    } else {
      text = GestureDetector(
        onLongPress: widget.onLongPressHint,
        child: Text.rich(
          TextSpan(style: widget.style, children: spans),
        ),
      );
    }
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: widget.onTap,
      child: Container(
        decoration: widget.playing
            ? BoxDecoration(
                color: palette.playHighlight,
                border: Border(
                  left: BorderSide(
                    color: palette.playHighlightBorder,
                    width: 3,
                  ),
                ),
                borderRadius: const BorderRadius.horizontal(
                  right: Radius.circular(6),
                ),
              )
            : null,
        padding: widget.playing
            ? const EdgeInsets.only(left: 7, top: 1, bottom: 1)
            : const EdgeInsets.symmetric(vertical: 1),
        margin: widget.playing ? const EdgeInsets.only(left: 0) : null,
        child: text,
      ),
    );
  }

  List<InlineSpan> _buildSpans() {
    final runs = widget.runs;
    if (runs == null || runs.isEmpty) {
      return [TextSpan(text: widget.text)];
    }
    return buildRunSpans(
      runs: runs,
      palette: PaletteScope.of(context),
      recognizerFor: (run) => _linkRecognizerFor(run.href),
    );
  }

  /// Long-press copies the link target — only http(s). Every other scheme
  /// (file:, javascript:, ...) stays inert styled text.
  LongPressGestureRecognizer? _linkRecognizerFor(String? href) {
    if (href == null) return null;
    final uri = Uri.tryParse(href);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return null;
    }
    final recognizer = LongPressGestureRecognizer()
      ..onLongPress = () => _copyLink(href);
    _linkRecognizers.add(recognizer);
    return recognizer;
  }

  void _copyLink(String href) {
    Clipboard.setData(ClipboardData(text: href));
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(
      SnackBar(
        content: Text('链接已复制：$href'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Widget _buildContextMenu(
    BuildContext context,
    EditableTextState editableTextState,
  ) {
    // Only public hook to the inner EditableText: remembered so
    // [clearSelection] can collapse the selection from outside later.
    _editableTextState = editableTextState;
    final selection = editableTextState.textEditingValue.selection;
    final selected = selection.isValid && !selection.isCollapsed
        ? selection.textInside(widget.text)
        : '';
    final items = [
      ContextMenuButtonItem(
        label: '词典',
        onPressed: () {
          editableTextState.hideToolbar();
          widget.onLookup(selected);
        },
      ),
      ContextMenuButtonItem(
        label: '复制',
        onPressed: () {
          editableTextState.copySelection(SelectionChangedCause.toolbar);
        },
      ),
      ContextMenuButtonItem(
        label: '本机翻译',
        onPressed: () {
          editableTextState.hideToolbar();
          widget.onTranslate(selected);
        },
      ),
    ];
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: editableTextState.contextMenuAnchors,
      buttonItems: items,
    );
  }
}
