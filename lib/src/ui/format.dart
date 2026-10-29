String formatBytes(int bytes) {
  if (bytes < 0) return 'Unknown size';
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final text = value >= 100
      ? value.round().toString()
      : value.toStringAsFixed(1);
  return '$text ${units[unit]}';
}

String formatRelative(DateTime time, {DateTime? now}) {
  final reference = now ?? DateTime.now();
  final delta = reference.difference(time);
  if (delta.inSeconds < 45) return 'Just now';
  if (delta.inMinutes < 60) return '${delta.inMinutes} min ago';
  if (delta.inHours < 24) return '${delta.inHours} h ago';
  if (delta.inDays == 1) return 'Yesterday';
  if (delta.inDays < 7) return '${delta.inDays} days ago';
  final local = time.toLocal();
  return '${local.day}/${local.month}/${local.year}';
}

String statusLabel(String wireStatus) {
  switch (wireStatus) {
    case 'queued':
      return 'Queued';
    case 'downloading':
      return 'Downloading';
    case 'preparing':
      return 'Preparing video';
    case 'saving':
      return 'Adding to Photos';
    case 'completed':
      return 'Saved';
    case 'failed':
      return 'Failed';
    case 'canceled':
      return 'Canceled';
    default:
      return wireStatus;
  }
}
