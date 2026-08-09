import 'package:flutter/material.dart';

import '../../../app/theme.dart';
import '../../library/domain/installed_article.dart';

/// One sentence as an independent interaction unit (MOB-READ-001).
///
/// - its own [SelectableText]: long-press starts a selection that can never
///   cross sentence boundaries (跨句选择 is an MVP exclusion);
/// - custom context menu: 词典 / 复制 / 本机翻译 (screen 09);
/// - tap opens the sentence menu unless a selection is active (短按取消优先,
///   UX-A4): routed through [SelectableText.onTap], which fires after the
///   native selection collapse; the outer GestureDetector only covers the
///   container padding that the text hit area does not reach.
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
    this.onLongPressHint,
    super.key,
  });

  final InstalledSentence sentence;

  /// English text in en/bilingual modes; the translation in zh-only mode.
  final String text;
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
    Widget text;
    if (widget.selectable) {
      text = SelectableText(
        widget.text,
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
        child: Text(widget.text, style: widget.style),
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
