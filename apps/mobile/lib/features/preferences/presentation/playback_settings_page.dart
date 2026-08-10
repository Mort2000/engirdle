import 'package:flutter/material.dart';

import '../../../app/scope.dart';
import '../domain/playback_preferences.dart';

/// User-facing playback behavior settings.
class PlaybackSettingsPage extends StatelessWidget {
  const PlaybackSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final preferences = AppScope.of(context).preferences;
    return ValueListenableBuilder<PlaybackPreferences>(
      valueListenable: preferences.playbackNotifier,
      builder: (context, value, _) => Scaffold(
        appBar: AppBar(title: const Text('播放设置')),
        body: ListView(
          padding: const EdgeInsets.all(14),
          children: [
            Card(
              child: SwitchListTile(
                title: const Text('播放时打断背景音乐'),
                subtitle: const Text(
                  '开启后会请求短时独占音频焦点，尽力暂停音乐类应用；'
                  '焦点不可用时仍继续播放。部分应用或旧系统可能仍会混音。',
                ),
                value: value.interruptBackgroundAudio,
                onChanged: (enabled) => preferences.updatePlayback(
                  value.copyWith(interruptBackgroundAudio: enabled),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
