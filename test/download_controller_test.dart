import 'package:flutter_test/flutter_test.dart';
import 'package:maidl/src/core/download_controller.dart';
import 'package:maidl/src/core/download_job.dart';
import 'package:maidl/src/core/downloads_api.dart';

import 'support/fake_downloads_api.dart';

DownloadJob _job(
  String id, {
  JobStatus status = JobStatus.queued,
  int created = 0,
  int updated = 0,
  String? error,
  String? remoteId,
  String url = 'https://x.dev/a.mp4',
}) {
  return DownloadJob(
    id: id,
    url: url,
    kind: MediaKind.video,
    fileName: '$id.mp4',
    status: status,
    origin: JobOrigin.share,
    createdAt: DateTime.fromMillisecondsSinceEpoch(1000 + created),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(1000 + updated),
    totalBytes: 1000,
    error: error,
    remoteId: remoteId,
  );
}

void main() {
  test('initialize mirrors native history with active jobs first', () async {
    final api = FakeDownloadsApi(
      jobs: [
        _job('saved', status: JobStatus.completed, created: 5),
        _job('older', status: JobStatus.completed, created: 1),
        _job('active', status: JobStatus.downloading, created: 2),
      ],
    );
    final controller = DownloadController(api);

    await controller.initialize();

    expect(controller.isLoading, isFalse);
    expect(controller.isAvailable, isTrue);
    expect(controller.jobs.map((job) => job.id), ['active', 'saved', 'older']);
    expect(controller.activeJobs.single.id, 'active');
    expect(controller.finishedJobs.map((job) => job.id), ['saved', 'older']);
    controller.dispose();
    await api.close();
  });

  test('submit extracts the URL from prose and marks it manual', () async {
    final api = FakeDownloadsApi();
    final controller = DownloadController(api);
    await controller.initialize();

    final job = await controller.submit(
      'try this https://cdn.example.com/v/clip.mp4?x=1 thanks',
    );

    expect(api.enqueuedUrls, ['https://cdn.example.com/v/clip.mp4?x=1']);
    expect(api.enqueuedOrigins, [JobOrigin.manual]);
    expect(job.status, JobStatus.downloading);
    expect(controller.activeJobs, hasLength(1));
    controller.dispose();
    await api.close();
  });

  test('submit rejects bad input without touching the native layer', () async {
    final api = FakeDownloadsApi();
    final controller = DownloadController(api);
    await controller.initialize();

    await expectLater(
      () => controller.submit('definitely not a link'),
      throwsA(
        isA<NativeFailure>()
            .having((failure) => failure.code, 'code', 'invalid_link')
            .having((failure) => failure.message, 'message', contains('http')),
      ),
    );
    expect(api.enqueuedUrls, isEmpty);
    controller.dispose();
    await api.close();
  });

  test('surfaces native rejection verbatim', () async {
    final api = FakeDownloadsApi()
      ..enqueueFailure = const NativeFailure(
        'unsupported_link',
        'That page has no direct video or image.',
      );
    final controller = DownloadController(api);
    await controller.initialize();

    await expectLater(
      () => controller.submit('https://site.example/watch/1'),
      throwsA(
        isA<NativeFailure>().having(
          (failure) => failure.message,
          'message',
          'That page has no direct video or image.',
        ),
      ),
    );
    expect(controller.jobs, isEmpty);
    controller.dispose();
    await api.close();
  });

  test('reports an unavailable platform and blocks submit', () async {
    final api = FakeDownloadsApi()
      ..initializeFailure = const NativeFailure(
        'unavailable',
        'Saving to Photos is only available on Android and iOS.',
      );
    final controller = DownloadController(api);
    await controller.initialize();

    expect(controller.isAvailable, isFalse);
    expect(controller.unavailableReason, contains('Android and iOS'));
    await expectLater(
      () => controller.submit('https://x.dev/a.png'),
      throwsA(
        isA<NativeFailure>().having(
          (failure) => failure.isUnavailable,
          'unavailable',
          isTrue,
        ),
      ),
    );
    controller.dispose();
    await api.close();
  });

  test('native events update the mirrored job and notify listeners', () async {
    final api = FakeDownloadsApi(
      jobs: [_job('a', status: JobStatus.downloading)],
    );
    final controller = DownloadController(api);
    await controller.initialize();
    var notifications = 0;
    controller.addListener(() => notifications++);

    api.emit(
      _job(
        'a',
        status: JobStatus.completed,
        updated: 10,
        remoteId: 'content://media/1',
      ),
    );

    await Future<void>.delayed(Duration.zero);
    final job = controller.jobs.single;
    expect(job.status, JobStatus.completed);
    expect(job.remoteId, 'content://media/1');
    expect(notifications, greaterThan(0));
    controller.dispose();
    await api.close();
  });

  test('a stale event cannot regress a finished job', () async {
    final api = FakeDownloadsApi(
      jobs: [
        _job(
          'a',
          status: JobStatus.completed,
          updated: 50,
          remoteId: 'saved-id',
        ),
      ],
    );
    final controller = DownloadController(api);
    await controller.initialize();

    api.emit(_job('a', status: JobStatus.completed, updated: 10));
    await Future<void>.delayed(Duration.zero);

    expect(controller.jobs.single.remoteId, 'saved-id');
    controller.dispose();
    await api.close();
  });

  test('stale progress cannot resurrect a finished download', () async {
    final api = FakeDownloadsApi(
      jobs: [
        _job(
          'a',
          status: JobStatus.completed,
          updated: 50,
          remoteId: 'saved-id',
        ),
      ],
    );
    final controller = DownloadController(api);
    await controller.initialize();

    api.emit(_job('a', status: JobStatus.downloading, updated: 10));
    await Future<void>.delayed(Duration.zero);

    expect(controller.jobs.single.status, JobStatus.completed);
    expect(controller.jobs.single.remoteId, 'saved-id');
    controller.dispose();
    await api.close();
  });

  test('refresh preserves native viewer capability on iOS', () async {
    final api = FakeDownloadsApi(
      platform: 'ios',
      canOpenSaved: false,
      jobs: [_job('a', status: JobStatus.completed)],
    );
    final controller = DownloadController(api);
    await controller.initialize();
    await controller.refresh();

    expect(controller.canOpenSaved, isFalse);
    controller.dispose();
    await api.close();
  });

  test('cancel does not relabel a native completed save', () async {
    final api = FakeDownloadsApi(
      jobs: [
        _job('a', status: JobStatus.completed, updated: 50, remoteId: 'asset'),
      ],
    );
    final controller = DownloadController(api);
    await controller.initialize();

    await controller.cancel('a');

    expect(controller.jobs.single.status, JobStatus.completed);
    expect(controller.jobs.single.remoteId, 'asset');
    controller.dispose();
    await api.close();
  });

  test(
    'cancel marks the job canceled and remove drops it from history',
    () async {
      final api = FakeDownloadsApi(
        jobs: [_job('a', status: JobStatus.downloading)],
      );
      final controller = DownloadController(api);
      await controller.initialize();

      await controller.cancel('a');
      expect(api.cancelCalls, 1);
      expect(controller.jobs.single.status, JobStatus.canceled);

      await controller.removeEntry('a');
      expect(api.removeCalls, 1);
      expect(controller.jobs, isEmpty);
      controller.dispose();
      await api.close();
    },
  );

  test('clearHistory keeps active downloads', () async {
    final api = FakeDownloadsApi(
      jobs: [
        _job('active', status: JobStatus.downloading, created: 3),
        _job('done', status: JobStatus.completed, created: 2),
      ],
    );
    final controller = DownloadController(api);
    await controller.initialize();

    await controller.clearHistory();

    expect(api.clearCalls, 1);
    expect(controller.jobs.map((job) => job.id), ['active']);
    controller.dispose();
    await api.close();
  });

  test(
    'refresh picks up downloads finished while the app was closed',
    () async {
      final api = FakeDownloadsApi(
        jobs: [_job('a', status: JobStatus.downloading)],
      );
      final controller = DownloadController(api);
      await controller.initialize();

      api.historyJobs
        ..clear()
        ..add(
          _job('a', status: JobStatus.completed, updated: 99, remoteId: 'uri'),
        );
      await controller.refresh();

      expect(controller.finishedJobs.single.remoteId, 'uri');
      controller.dispose();
      await api.close();
    },
  );
}
