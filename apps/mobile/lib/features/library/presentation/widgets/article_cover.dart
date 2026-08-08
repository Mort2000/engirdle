import 'package:flutter/material.dart';

/// Uniform cover component (constraints §7.1): initials of the title's first
/// two words (original casing), one of five spine colors hashed by
/// article_id.
class ArticleCover extends StatelessWidget {
  const ArticleCover({
    required this.title,
    required this.articleId,
    this.width = 42,
    this.height = 56,
    super.key,
  });

  final String title;
  final String articleId;
  final double width;
  final double height;

  static const _colors = [
    Color(0xFF87977A), // 鼠尾草绿
    Color(0xFF7D5D6E), // 深李
    Color(0xFF71879B), // 雾蓝
    Color(0xFFB26E4F), // 陶土
    Color(0xFFC9B083), // 燕麦
  ];
  static const _onColors = [
    Color(0xFFF5F2E7),
    Color(0xFFF6EEE9),
    Color(0xFFEEF1F4),
    Color(0xFFFAF0E6),
    Color(0xFF4D4028),
  ];

  static String initialsOf(String title) {
    final words = title
        .trim()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) return '?';
    if (words.length == 1) {
      return words.first.firstChar;
    }
    return words[0].firstChar + words[1].firstChar;
  }

  static int colorIndexOf(String articleId) {
    var hash = 0;
    for (final unit in articleId.codeUnits) {
      hash = (hash * 31 + unit) & 0x7FFFFFFF;
    }
    return hash % _colors.length;
  }

  @override
  Widget build(BuildContext context) {
    final index = colorIndexOf(articleId);
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: _colors[index],
        borderRadius: BorderRadius.circular(6),
        boxShadow: const [
          BoxShadow(
            color: Color(0x38000000),
            blurRadius: 5,
            offset: Offset(0, 2),
          ),
        ],
      ),
      alignment: Alignment.center,
      child: Text(
        initialsOf(title),
        style: TextStyle(
          fontFamily: 'serif',
          fontSize: width * 0.38,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
          color: _onColors[index],
        ),
      ),
    );
  }
}

extension on String {
  String get firstChar => isEmpty ? this : substring(0, 1);
}
