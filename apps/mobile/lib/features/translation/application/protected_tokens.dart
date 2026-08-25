import '../../../contracts/readpack_v1/article.dart';
import '../domain/translation_errors.dart';

/// Protected-literal handling for the shared translation v1 protocol.
///
/// Inline code literals and autolink URIs never enter an LLM request: every
/// protected run occurrence is replaced, in wire order, by its own stable
/// `‰N‰` placeholder; the literal is restored only after the model reply
/// passes slot-aware verification. Numbering is scoped to one message — the
/// source context numbers document-wide, each unit request numbers only its
/// own literals (contracts/translation/v1/protocol.json).
const String kPlaceholderSentinel = '‰';

/// Canonical placeholder shape: STRICT ASCII digits between two sentinels.
/// The regex must stay `[0-9]` — a `\d` class or an int() parse would
/// normalize non-ASCII digit lookalikes or leading zeros onto a real index;
/// consumers always compare the FULL placeholder string.
final RegExp _placeholderPattern = RegExp(
  '$kPlaceholderSentinel[0-9]+$kPlaceholderSentinel',
);

bool isProtectedRun(ArticleRun run) {
  if (run.kind == ArticleRunKind.code) return run.text.isNotEmpty;
  if (run.kind == ArticleRunKind.link) {
    // Autolinks (display text == URI): the URL must survive translation.
    // Ordinary links translate their display text; the href never enters the
    // wire, so there is nothing to protect.
    final href = run.href;
    return href != null &&
        href.isNotEmpty &&
        run.text.trim() == href.trim();
  }
  return false;
}

class ProtectedToken {
  const ProtectedToken({
    required this.index,
    required this.literal,
    required this.slot,
  });

  final int index;

  /// The protected literal (code text or autolink URI); never serialized.
  final String literal;

  /// The wire slot (sentence / table cell position) the token came from.
  /// Verification is slot-aware: swapping two placeholders between slots is
  /// rejected instead of binding the wrong literal to the wrong slot.
  final int slot;

  String get placeholder =>
      '$kPlaceholderSentinel$index$kPlaceholderSentinel';
}

class ProtectedTokenMap {
  const ProtectedTokenMap({this.tokens = const []});

  final List<ProtectedToken> tokens;

  /// Restores placeholders in ONE pass. A sequential replace chain would
  /// cascade if one literal itself contains another placeholder pattern;
  /// [replaceAllMapped] never rescans substituted text. Matching is by the
  /// complete canonical spelling, so lookalikes never normalize onto a token.
  String restore(String text) {
    final byPlaceholder = {
      for (final token in tokens) token.placeholder: token,
    };
    return text.replaceAllMapped(_placeholderPattern, (match) {
      return byPlaceholder[match.group(0)]?.literal ?? match.group(0)!;
    });
  }
}

/// Builds the protected wire texts from inline run lists, occurrence-based
/// and deterministic: the same walk always produces the same texts and map.
/// [slot] of each token is the index of its run list (sentence or cell).
(List<String>, ProtectedTokenMap) protectRunLists(
  List<List<ArticleRun>> runLists,
) {
  final texts = <String>[];
  final tokens = <ProtectedToken>[];
  for (var slot = 0; slot < runLists.length; slot++) {
    final parts = <String>[];
    for (final run in runLists[slot]) {
      if (isProtectedRun(run)) {
        final token = ProtectedToken(
          index: tokens.length,
          literal: run.text,
          slot: slot,
        );
        tokens.add(token);
        parts.add(token.placeholder);
      } else {
        parts.add(run.text);
      }
    }
    texts.add(parts.join());
  }
  return (texts, ProtectedTokenMap(tokens: tokens));
}

/// Every placeholder must survive exactly once, in its own slot. Every
/// sentinel character in the reply must belong to a well-formed placeholder:
/// a stray sentinel, leading zeros, non-ASCII digit lookalikes or invented
/// indices are protocol errors (protocol.json `placeholder.verification`).
void verifyProtectedTokens(
  ProtectedTokenMap map,
  List<String> translated,
) {
  final expectedInSlot = List<Set<String>>.generate(
    translated.length,
    (_) => {},
  );
  for (final token in map.tokens) {
    if (token.slot < 0 || token.slot >= translated.length) {
      throw TranslationProtocolError(
        'protected token ${token.index} has slot ${token.slot} outside the '
        '${translated.length} translated items',
      );
    }
    expectedInSlot[token.slot].add(token.placeholder);
  }
  for (var slot = 0; slot < translated.length; slot++) {
    final text = translated[slot];
    final matches = _placeholderPattern.allMatches(text).toList();
    if (kPlaceholderSentinel.allMatches(text).length != 2 * matches.length) {
      throw TranslationProtocolError(
        'slot $slot contains a stray or malformed placeholder marker',
      );
    }
    for (final match in matches) {
      final placeholder = match.group(0)!;
      if (!expectedInSlot[slot].remove(placeholder)) {
        throw TranslationProtocolError(
          'slot $slot carries placeholder "$placeholder" which is not the '
          'canonical spelling of the token protected there',
        );
      }
    }
  }
  for (var slot = 0; slot < expectedInSlot.length; slot++) {
    final remaining = expectedInSlot[slot];
    if (remaining.isNotEmpty) {
      final first = remaining.toList()..sort();
      throw TranslationProtocolError(
        'slot $slot dropped placeholder "${first.first}"',
      );
    }
  }
}
