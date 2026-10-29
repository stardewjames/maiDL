import 'package:flutter/material.dart';

import '../core/download_controller.dart';
import '../core/downloads_api.dart';

const String appVersion = '1.0.0';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.controller});

  final DownloadController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final isIos = controller.platform == 'ios';
        final isAndroid = controller.platform == 'android';
        final theme = Theme.of(context);

        return Scaffold(
          appBar: AppBar(title: const Text('Settings')),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
            children: [
              _SectionLabel('Permissions'),
              Card(
                child: Column(
                  children: [
                    if (isIos)
                      _PermissionTile(
                        icon: Icons.photo_library_outlined,
                        title: 'Photos',
                        subtitle: 'Add-only access for saving downloads',
                        state: controller.photoAccess,
                        onRequest: () async {
                          final state = await controller.requestPhotoAccess();
                          if (!context.mounted) return;
                          _snack(
                            context,
                            state == PermissionState.granted
                                ? 'Photos access granted.'
                                : 'Change this in Settings → maiDL → Photos.',
                          );
                        },
                      ),
                    if (isAndroid)
                      _PermissionTile(
                        icon: Icons.notifications_outlined,
                        title: 'Download notifications',
                        subtitle: 'Progress and completion alerts',
                        state: controller.notifications,
                        onRequest: () async {
                          final granted = await controller
                              .requestNotifications();
                          if (!context.mounted) return;
                          _snack(
                            context,
                            granted
                                ? 'Notifications enabled.'
                                : 'Change this in system settings → Apps → '
                                      'maiDL → Notifications.',
                          );
                        },
                      ),
                    if (!isIos && !isAndroid)
                      const ListTile(
                        leading: Icon(Icons.info_outline_rounded),
                        title: Text('No platform permissions required'),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 22),
              _SectionLabel('Where files go'),
              Card(
                child: ListTile(
                  leading: Icon(
                    Icons.folder_outlined,
                    color: theme.colorScheme.primary,
                  ),
                  title: Text(
                    isIos
                        ? 'Your Photos library'
                        : 'Pictures/maiDL and Movies/maiDL',
                  ),
                  subtitle: Text(
                    isIos
                        ? 'Downloads are added to the Photos app automatically.'
                        : 'Downloads appear in your gallery and Google Photos.',
                  ),
                ),
              ),
              const SizedBox(height: 22),
              _SectionLabel('Supported links'),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _SupportLine(
                        icon: Icons.check_circle_outline_rounded,
                        text: isIos
                            ? 'Videos are prepared as MP4 with H.264 video and '
                                  'AAC audio when present. Damaged or unsupported '
                                  'inputs are rejected.'
                            : 'Direct video and image links. Importing a file '
                                  'depends on the formats your gallery app supports.',
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(height: 10),
                      _SupportLine(
                        icon: Icons.check_circle_outline_rounded,
                        text:
                            'Public pages with direct media metadata. A page '
                            'may expose only its preview image, not the full video.',
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(height: 10),
                      _SupportLine(
                        icon: Icons.remove_circle_outline_rounded,
                        text:
                            'Streaming services, DRM-protected content, and '
                            'private or login-only pages are not supported.',
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 22),
              _SectionLabel('History'),
              Card(
                child: ListTile(
                  leading: Icon(
                    Icons.delete_sweep_outlined,
                    color: theme.colorScheme.error,
                  ),
                  title: const Text('Clear history'),
                  subtitle: const Text('Keeps the downloaded files'),
                  onTap: () => _confirmClear(context),
                ),
              ),
              const SizedBox(height: 28),
              Center(
                child: Text(
                  'maiDL $appVersion',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _confirmClear(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Clear history?'),
        content: const Text(
          'Downloaded videos and photos stay in your library. Only the list in '
          'maiDL is cleared.',
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
    if (confirmed != true) return;
    try {
      await controller.clearHistory();
      if (!context.mounted) return;
      _snack(context, 'History cleared.');
    } on NativeFailure catch (failure) {
      if (!context.mounted) return;
      _snack(context, failure.message);
    }
  }

  void _snack(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
      child: Text(
        text.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          letterSpacing: 0.9,
          fontWeight: FontWeight.w700,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _PermissionTile extends StatelessWidget {
  const _PermissionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.state,
    required this.onRequest,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final PermissionState state;
  final VoidCallback onRequest;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final granted = state.isGranted;
    return ListTile(
      leading: Icon(icon, color: scheme.primary),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: granted
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.check_circle_rounded,
                  size: 18,
                  color: scheme.primary,
                ),
                const SizedBox(width: 6),
                Text('Allowed', style: TextStyle(color: scheme.primary)),
              ],
            )
          : TextButton(onPressed: onRequest, child: Text(_label())),
    );
  }

  String _label() => switch (state) {
    PermissionState.granted => 'Allowed',
    PermissionState.denied => 'Fix',
    PermissionState.notDetermined => 'Allow',
    PermissionState.unsupported => '—',
  };
}

class _SupportLine extends StatelessWidget {
  const _SupportLine({
    required this.icon,
    required this.text,
    required this.color,
  });

  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(icon, size: 17, color: color),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurface,
              height: 1.35,
            ),
          ),
        ),
      ],
    );
  }
}
