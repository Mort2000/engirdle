import 'package:flutter/material.dart';

import '../../../app/scope.dart';
import '../domain/reading_preferences.dart';

/// Screen 13A — typography settings. All options persist immediately and
/// survive restarts (MOB-READ-004); presets only, no color pickers.
class TypographySettingsPage extends StatelessWidget {
  const TypographySettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final deps = AppScope.of(context);
    final theme = Theme.of(context);
    return ValueListenableBuilder<ReadingPreferences>(
      valueListenable: deps.preferences.notifier,
      builder: (context, prefs, _) {
        void update(ReadingPreferences next) =>
            deps.preferences.update(next);
        return Scaffold(
          appBar: AppBar(title: const Text('排版与主题')),
          body: ListView(
            padding: const EdgeInsets.all(14),
            children: [
              _Card(
                label: '字体',
                child: _Segmented<ReaderFontFamily>(
                  values: ReaderFontFamily.values,
                  selected: prefs.fontFamily,
                  labelOf: (v) => switch (v) {
                    ReaderFontFamily.serif => '衬线 Serif',
                    ReaderFontFamily.sans => '无衬线 Sans',
                  },
                  onChanged: (v) => update(prefs.copyWith(fontFamily: v)),
                ),
              ),
              _Card(
                label: '字号',
                trailing: Text(
                  prefs.fontSize.label,
                  style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w600),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _Segmented<ReaderFontSize>(
                      values: ReaderFontSize.values,
                      selected: prefs.fontSize,
                      labelOf: (v) => v.label,
                      onChanged: (v) => update(prefs.copyWith(fontSize: v)),
                    ),
                    const Divider(height: 20),
                    Text(
                      'The work is slow, but slowness is the point.',
                      style: TextStyle(
                        fontFamily:
                            prefs.fontFamily == ReaderFontFamily.serif
                                ? 'serif'
                                : null,
                        fontSize: prefs.fontSize.logicalPixels,
                        height: prefs.lineHeight.factor,
                      ),
                    ),
                  ],
                ),
              ),
              _Card(
                label: '行高',
                child: _Segmented<ReaderLineHeight>(
                  values: ReaderLineHeight.values,
                  selected: prefs.lineHeight,
                  labelOf: (v) => v.factor.toStringAsFixed(1),
                  onChanged: (v) => update(prefs.copyWith(lineHeight: v)),
                ),
              ),
              _Card(
                label: '页面边距',
                child: _Segmented<ReaderMargin>(
                  values: ReaderMargin.values,
                  selected: prefs.margin,
                  labelOf: (v) => switch (v) {
                    ReaderMargin.narrow => '窄',
                    ReaderMargin.standard => '标准',
                    ReaderMargin.wide => '宽',
                  },
                  onChanged: (v) => update(prefs.copyWith(margin: v)),
                ),
              ),
              _Card(
                label: '主题（预设，保证可读对比度）',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        _ThemeSwatch(
                          label: '纸白',
                          color: const Color(0xFFFDFAF3),
                          outline: const Color(0xFFDDD5C3),
                          selected:
                              prefs.themePreset == ReaderThemePreset.paper,
                          onTap: () => update(prefs.copyWith(
                              themePreset: ReaderThemePreset.paper)),
                        ),
                        const SizedBox(width: 12),
                        _ThemeSwatch(
                          label: '暖黄',
                          color: const Color(0xFFF3E9D2),
                          outline: const Color(0xFFDDCFA9),
                          selected:
                              prefs.themePreset == ReaderThemePreset.warm,
                          onTap: () => update(prefs.copyWith(
                              themePreset: ReaderThemePreset.warm)),
                        ),
                        const SizedBox(width: 12),
                        _ThemeSwatch(
                          label: '暗色',
                          color: const Color(0xFF171B17),
                          outline: const Color(0xFF3A4036),
                          selected:
                              prefs.themePreset == ReaderThemePreset.dark,
                          onTap: () => update(prefs.copyWith(
                              themePreset: ReaderThemePreset.dark)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text('仅提供预设主题，不提供自定义取色器（MVP 排除项）。',
                        style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
              Container(
                decoration: BoxDecoration(
                  color: const Color(0xFFD6E8DA),
                  borderRadius: BorderRadius.circular(12),
                ),
                padding: const EdgeInsets.all(12),
                child: const Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.check, size: 17, color: Color(0xFF234534)),
                    SizedBox(width: 9),
                    Expanded(
                      child: Text(
                        '以上设置保存在本机并即时生效，重启应用后保持；与每篇文章的显示模式选择分开持久化。',
                        style:
                            TextStyle(fontSize: 12, color: Color(0xFF234534)),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.label, required this.child, this.trailing});

  final String label;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(13),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                    child: Text(label, style: theme.textTheme.bodySmall)),
                if (trailing != null) ?trailing,
              ],
            ),
            const SizedBox(height: 6),
            child,
          ],
        ),
      ),
    );
  }
}

class _Segmented<T> extends StatelessWidget {
  const _Segmented({
    required this.values,
    required this.selected,
    required this.labelOf,
    required this.onChanged,
  });

  final List<T> values;
  final T selected;
  final String Function(T) labelOf;
  final void Function(T) onChanged;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<T>(
      segments: [
        for (final value in values)
          ButtonSegment(value: value, label: Text(labelOf(value))),
      ],
      selected: {selected},
      onSelectionChanged: (selection) => onChanged(selection.first),
      style: const ButtonStyle(visualDensity: VisualDensity.compact),
    );
  }
}

class _ThemeSwatch extends StatelessWidget {
  const _ThemeSwatch({
    required this.label,
    required this.color,
    required this.outline,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final Color color;
  final Color outline;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: selected ? theme.colorScheme.primary : outline,
                width: selected ? 2 : 1,
              ),
            ),
            child: selected
                ? Align(
                    alignment: Alignment.bottomRight,
                    child: Padding(
                      padding: const EdgeInsets.all(3),
                      child: CircleAvatar(
                        radius: 6,
                        backgroundColor: theme.colorScheme.primary,
                      ),
                    ),
                  )
                : null,
          ),
          const SizedBox(height: 4),
          Text(label, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}
