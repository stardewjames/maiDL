import 'package:flutter/material.dart';

import '../core/download_controller.dart';
import '../core/download_job.dart';
import '../core/downloads_api.dart';
import 'settings_page.dart';
import 'widgets/job_card.dart';
import 'widgets/link_composer.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key, required this.controller});

  final DownloadController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(
            title: const Text('maiDL'),
            actions: [
              IconButton(
                tooltip: 'Settings',
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => SettingsPage(controller: controller),
                  ),
                ),
                icon: const Icon(Icons.tune_rounded),
              ),
              const SizedBox(width: 8),
            ],
          ),
          body: controller.isLoading
              ? const Center(child: CircularProgressIndicator())
              : _body(context),
        );
      },
    );
  }

  Widget _body(BuildContext context) {
    final theme = Theme.of(context);
    final active = controller.activeJobs;
    final finished = controller.finishedJobs;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 36),
      children: [
        if (!controller.isAvailable) ...[
          _NoticeCard(
            icon: Icons.phonelink_erase_rounded,
            tone: _NoticeTone.warning,
            title: 'Downloads are not available here',
            message:
                controller.unavailableReason ??
                'Use the Android or iOS app to save videos and images.',
          ),
          const SizedBox(height: 12),
        ],
        if (_needsPhotoAccess) ...[
          _NoticeCard(
            icon: Icons.photo_library_outlined,
            tone: _NoticeTone.primary,
            title: 'Allow Photos access',
            message:
                'maiDL needs add-only access so downloads can appear in '
                'your library without a prompt each time.',
            actionLabel: 'Allow',
            onAction: () => _requestPhotoAccess(context),
          ),
          const SizedBox(height: 12),
        ],
        if (controller.platform == 'android' &&
            controller.notifications == PermissionState.denied) ...[
          _NoticeCard(
            icon: Icons.notifications_off_outlined,
            tone: _NoticeTone.neutral,
            title: 'Notifications are off',
            message:
                'Downloads still run in the background; progress just '
                'will not be shown.',
            actionLabel: 'Turn on',
            onAction: () async {
              final granted = await controller.requestNotifications();
              if (!context.mounted) return;
              _snack(
                context,
                granted
                    ? 'Download notifications enabled.'
                    : 'Enable notifications in system settings.',
              );
            },
          ),
          const SizedBox(height: 12),
        ],
        LinkComposer(onSave: (input) => _save(context, input)),
        if (active.isNotEmpty) ...[
          const SizedBox(height: 26),
          _SectionHeader(title: 'In progress', trailing: '${active.length}'),
          const SizedBox(height: 10),
          for (final job in active) ...[
            _cardFor(context, job),
            const SizedBox(height: 10),
          ],
        ],
        const SizedBox(height: 26),
        _SectionHeader(
          title: 'Recent',
          trailing: finished.isEmpty
              ? null
              : (finished.length > 99 ? '99+' : '${finished.length}'),
          action: finished.isEmpty
              ? null
              : TextButton(
                  onPressed: () => _confirmClear(context),
                  child: const Text('Clear'),
                ),
        ),
        const SizedBox(height: 10),
        if (finished.isEmpty)
          _EmptyState(hasActive: active.isNotEmpty)
        else
          for (final job in finished) ...[
            _cardFor(context, job),
            const SizedBox(height: 10),
          ],
        const SizedBox(height: 8),
        Text(
          'Tip: share a link to maiDL from any app to save it without '
          'opening maiDL.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  bool get _needsPhotoAccess =>
      controller.platform == 'ios' &&
      controller.photoAccess != PermissionState.granted &&
      controller.photoAccess != PermissionState.unsupported;

  Widget _cardFor(BuildContext context, DownloadJob job) {
    return JobCard(
      job: job,
      canOpenSaved: controller.canOpenSaved,
      onRetry: () => _run(context, () => controller.retry(job.id)),
      onCancel: () => _run(context, () => controller.cancel(job.id)),
      onOpen: () => _run(context, () async {
        final opened = await controller.openSaved(job.id);
        if (!opened && context.mounted) {
          _snack(context, 'No app can open this file.');
        }
      }),
      onRemove: () => _run(
        context,
        () => controller.removeEntry(job.id),
        success: 'Removed from history. The file stays in your library.',
      ),
    );
  }

  Future<void> _save(BuildContext context, String input) async {
    final job = await controller.submit(input);
    if (!context.mounted) return;
    _snack(
      context,
      job.status == JobStatus.completed
          ? 'Saved to your library.'
          : 'Saving in the background — you can leave maiDL.',
    );
  }

  Future<void> _requestPhotoAccess(BuildContext context) async {
    final state = await controller.requestPhotoAccess();
    if (!context.mounted) return;
    _snack(
      context,
      state == PermissionState.granted
          ? 'Photos access granted.'
          : 'Enable Photos access in Settings → maiDL → Photos.',
    );
  }

  Future<void> _confirmClear(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Clear history?'),
        content: const Text(
          'Downloaded videos and photos stay in your library. Only this list '
          'is cleared.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      await _run(context, controller.clearHistory);
    }
  }

  Future<void> _run(
    BuildContext context,
    Future<void> Function() action, {
    String? success,
  }) async {
    try {
      await action();
      if (success != null && context.mounted) _snack(context, success);
    } on NativeFailure catch (failure) {
      if (context.mounted) _snack(context, failure.message);
    }
  }

  void _snack(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.trailing, this.action});

  final String title;
  final String? trailing;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Text(
          title,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: 0.2,
          ),
        ),
        if (trailing != null) ...[
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: theme.colorScheme.secondaryContainer,
              borderRadius: BorderRadius.circular(99),
            ),
            child: Text(
              trailing!,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSecondaryContainer,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
        const Spacer(),
        ?action,
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.hasActive});

  final bool hasActive;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 32),
        child: Column(
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                shape: BoxShape.circle,
              ),
              child: Icon(
                hasActive
                    ? Icons.hourglass_empty_rounded
                    : Icons.photo_library_outlined,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              hasActive ? 'Nothing finished yet' : 'Nothing saved yet',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              hasActive
                  ? 'Finished downloads appear here.'
                  : 'Paste a link above, or use the share sheet from any app.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum _NoticeTone { primary, warning, neutral }

class _NoticeCard extends StatelessWidget {
  const _NoticeCard({
    required this.icon,
    required this.tone,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final _NoticeTone tone;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (background, foreground) = switch (tone) {
      _NoticeTone.primary => (
        scheme.primaryContainer,
        scheme.onPrimaryContainer,
      ),
      _NoticeTone.warning => (scheme.errorContainer, scheme.onErrorContainer),
      _NoticeTone.neutral => (
        scheme.surfaceContainerHighest,
        scheme.onSurfaceVariant,
      ),
    };

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 20, color: foreground),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: foreground,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            message,
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: foreground),
          ),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 10),
            FilledButton.tonal(
              onPressed: onAction,
              style: FilledButton.styleFrom(
                backgroundColor: foreground,
                foregroundColor: background,
                minimumSize: const Size(0, 40),
              ),
              child: Text(actionLabel!),
            ),
          ],
        ],
      ),
    );
  }
}
