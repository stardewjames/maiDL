import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/download_job.dart';
import '../../core/downloads_api.dart';
import '../../core/link_input.dart';

/// Link entry point used when the user opens the app instead of sharing.
class LinkComposer extends StatefulWidget {
  const LinkComposer({super.key, required this.onSave});

  /// Receives raw text, validates/downloads natively, and throws
  /// [NativeFailure] with a user-facing message on failure.
  final Future<void> Function(String input) onSave;

  @override
  State<LinkComposer> createState() => _LinkComposerState();
}

class _LinkComposerState extends State<LinkComposer> {
  final TextEditingController _text = TextEditingController();
  final FocusNode _focus = FocusNode();
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _text.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _text.removeListener(_onTextChanged);
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onTextChanged() => setState(() {});

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final raw = data?.text?.trim() ?? '';
    if (raw.isEmpty) {
      _showMessage('Your clipboard is empty.');
      return;
    }
    final parsed = parseLinkInput(raw);
    final value = parsed.url ?? raw;
    _text.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
    setState(() => _error = null);
  }

  Future<void> _submit() async {
    if (_busy) return;
    final input = _text.text.trim();
    if (input.isEmpty) {
      setState(() => _error = 'Paste a video or image link first.');
      _focus.requestFocus();
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onSave(input);
      if (!mounted) return;
      _text.clear();
      _focus.unfocus();
      HapticFeedback.mediumImpact();
    } on NativeFailure catch (failure) {
      if (!mounted) return;
      setState(() => _error = failure.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final preview = _preview();

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [scheme.primary, scheme.tertiary],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: const Icon(
                    Icons.download_rounded,
                    color: Colors.white,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Save a link',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        'Videos and images go straight to your library.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _text,
              focusNode: _focus,
              minLines: 1,
              maxLines: 3,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.go,
              autocorrect: false,
              enableSuggestions: false,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                hintText: 'https://example.com/clip.mp4',
                suffixIcon: IconButton(
                  tooltip: 'Paste from clipboard',
                  onPressed: _busy ? null : _paste,
                  icon: const Icon(Icons.content_paste_rounded, size: 20),
                ),
              ),
            ),
            if (preview != null) ...[const SizedBox(height: 10), preview],
            if (_error != null) ...[
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.error_outline_rounded,
                    size: 16,
                    color: scheme.error,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _error!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.error,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _busy ? null : _submit,
                icon: _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.download_rounded, size: 20),
                label: Text(_busy ? 'Starting…' : 'Save'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget? _preview() {
    final raw = _text.text.trim();
    if (raw.isEmpty) return null;
    final parsed = parseLinkInput(raw);
    if (!parsed.isValid) return null;
    final url = parsed.url!;
    final kind = kindHintForUrl(url);
    final host = Uri.tryParse(url)?.host ?? '';
    final label = switch (kind) {
      MediaKind.video => 'Video link',
      MediaKind.image => 'Image link',
      MediaKind.unknown => 'Link',
    };
    final icon = switch (kind) {
      MediaKind.video => Icons.movie_creation_outlined,
      MediaKind.image => Icons.image_outlined,
      MediaKind.unknown => Icons.link_rounded,
    };
    final scheme = Theme.of(context).colorScheme;

    return Row(
      children: [
        Icon(icon, size: 16, color: scheme.primary),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            host.isEmpty ? label : '$label · $host',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}
