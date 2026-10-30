import 'dart:async';

import 'package:flutter/foundation.dart';

import 'download_job.dart';
import 'downloads_api.dart';
import 'link_input.dart';
import 'resolver_settings.dart';

/// Mirrors the native queue and history, and serialises user actions.
///
/// Native state is authoritative: every job the UI shows came from a bridge
/// payload, so a download that finished while the app was closed (or while the
/// Flutter engine was not running) still appears with the right status.
class DownloadController extends ChangeNotifier {
  DownloadController(this._api);

  final DownloadsApi _api;
  final Map<String, DownloadJob> _jobs = {};

  StreamSubscription<DownloadJob>? _subscription;
  bool _initialized = false;
  bool _loading = true;
  bool _disposed = false;
  String? _unavailableReason;

  PermissionState photoAccess = PermissionState.unsupported;
  PermissionState notifications = PermissionState.unsupported;
  bool canOpenSaved = false;
  String platform = '';
  ResolverSettings resolverSettings = const ResolverSettings();

  bool get isLoading => _loading;

  bool get isAvailable => _unavailableReason == null;

  /// Non-null when this platform has no native download service (desktop,
  /// tests without a fake). The UI shows it as a banner.
  String? get unavailableReason => _unavailableReason;

  List<DownloadJob> get jobs => _sorted();

  List<DownloadJob> get activeJobs =>
      _sorted().where((job) => job.isActive).toList(growable: false);

  List<DownloadJob> get finishedJobs =>
      _sorted().where((job) => !job.isActive).toList(growable: false);

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    _subscription = _api.updates.listen(_upsert, onError: (Object _) {});
    try {
      final snapshot = await _api.initialize();
      platform = snapshot.platform;
      photoAccess = snapshot.photoAccess;
      notifications = snapshot.notifications;
      canOpenSaved = snapshot.canOpenSaved;
      resolverSettings = snapshot.resolver;
      _merge(snapshot.jobs);
    } on NativeFailure catch (failure) {
      _unavailableReason = failure.message;
    } catch (error) {
      _unavailableReason = 'Downloads are unavailable: $error';
    } finally {
      _loading = false;
      _notify();
    }
  }

  /// Re-reads native history, e.g. when the app returns to the foreground
  /// after a share-initiated download.
  Future<void> refresh() async {
    if (!isAvailable) return;
    try {
      _merge(await _api.history());
    } on NativeFailure catch (_) {
      // Keep showing the last known state.
    } finally {
      _notify();
    }
  }

  /// Validates [input] and hands the link to the native service.
  ///
  /// Throws [NativeFailure] with a user-facing message when the link is not
  /// usable or the platform rejects it.
  Future<DownloadJob> submit(String input) async {
    final parsed = parseLinkInput(input);
    if (!parsed.isValid) {
      throw NativeFailure('invalid_link', parsed.error!);
    }
    if (!isAvailable) {
      throw NativeFailure(
        'unavailable',
        _unavailableReason ?? 'Saving is not available on this device.',
      );
    }
    final job = await _api.enqueue(parsed.url!, origin: JobOrigin.manual);
    _upsert(job);
    return job;
  }

  Future<void> retry(String id) async {
    final job = await _api.retry(id);
    _upsert(job);
  }

  Future<void> cancel(String id) async {
    await _api.cancel(id);
    // Cancellation can race completion, or be refused once publication starts.
    // Display the native result instead of inventing a local canceled state.
    _merge(await _api.history());
    _notify();
  }

  Future<void> removeEntry(String id) async {
    await _api.remove(id);
    _jobs.remove(id);
    _notify();
  }

  Future<void> clearHistory() async {
    await _api.clearHistory();
    _jobs.removeWhere((_, job) => !job.isActive);
    _notify();
  }

  /// Returns true when a viewer was opened for the saved item.
  Future<bool> openSaved(String id) async {
    if (!canOpenSaved) return false;
    return _api.openSaved(id);
  }

  Future<PermissionState> requestPhotoAccess() async {
    final state = await _api.requestPhotoAccess();
    photoAccess = state;
    _notify();
    return state;
  }

  Future<bool> requestNotifications() async {
    final granted = await _api.requestNotifications();
    notifications = granted ? PermissionState.granted : PermissionState.denied;
    _notify();
    return granted;
  }

  Future<void> updateResolverSettings(ResolverSettings settings) async {
    await _api.setResolverSettings(settings);
    resolverSettings = settings;
    _notify();
  }

  void _merge(List<DownloadJob> incoming) {
    for (final job in incoming) {
      _jobs[job.id] = job;
    }
  }

  void _upsert(DownloadJob job) {
    // A delayed native progress event must not resurrect a completed job.
    final existing = _jobs[job.id];
    if (existing != null && existing.updatedAt.isAfter(job.updatedAt)) {
      return;
    }
    _jobs[job.id] = job;
    _notify();
  }

  List<DownloadJob> _sorted() {
    final list = _jobs.values.toList(growable: false);
    list.sort((a, b) {
      if (a.isActive != b.isActive) return a.isActive ? -1 : 1;
      return b.createdAt.compareTo(a.createdAt);
    });
    return list;
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _subscription?.cancel();
    super.dispose();
  }
}
