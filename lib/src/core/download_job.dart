/// Immutable view of a download job owned by the native layer.
///
/// The native side (WorkManager on Android, background URLSession + Photos on
/// iOS) is the single source of truth. Flutter only mirrors it for display, so
/// every field here maps 1:1 to a key in the bridge payload.
library;

import 'dart:math' as math;

enum MediaKind {
  video('video'),
  image('image'),
  unknown('unknown');

  const MediaKind(this.wire);

  final String wire;

  static MediaKind fromWire(Object? value) {
    for (final kind in values) {
      if (kind.wire == value) return kind;
    }
    return MediaKind.unknown;
  }
}

enum JobStatus {
  queued('queued'),
  downloading('downloading'),
  preparing('preparing'),
  saving('saving'),
  completed('completed'),
  failed('failed'),
  canceled('canceled');

  const JobStatus(this.wire);

  final String wire;

  static JobStatus fromWire(Object? value) {
    for (final status in values) {
      if (status.wire == value) return status;
    }
    return JobStatus.queued;
  }
}

enum JobOrigin {
  share('share'),
  manual('manual');

  const JobOrigin(this.wire);

  final String wire;

  static JobOrigin fromWire(Object? value) {
    for (final origin in values) {
      if (origin.wire == value) return origin;
    }
    return JobOrigin.manual;
  }
}

class DownloadJob {
  const DownloadJob({
    required this.id,
    required this.url,
    required this.kind,
    required this.fileName,
    required this.status,
    required this.origin,
    required this.createdAt,
    required this.updatedAt,
    this.bytesReceived = 0,
    this.totalBytes = -1,
    this.error,
    this.remoteId,
  });

  final String id;
  final String url;
  final MediaKind kind;
  final String fileName;
  final JobStatus status;
  final JobOrigin origin;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// Bytes written to disk so far. For resumable transfers this survives
  /// app restarts, so it can jump back up when a job is resumed.
  final int bytesReceived;

  /// -1 when the server did not send a Content-Length.
  final int totalBytes;

  final String? error;

  /// Opaque platform handle for the saved item (MediaStore URI on Android,
  /// Photos local identifier on iOS). Only set once [status] is completed.
  final String? remoteId;

  bool get isActive =>
      status == JobStatus.queued ||
      status == JobStatus.downloading ||
      status == JobStatus.preparing ||
      status == JobStatus.saving;

  bool get isSavable => status == JobStatus.completed;

  /// Transfer fraction, or null for unknown size and post-download processing.
  double? get progress {
    // Transfer completion is not conversion or Photos-import completion.
    if (status == JobStatus.preparing || status == JobStatus.saving) {
      return null;
    }
    if (totalBytes <= 0) return null;
    return (bytesReceived / totalBytes).clamp(0.0, 1.0);
  }

  Uri? get uri => Uri.tryParse(url);

  String get host => uri?.host ?? url;

  DownloadJob copyWith({
    MediaKind? kind,
    String? fileName,
    JobStatus? status,
    int? bytesReceived,
    int? totalBytes,
    String? error,
    bool clearError = false,
    String? remoteId,
    DateTime? updatedAt,
  }) {
    return DownloadJob(
      id: id,
      url: url,
      kind: kind ?? this.kind,
      fileName: fileName ?? this.fileName,
      status: status ?? this.status,
      origin: origin,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      bytesReceived: bytesReceived ?? this.bytesReceived,
      totalBytes: totalBytes ?? this.totalBytes,
      error: clearError ? null : (error ?? this.error),
      remoteId: remoteId ?? this.remoteId,
    );
  }

  static DownloadJob? tryFromMap(Map<Object?, Object?> map) {
    final id = _string(map['id']);
    final url = _string(map['url']);
    if (id == null || url == null) return null;
    return DownloadJob(
      id: id,
      url: url,
      kind: MediaKind.fromWire(map['kind']),
      fileName: _string(map['fileName']) ?? _fallbackFileName(url),
      status: JobStatus.fromWire(map['status']),
      origin: JobOrigin.fromWire(map['origin']),
      createdAt: _date(map['createdAt']),
      updatedAt: _date(map['updatedAt']),
      bytesReceived: _int(map['bytesReceived']) ?? 0,
      totalBytes: _int(map['totalBytes']) ?? -1,
      error: _string(map['error']),
      remoteId: _string(map['remoteId']),
    );
  }

  static List<DownloadJob> listFromWire(Object? value) {
    if (value is! List) return const [];
    final jobs = <DownloadJob>[];
    for (final entry in value) {
      if (entry is Map) {
        final job = tryFromMap(entry.cast<Object?, Object?>());
        if (job != null) jobs.add(job);
      }
    }
    return jobs;
  }

  static String _fallbackFileName(String url) {
    final segments = Uri.tryParse(url)?.pathSegments ?? const <String>[];
    if (segments.isEmpty) return 'media';
    final last = segments.last;
    return last.isEmpty ? 'media' : last;
  }

  static String? _string(Object? value) {
    if (value is String) {
      final trimmed = value.trim();
      return trimmed.isEmpty ? null : trimmed;
    }
    if (value is num) return value.toString();
    return null;
  }

  static int? _int(Object? value) {
    if (value is int) return value;
    if (value is num) return value.round();
    if (value is String) return int.tryParse(value);
    return null;
  }

  static DateTime _date(Object? value) {
    final millis = _int(value);
    if (millis == null || millis <= 0) {
      return DateTime.fromMillisecondsSinceEpoch(0);
    }
    return DateTime.fromMillisecondsSinceEpoch(millis);
  }

  static int percent(int received, int total) {
    if (total <= 0) return 0;
    return math.min(100, math.max(0, (received * 100 / total).round()));
  }
}
