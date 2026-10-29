import 'package:flutter/material.dart';

import '../../core/download_job.dart';
import '../format.dart';

class JobCard extends StatelessWidget {
  const JobCard({
    super.key,
    required this.job,
    required this.canOpenSaved,
    this.onRetry,
    this.onCancel,
    this.onOpen,
    this.onRemove,
  });

  final DownloadJob job;
  final bool canOpenSaved;
  final VoidCallback? onRetry;
  final VoidCallback? onCancel;
  final VoidCallback? onOpen;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Card(
      child: InkWell(
        onTap: job.isSavable && canOpenSaved ? onOpen : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 8, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _KindBadge(kind: job.kind, status: job.status),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            job.fileName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            _subtitle(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  _StatusChip(
                    label: statusLabel(job.status.wire),
                    status: job.status,
                  ),
                  _Menu(
                    job: job,
                    canOpenSaved: canOpenSaved,
                    onRetry: onRetry,
                    onCancel: onCancel,
                    onOpen: onOpen,
                    onRemove: job.status == JobStatus.saving ? null : onRemove,
                  ),
                ],
              ),
              if (job.isActive) ...[
                const SizedBox(height: 12),
                _Progress(job: job),
              ],
              if (job.status == JobStatus.failed && job.error != null) ...[
                const SizedBox(height: 8),
                Text(
                  job.error!,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.error,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _subtitle() {
    final parts = <String>[];
    switch (job.status) {
      case JobStatus.completed:
        if (job.totalBytes > 0) parts.add(formatBytes(job.totalBytes));
        parts.add(formatRelative(job.updatedAt));
      case JobStatus.failed:
      case JobStatus.canceled:
        parts.add(formatRelative(job.updatedAt));
      case JobStatus.preparing:
      case JobStatus.saving:
        parts.add(formatBytes(job.bytesReceived));
      case JobStatus.downloading:
      case JobStatus.queued:
        if (job.totalBytes > 0) {
          parts.add(
            '${formatBytes(job.bytesReceived)} of '
            '${formatBytes(job.totalBytes)}',
          );
        } else if (job.bytesReceived > 0) {
          parts.add(formatBytes(job.bytesReceived));
        }
        parts.add('from ${job.host}');
    }
    return parts.join(' · ');
  }
}

class _KindBadge extends StatelessWidget {
  const _KindBadge({required this.kind, required this.status});

  final MediaKind kind;
  final JobStatus status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final failed = status == JobStatus.failed;
    final icon = switch (kind) {
      MediaKind.video => Icons.movie_creation_outlined,
      MediaKind.image => Icons.image_outlined,
      MediaKind.unknown => Icons.insert_drive_file_outlined,
    };
    final background = failed
        ? scheme.errorContainer
        : (kind == MediaKind.image
              ? scheme.tertiaryContainer
              : scheme.primaryContainer);

    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Icon(
        icon,
        size: 22,
        color: failed ? scheme.onErrorContainer : scheme.onPrimaryContainer,
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.label, required this.status});

  final String label;
  final JobStatus status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (foreground, background) = switch (status) {
      JobStatus.completed => (
        scheme.onSecondaryContainer,
        scheme.secondaryContainer,
      ),
      JobStatus.failed => (scheme.onErrorContainer, scheme.errorContainer),
      JobStatus.canceled => (
        scheme.onSurfaceVariant,
        scheme.surfaceContainerHighest,
      ),
      _ => (scheme.onPrimary, scheme.primary),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: foreground,
          letterSpacing: 0.1,
        ),
      ),
    );
  }
}

class _Progress extends StatelessWidget {
  const _Progress({required this.job});

  final DownloadJob job;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final progress = job.progress;

    return Row(
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(99),
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: progress ?? 0),
              duration: const Duration(milliseconds: 350),
              curve: Curves.easeOutCubic,
              builder: (context, value, _) {
                if (progress == null) {
                  return LinearProgressIndicator(
                    minHeight: 6,
                    backgroundColor: scheme.surfaceContainerHighest,
                  );
                }
                return LinearProgressIndicator(
                  value: value,
                  minHeight: 6,
                  backgroundColor: scheme.surfaceContainerHighest,
                );
              },
            ),
          ),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 40,
          child: Text(
            progress == null ? '' : '${(progress * 100).round()}%',
            textAlign: TextAlign.end,
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

class _Menu extends StatelessWidget {
  const _Menu({
    required this.job,
    required this.canOpenSaved,
    this.onRetry,
    this.onCancel,
    this.onOpen,
    this.onRemove,
  });

  final DownloadJob job;
  final bool canOpenSaved;
  final VoidCallback? onRetry;
  final VoidCallback? onCancel;
  final VoidCallback? onOpen;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final canRetry =
        (job.status == JobStatus.failed || job.status == JobStatus.canceled) &&
        onRetry != null;
    final canCancel =
        job.isActive && job.status != JobStatus.saving && onCancel != null;
    final canOpen = job.isSavable && canOpenSaved && onOpen != null;

    if (!canRetry && !canCancel && !canOpen && onRemove == null) {
      return const SizedBox(width: 4);
    }

    return PopupMenuButton<String>(
      tooltip: 'More actions',
      icon: const Icon(Icons.more_vert_rounded, size: 20),
      padding: EdgeInsets.zero,
      splashRadius: 20,
      onSelected: (value) {
        switch (value) {
          case 'open':
            onOpen?.call();
          case 'retry':
            onRetry?.call();
          case 'cancel':
            onCancel?.call();
          case 'remove':
            onRemove?.call();
        }
      },
      itemBuilder: (context) => [
        if (canOpen) const PopupMenuItem(value: 'open', child: Text('Open')),
        if (canRetry)
          const PopupMenuItem(value: 'retry', child: Text('Try again')),
        if (canCancel)
          const PopupMenuItem(value: 'cancel', child: Text('Cancel')),
        if (onRemove != null)
          const PopupMenuItem(
            value: 'remove',
            child: Text('Remove from history'),
          ),
      ],
    );
  }
}
