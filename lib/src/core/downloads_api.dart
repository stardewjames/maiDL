/// Dart side of the native download bridge.
///
/// Contract (Android + iOS implement the same channel):
///
///   MethodChannel `app.maidl/downloads`
///     initialize()                        -> {jobs, photos, notifications,
///                                             canOpenSaved, platform}
///     enqueue({url, origin})              -> job map
///     history()                           -> [job map]
///     retry({id})                         -> job map
///     cancel({id})
///     remove({id})
///     clearHistory()
///     openSaved({id})                     -> bool
///     requestPhotoAccess()                -> permission wire string
///     requestNotifications()              -> bool
///
///   EventChannel `app.maidl/download_events` -> job map on every change.
///
/// Job map keys: id, url, kind, fileName, status, origin, createdAt, updatedAt,
/// bytesReceived, totalBytes, error, remoteId. See [DownloadJob].
library;

import 'dart:async';

import 'package:flutter/services.dart';

import 'download_job.dart';

enum PermissionState {
  granted('granted'),
  denied('denied'),
  notDetermined('notDetermined'),
  unsupported('unsupported');

  const PermissionState(this.wire);

  final String wire;

  bool get isGranted => this == PermissionState.granted;

  static PermissionState fromWire(Object? value) {
    for (final state in values) {
      if (state.wire == value) return state;
    }
    return PermissionState.unsupported;
  }
}

class NativeSnapshot {
  const NativeSnapshot({
    required this.jobs,
    required this.platform,
    this.photoAccess = PermissionState.unsupported,
    this.notifications = PermissionState.unsupported,
    this.canOpenSaved = false,
  });

  final List<DownloadJob> jobs;
  final String platform;
  final PermissionState photoAccess;
  final PermissionState notifications;
  final bool canOpenSaved;
}

/// A failure the UI can show verbatim. Never leaks stack traces to the user.
class NativeFailure implements Exception {
  const NativeFailure(this.code, this.message);

  final String code;
  final String message;

  bool get isUnavailable => code == 'unavailable';

  @override
  String toString() => message;
}

abstract class DownloadsApi {
  Future<NativeSnapshot> initialize();

  Stream<DownloadJob> get updates;

  Future<DownloadJob> enqueue(String url, {required JobOrigin origin});

  Future<List<DownloadJob>> history();

  Future<DownloadJob> retry(String id);

  Future<void> cancel(String id);

  Future<void> remove(String id);

  Future<void> clearHistory();

  Future<bool> openSaved(String id);

  Future<PermissionState> requestPhotoAccess();

  Future<bool> requestNotifications();
}

class MethodChannelDownloadsApi implements DownloadsApi {
  MethodChannelDownloadsApi({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
  }) : _method = methodChannel ?? const MethodChannel('app.maidl/downloads'),
       _event = eventChannel ?? const EventChannel('app.maidl/download_events');

  final MethodChannel _method;
  final EventChannel _event;
  Stream<DownloadJob>? _updates;

  @override
  Stream<DownloadJob> get updates {
    return _updates ??= _event
        .receiveBroadcastStream()
        .map((event) {
          if (event is! Map) return null;
          return DownloadJob.tryFromMap(event.cast<Object?, Object?>());
        })
        .where((job) => job != null)
        .cast<DownloadJob>()
        .handleError((Object _) {
          // Native event failures are non-fatal: the next history refresh
          // reconciles state.
        });
  }

  @override
  Future<NativeSnapshot> initialize() async {
    final raw = await _callMap('initialize');
    return NativeSnapshot(
      jobs: DownloadJob.listFromWire(raw['jobs']),
      platform: (raw['platform'] as String?) ?? '',
      photoAccess: PermissionState.fromWire(raw['photos']),
      notifications: PermissionState.fromWire(raw['notifications']),
      canOpenSaved: raw['canOpenSaved'] == true,
    );
  }

  @override
  Future<List<DownloadJob>> history() async {
    final raw = await _call<Object?>('history');
    return DownloadJob.listFromWire(raw);
  }

  @override
  Future<DownloadJob> enqueue(String url, {required JobOrigin origin}) {
    return _callJob('enqueue', {'url': url, 'origin': origin.wire});
  }

  @override
  Future<DownloadJob> retry(String id) => _callJob('retry', {'id': id});

  @override
  Future<void> cancel(String id) => _callVoid('cancel', {'id': id});

  @override
  Future<void> remove(String id) => _callVoid('remove', {'id': id});

  @override
  Future<void> clearHistory() => _callVoid('clearHistory');

  @override
  Future<bool> openSaved(String id) => _call<bool>('openSaved', {'id': id});

  @override
  Future<PermissionState> requestPhotoAccess() async {
    final state = await _call<String>('requestPhotoAccess');
    return PermissionState.fromWire(state);
  }

  @override
  Future<bool> requestNotifications() => _call<bool>('requestNotifications');

  Future<DownloadJob> _callJob(String method, [Object? args]) async {
    final raw = await _callMap(method, args);
    final job = DownloadJob.tryFromMap(raw);
    if (job == null) {
      throw const NativeFailure(
        'protocol',
        'The download service sent no job.',
      );
    }
    return job;
  }

  Future<Map<Object?, Object?>> _callMap(String method, [Object? args]) async {
    final raw = await _raw(method, args);
    if (raw is! Map) {
      throw NativeFailure('protocol', 'Unexpected reply to "$method".');
    }
    return raw.cast<Object?, Object?>();
  }

  Future<T> _call<T>(String method, [Object? args]) async {
    final result = await _raw(method, args);
    if (result is T) return result;
    throw NativeFailure('protocol', 'Unexpected reply to "$method".');
  }

  Future<void> _callVoid(String method, [Object? args]) async {
    await _raw(method, args);
  }

  Future<Object?> _raw(String method, [Object? args]) async {
    try {
      return await _method.invokeMethod<Object?>(method, args);
    } on MissingPluginException {
      throw const NativeFailure(
        'unavailable',
        'Saving to Photos is only available on Android and iOS.',
      );
    } on PlatformException catch (error) {
      throw NativeFailure(
        error.code,
        error.message ?? 'The download could not be started.',
      );
    }
  }
}
