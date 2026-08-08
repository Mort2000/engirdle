import 'package:flutter/material.dart';

import '../../../app/theme.dart';
import '../application/playback_controller.dart';
import '../domain/playback_models.dart';

/// Screen 14 — the single-session playback control bar.
///
/// Deliberately omitted (MVP exclusions): speed, loop, prev/next queue,
/// playlist, draggable progress, media notification / background playback.
class PlaybackBar extends StatelessWidget {
  const PlaybackBar({required this.controller, super.key});

  final PlaybackController controller;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<PlaybackSnapshot>(
      valueListenable: controller.state,
      builder: (context, state, _) {
        if (state.phase == PlaybackPhase.idle) {
          return const SizedBox.shrink();
        }
        final theme = Theme.of(context);
        final playing = state.phase == PlaybackPhase.playing;
        final (title, subtitle) = _labels(state);
        return Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            border: Border(
                top: BorderSide(color: PaletteScope.of(context).outline)),
          ),
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: SafeArea(
            top: false,
            child: Row(
              children: [
                _RoundButton(
                  icon: playing ? Icons.pause : Icons.play_arrow,
                  filled: true,
                  onPressed: playing ? controller.pause : controller.resume,
                ),
                const SizedBox(width: 11),
                _RoundButton(
                  icon: Icons.stop,
                  filled: false,
                  onPressed: controller.stop,
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(title,
                          style: theme.textTheme.titleSmall,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                      Text(subtitle,
                          style: theme.textTheme.bodySmall,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  (String, String) _labels(PlaybackSnapshot state) {
    switch (state.mode) {
      case PlaybackMode.sentence:
        return (
          '单句播放 · ${state.currentLabel ?? ''}',
          '${_clock(state.position)} / ${_clock(state.playableDuration)} · 句末自动停止',
        );
      case PlaybackMode.continuous:
        return (
          '连续播放 · 当前${state.currentLabel ?? ''}',
          '起点：${state.startLabel ?? ''} · 保留句间停顿 · 播放至文末结束',
        );
      case null:
        return ('', '');
    }
  }

  static String _clock(Duration duration) {
    final totalSeconds = duration.inSeconds;
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.icon,
    required this.filled,
    required this.onPressed,
  });

  final IconData icon;
  final bool filled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: filled ? theme.colorScheme.primaryContainer : Colors.transparent,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: SizedBox(
          width: 40,
          height: 40,
          child: Icon(icon,
              size: 20,
              color: filled
                  ? theme.colorScheme.onPrimaryContainer
                  : theme.colorScheme.onSurfaceVariant),
        ),
      ),
    );
  }
}
