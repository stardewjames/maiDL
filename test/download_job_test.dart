import 'package:flutter_test/flutter_test.dart';
import 'package:maidl/src/core/download_job.dart';
import 'package:maidl/src/ui/format.dart';

void main() {
  group('DownloadJob.tryFromMap', () {
    test('parses a full native payload', () {
      final job = DownloadJob.tryFromMap({
        'id': 'abc',
        'url': 'https://x.dev/a.mp4',
        'kind': 'video',
        'fileName': 'a.mp4',
        'status': 'downloading',
        'origin': 'share',
        'createdAt': 1700000000000,
        'updatedAt': 1700000005000,
        'bytesReceived': 512,
        'totalBytes': 1024,
        'error': null,
        'remoteId': null,
      });

      expect(job, isNotNull);
      expect(job!.kind, MediaKind.video);
      expect(job.status, JobStatus.downloading);
      expect(job.origin, JobOrigin.share);
      expect(job.progress, 0.5);
      expect(job.isActive, isTrue);
      expect(job.host, 'x.dev');
    });

    test('tolerates missing optional fields and numeric strings', () {
      final job = DownloadJob.tryFromMap({
        'id': 'abc',
        'url': 'https://x.dev/a.png',
        'bytesReceived': '12',
      });

      expect(job, isNotNull);
      expect(job!.bytesReceived, 12);
      expect(job.totalBytes, -1);
      expect(job.status, JobStatus.queued);
      expect(job.fileName, 'a.png');
      expect(job.progress, isNull);
    });

    test('rejects payloads without identity', () {
      expect(DownloadJob.tryFromMap({'url': 'https://x.dev/a.png'}), isNull);
      expect(DownloadJob.tryFromMap({'id': 'abc'}), isNull);
    });

    test('ignores junk entries when parsing history', () {
      final jobs = DownloadJob.listFromWire([
        {'id': '1', 'url': 'https://x.dev/1.mp4', 'status': 'completed'},
        'nope',
        {'id': '', 'url': ''},
      ]);
      expect(jobs, hasLength(1));
      expect(jobs.single.status, JobStatus.completed);
    });

    test('clamps progress to 0..1', () {
      final job = DownloadJob(
        id: 'a',
        url: 'https://x.dev/a.mp4',
        kind: MediaKind.video,
        fileName: 'a.mp4',
        status: JobStatus.downloading,
        origin: JobOrigin.manual,
        createdAt: DateTime(2024),
        updatedAt: DateTime(2024),
        bytesReceived: 2000,
        totalBytes: 1000,
      );
      expect(job.progress, 1.0);
    });

    test(
      'fully downloaded video is still active while preparing for Photos',
      () {
        final job = DownloadJob.tryFromMap({
          'id': 'video',
          'url': 'https://x.dev/clip.mov',
          'kind': 'video',
          'status': 'preparing',
          'bytesReceived': 1024,
          'totalBytes': 1024,
        })!;

        expect(job.status, JobStatus.preparing);
        expect(job.isActive, isTrue);
        expect(job.isSavable, isFalse);
        expect(job.progress, isNull);
      },
    );
  });

  group('formatBytes', () {
    test('uses readable units and boundaries', () {
      expect(formatBytes(-1), 'Unknown size');
      expect(formatBytes(1023), '1023 B');
      expect(formatBytes(1024), '1.0 KB');
      expect(formatBytes(1024 * 1024), '1.0 MB');
      expect(formatBytes(1024 * 1024 * 1024 * 3 ~/ 2), '1.5 GB');
    });
  });

  group('formatRelative', () {
    final now = DateTime(2024, 5, 20, 12);
    test('labels recent and older timestamps', () {
      expect(
        formatRelative(now.subtract(const Duration(seconds: 5)), now: now),
        'Just now',
      );
      expect(
        formatRelative(now.subtract(const Duration(minutes: 7)), now: now),
        '7 min ago',
      );
      expect(
        formatRelative(now.subtract(const Duration(hours: 5)), now: now),
        '5 h ago',
      );
      expect(
        formatRelative(now.subtract(const Duration(days: 1)), now: now),
        'Yesterday',
      );
    });
  });
}
