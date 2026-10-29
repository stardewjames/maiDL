import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maidl/app.dart';
import 'package:maidl/src/core/download_controller.dart';
import 'package:maidl/src/core/download_job.dart';
import 'package:maidl/src/core/downloads_api.dart';

import 'support/fake_downloads_api.dart';

DownloadJob _job(
  String id, {
  JobStatus status = JobStatus.completed,
  int total = 2048,
  String? error,
}) {
  return DownloadJob(
    id: id,
    url: 'https://cdn.example.com/$id.mp4',
    kind: MediaKind.video,
    fileName: '$id.mp4',
    status: status,
    origin: JobOrigin.share,
    createdAt: DateTime.now().subtract(const Duration(minutes: 3)),
    updatedAt: DateTime.now().subtract(const Duration(minutes: 2)),
    bytesReceived: total,
    totalBytes: total,
    error: error,
  );
}

Future<DownloadController> _pumpApp(
  WidgetTester tester,
  FakeDownloadsApi api,
) async {
  final controller = DownloadController(api);
  await tester.pumpWidget(MaidlApp(controller: controller));
  await tester.pumpAndSettle();
  return controller;
}

void main() {
  testWidgets('shows the empty state before anything is saved', (tester) async {
    final api = FakeDownloadsApi();
    await _pumpApp(tester, api);

    expect(find.text('maiDL'), findsOneWidget);
    expect(find.text('Save a link'), findsOneWidget);
    expect(find.text('Nothing saved yet'), findsOneWidget);

    await api.close();
  });

  testWidgets('lists saved downloads with their status', (tester) async {
    final api = FakeDownloadsApi(jobs: [_job('clip')]);
    await _pumpApp(tester, api);

    expect(find.text('clip.mp4'), findsOneWidget);
    expect(find.text('Saved'), findsOneWidget);
    expect(find.text('Recent'), findsOneWidget);
    expect(find.text('Nothing saved yet'), findsNothing);

    await api.close();
  });

  testWidgets('submitting a link starts a download and shows progress', (
    tester,
  ) async {
    final api = FakeDownloadsApi()
      ..enqueueResult = _job('new', status: JobStatus.downloading, total: 4000);
    await _pumpApp(tester, api);

    await tester.enterText(
      find.byType(TextField),
      'https://cdn.example.com/new.mp4',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(api.enqueuedUrls, ['https://cdn.example.com/new.mp4']);
    expect(find.text('In progress'), findsOneWidget);
    expect(find.text('Downloading'), findsOneWidget);
    expect(find.text('new.mp4'), findsOneWidget);

    await api.close();
  });

  testWidgets('invalid input shows an inline error', (tester) async {
    final api = FakeDownloadsApi();
    await _pumpApp(tester, api);

    await tester.enterText(find.byType(TextField), 'nope');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(find.textContaining('http'), findsWidgets);
    expect(api.enqueuedUrls, isEmpty);

    await api.close();
  });

  testWidgets('asks for Photos access on iOS when it is missing', (
    tester,
  ) async {
    final api = FakeDownloadsApi(
      platform: 'ios',
      photoAccess: PermissionState.notDetermined,
      canOpenSaved: false,
    );
    await _pumpApp(tester, api);

    expect(find.text('Allow Photos access'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Allow'));
    await tester.pumpAndSettle();

    expect(api.photoAccess, PermissionState.granted);
    expect(find.text('Allow Photos access'), findsNothing);

    await api.close();
  });

  testWidgets('video preparation stays cancelable until the Photos commit', (
    tester,
  ) async {
    final api = FakeDownloadsApi(
      platform: 'ios',
      photoAccess: PermissionState.granted,
      jobs: [_job('convert', status: JobStatus.preparing)],
      canOpenSaved: false,
    );
    final controller = DownloadController(api);
    await tester.pumpWidget(MaidlApp(controller: controller));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    final indicator = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(indicator.value, isNull);
    expect(controller.activeJobs.single.status, JobStatus.preparing);

    await tester.tap(find.byTooltip('More actions'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(controller.jobs.single.status, JobStatus.canceled);

    api.emit(_job('commit', status: JobStatus.saving));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    // Already-submitted Photos changes cannot be withdrawn.
    expect(find.byTooltip('More actions'), findsOneWidget);
    // The only remaining menu belongs to the canceled download, not the commit.
    final committingCard = find.ancestor(
      of: find.text('commit.mp4'),
      matching: find.byType(Card),
    );
    expect(
      find.descendant(
        of: committingCard,
        matching: find.byTooltip('More actions'),
      ),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await api.close();
  });

  testWidgets('fits a small phone without layout overflows', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final api = FakeDownloadsApi(
      jobs: [
        _job('active', status: JobStatus.downloading, total: 1000000),
        _job('done'),
      ],
      platform: 'android',
    );
    await _pumpApp(tester, api);

    expect(tester.takeException(), isNull);
    expect(find.text('Downloading'), findsOneWidget);

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await api.close();
  });

  testWidgets('opens settings with history and permission sections', (
    tester,
  ) async {
    final api = FakeDownloadsApi(platform: 'ios');
    await _pumpApp(tester, api);

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();

    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Your Photos library'), findsOneWidget);
    expect(find.text('Clear history'), findsOneWidget);

    await api.close();
  });
}
