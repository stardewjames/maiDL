import 'dart:async';

import 'package:maidl/src/core/download_job.dart';
import 'package:maidl/src/core/downloads_api.dart';

/// Records calls and lets tests drive native events.
class FakeDownloadsApi implements DownloadsApi {
  FakeDownloadsApi({
    this.platform = 'android',
    List<DownloadJob> jobs = const [],
    this.photoAccess = PermissionState.unsupported,
    this.notifications = PermissionState.granted,
    this.canOpenSaved = true,
  }) : historyJobs = List.of(jobs);

  final String platform;
  final List<DownloadJob> historyJobs;
  PermissionState photoAccess;
  PermissionState notifications;
  bool canOpenSaved;

  NativeFailure? initializeFailure;
  NativeFailure? enqueueFailure;
  bool photosGrantedOnRequest = true;
  bool notificationsGrantedOnRequest = true;

  final List<String> enqueuedUrls = [];
  final List<JobOrigin> enqueuedOrigins = [];
  int retryCalls = 0;
  int cancelCalls = 0;
  int removeCalls = 0;
  int clearCalls = 0;
  int openCalls = 0;
  DownloadJob? enqueueResult;

  final StreamController<DownloadJob> _events =
      StreamController<DownloadJob>.broadcast();

  @override
  Stream<DownloadJob> get updates => _events.stream;

  void emit(DownloadJob job) => _events.add(job);

  @override
  Future<NativeSnapshot> initialize() async {
    final failure = initializeFailure;
    if (failure != null) throw failure;
    return NativeSnapshot(
      jobs: List.of(historyJobs),
      platform: platform,
      photoAccess: photoAccess,
      notifications: notifications,
      canOpenSaved: canOpenSaved,
    );
  }

  @override
  Future<List<DownloadJob>> history() async => List.of(historyJobs);

  @override
  Future<DownloadJob> enqueue(String url, {required JobOrigin origin}) async {
    final failure = enqueueFailure;
    if (failure != null) throw failure;
    enqueuedUrls.add(url);
    enqueuedOrigins.add(origin);
    final job =
        enqueueResult ??
        DownloadJob(
          id: 'job-${enqueuedUrls.length}',
          url: url,
          kind: MediaKind.unknown,
          fileName: 'clip',
          status: JobStatus.downloading,
          origin: origin,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );
    historyJobs.insert(0, job);
    return job;
  }

  @override
  Future<DownloadJob> retry(String id) async {
    retryCalls++;
    final job = historyJobs.firstWhere((entry) => entry.id == id);
    final updated = job.copyWith(
      status: JobStatus.queued,
      clearError: true,
      updatedAt: DateTime.now(),
    );
    historyJobs
      ..removeWhere((entry) => entry.id == id)
      ..insert(0, updated);
    return updated;
  }

  @override
  Future<void> cancel(String id) async {
    cancelCalls++;
    final index = historyJobs.indexWhere((job) => job.id == id);
    if (index >= 0 &&
        historyJobs[index].isActive &&
        historyJobs[index].status != JobStatus.saving) {
      historyJobs[index] = historyJobs[index].copyWith(
        status: JobStatus.canceled,
        updatedAt: DateTime.now(),
      );
    }
  }

  @override
  Future<void> remove(String id) async {
    removeCalls++;
    historyJobs.removeWhere((entry) => entry.id == id);
  }

  @override
  Future<void> clearHistory() async {
    clearCalls++;
    historyJobs.removeWhere((job) => !job.isActive);
  }

  @override
  Future<bool> openSaved(String id) async {
    openCalls++;
    return true;
  }

  @override
  Future<PermissionState> requestPhotoAccess() async {
    photoAccess = photosGrantedOnRequest
        ? PermissionState.granted
        : PermissionState.denied;
    return photoAccess;
  }

  @override
  Future<bool> requestNotifications() async {
    notifications = notificationsGrantedOnRequest
        ? PermissionState.granted
        : PermissionState.denied;
    return notificationsGrantedOnRequest;
  }

  Future<void> close() => _events.close();
}
