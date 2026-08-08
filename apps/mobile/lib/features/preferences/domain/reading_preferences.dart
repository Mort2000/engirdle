/// Global reading typography (MOB-READ-004, screen 13).
///
/// Presets only — no arbitrary color pickers (MVP exclusion). Per-article
/// display mode is persisted separately and never overwrites these.
enum ReaderFontFamily { serif, sans }

enum ReaderFontSize {
  small(14, '小 14'),
  standard(16, '标准 16'),
  large(18, '大 18'),
  extraLarge(20, '特大 20');

  const ReaderFontSize(this.logicalPixels, this.label);
  final double logicalPixels;
  final String label;
}

enum ReaderLineHeight {
  compact(1.5),
  comfortable(1.8),
  loose(2.0);

  const ReaderLineHeight(this.factor);
  final double factor;
}

enum ReaderMargin {
  narrow(14),
  standard(20),
  wide(28);

  const ReaderMargin(this.logicalPixels);
  final double logicalPixels;
}

enum ReaderThemePreset { paper, warm, dark }

class ReadingPreferences {
  const ReadingPreferences({
    this.fontFamily = ReaderFontFamily.serif,
    this.fontSize = ReaderFontSize.standard,
    this.lineHeight = ReaderLineHeight.comfortable,
    this.margin = ReaderMargin.standard,
    this.themePreset = ReaderThemePreset.paper,
  });

  final ReaderFontFamily fontFamily;
  final ReaderFontSize fontSize;
  final ReaderLineHeight lineHeight;
  final ReaderMargin margin;
  final ReaderThemePreset themePreset;

  ReadingPreferences copyWith({
    ReaderFontFamily? fontFamily,
    ReaderFontSize? fontSize,
    ReaderLineHeight? lineHeight,
    ReaderMargin? margin,
    ReaderThemePreset? themePreset,
  }) =>
      ReadingPreferences(
        fontFamily: fontFamily ?? this.fontFamily,
        fontSize: fontSize ?? this.fontSize,
        lineHeight: lineHeight ?? this.lineHeight,
        margin: margin ?? this.margin,
        themePreset: themePreset ?? this.themePreset,
      );
}
