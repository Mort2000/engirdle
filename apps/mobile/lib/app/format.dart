import '../shared_kernel/failures.dart';

/// User-facing, de-engineered text (constraints §7.2-bis): no sentence IDs,
/// hashes, staging paths or version internals in the main flow.

String formatDurationMs(int ms) {
  final totalSeconds = ms ~/ 1000;
  final minutes = totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;
  if (minutes >= 60) {
    final hours = minutes ~/ 60;
    final rest = minutes % 60;
    return '$hours:${rest.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

String formatBytes(int bytes) {
  final mb = bytes / (1024 * 1024);
  if (mb >= 100) return '${mb.toStringAsFixed(0)} MB';
  if (mb >= 1) return '${mb.toStringAsFixed(1)} MB';
  final kb = bytes / 1024;
  return '${kb.toStringAsFixed(0)} KB';
}

/// Groups an integer with thousands separators (design copy: 「约 4,200 词」).
/// Hand-rolled to avoid pulling in intl for a single format.
String formatThousands(int value) {
  final digits = value.toString();
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
    buffer.write(digits[i]);
  }
  return buffer.toString();
}

String formatClock(DateTime time) {
  final local = time.toLocal();
  return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
}

/// 「刚刚 / N 分钟前 / 昨天 21:14 / 2026-08-04」.
String formatRelative(DateTime time) {
  final now = DateTime.now();
  final local = time.toLocal();
  final diff = now.difference(local);
  if (diff.inMinutes < 1) return '刚刚';
  if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(local.year, local.month, local.day);
  final dayDiff = today.difference(day).inDays;
  if (dayDiff <= 0) return '今天 ${formatClock(local)}';
  if (dayDiff == 1) return '昨天 ${formatClock(local)}';
  if (dayDiff < 7) return '$dayDiff 天前';
  return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
}

String formatDate(DateTime time) {
  final local = time.toLocal();
  return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
}

/// Maps a failure to its category + actionable user text (screens 02/04).
String failureMessage(AppFailure failure) {
  switch (failure.kind) {
    case FailureKind.connection:
      return switch (failure.message) {
        'invalid url' =>
          '地址格式无效：需以 http:// 或 https:// 开头，例如 http://192.168.1.12:8766。',
        'non-lan http rejected' =>
          '已拒绝：非局域网 HTTP 地址。明文 HTTP 仅限局域网；公网请改用 HTTPS。',
        'timeout' => '连接超时：几秒内未收到响应。请检查 PC 是否在线，以及手机与电脑是否处于同一局域网。',
        'connection refused' =>
          '无法连接服务：连接被拒绝。请依次确认：1. PC 端已显式开启「局域网只读服务」；2. 手机与 PC 处于同一局域网；3. 地址与端口填写正确。',
        'host unreachable' => '无法连接服务：找不到该地址。请确认 PC 在线且与手机处于同一局域网。',
        'service not configured' => '尚未配置服务地址。请先设置 PC 的局域网只读服务地址。',
        'invalid catalog' => '服务返回的目录无法识别。请确认地址指向 Engirdle 的局域网只读服务。',
        'response too large' => '服务返回内容超出限制。',
        _ => '无法连接服务。请确认 PC 已开启服务、手机与 PC 在同一网络。',
      };
    case FailureKind.download:
      return switch (failure.message) {
        'size mismatch' => '校验失败：文件不完整或损坏。下载的文件与目录声明不一致，已丢弃本次下载，未影响本机内容，可重试。',
        'sha256 mismatch' => '校验失败：文件不完整或损坏。下载的文件与目录声明不一致，已丢弃本次下载，未影响本机内容，可重试。',
        'cancelled' => '已取消。未影响本机内容。',
        'package too large' => '下载内容超出大小限制，已放弃本次下载。',
        _ => '下载失败。已丢弃本次下载，未影响本机内容，可重试。',
      };
    case FailureKind.packageFormat:
      return '包校验未通过，无法导入。当前已安装内容不受影响。';
    case FailureKind.resourceLimit:
      return '包超出安全限制，已拒绝导入。当前已安装内容不受影响。';
    case FailureKind.database:
      return '保存到本机时出错，已回滚本次操作；当前版本与生词不受影响。';
    case FailureKind.player:
      return '播放失败。请重试；若持续失败，请重新导入该文章。';
  }
}

String failureKindLabel(FailureKind kind) => switch (kind) {
  FailureKind.connection => '连接错误',
  FailureKind.download => '下载错误',
  FailureKind.packageFormat => '包格式错误',
  FailureKind.resourceLimit => '资源超限错误',
  FailureKind.database => '数据库错误',
  FailureKind.player => '播放器错误',
};
