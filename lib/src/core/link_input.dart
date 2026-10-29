/// Parsing and validation for user/share-supplied links.
///
/// Native code re-validates everything it receives; this layer exists so the
/// user gets instant, specific feedback and so share-sheet text with trailing
/// chatter ("look at this https://… amazing") still resolves.
library;

import 'download_job.dart';

class LinkParseResult {
  const LinkParseResult.valid(this.url) : error = null;
  const LinkParseResult.invalid(this.error) : url = null;

  final String? url;
  final String? error;

  bool get isValid => url != null;
}

const Map<String, MediaKind> _extensionKinds = {
  'mp4': MediaKind.video,
  'm4v': MediaKind.video,
  'mov': MediaKind.video,
  'webm': MediaKind.video,
  'mkv': MediaKind.video,
  'avi': MediaKind.video,
  '3gp': MediaKind.video,
  'mpg': MediaKind.video,
  'mpeg': MediaKind.video,
  'jpg': MediaKind.image,
  'jpeg': MediaKind.image,
  'png': MediaKind.image,
  'gif': MediaKind.image,
  'webp': MediaKind.image,
  'heic': MediaKind.image,
  'heif': MediaKind.image,
  'bmp': MediaKind.image,
  'tif': MediaKind.image,
  'tiff': MediaKind.image,
};

final RegExp _httpUrl = RegExp(r'https?://[^\s<>"]+', caseSensitive: false);
final RegExp _bareHost = RegExp(
  r'^(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}(?::\d+)?(?:[/?#].*)?$',
  caseSensitive: false,
);
const String _trailingJunk = '.,;:!?]}>\'"';

/// Returns the first usable http(s) URL inside [text], or null.
String? extractFirstUrl(String text) {
  for (final match in _httpUrl.allMatches(text)) {
    final candidate = _trimUrl(match.group(0)!);
    if (candidate != null) return candidate;
  }
  return null;
}

/// Accepts a full URL, a URL surrounded by prose, or a bare host like
/// `cdn.example.com/clip.mp4`.
LinkParseResult parseLinkInput(String raw) {
  final text = raw.trim();
  if (text.isEmpty) {
    return const LinkParseResult.invalid('Paste a video or image link first.');
  }

  final extracted = extractFirstUrl(text);
  if (extracted != null) {
    return LinkParseResult.valid(_normalize(extracted));
  }

  if (!text.contains(RegExp(r'\s')) && _bareHost.hasMatch(text)) {
    final normalized = _normalize('https://$text');
    return LinkParseResult.valid(normalized);
  }

  return const LinkParseResult.invalid(
    "That doesn't look like an http or https link.",
  );
}

/// Best-effort media kind from the URL extension. Native code confirms it with
/// the response Content-Type, then falls back to this hint.
MediaKind kindHintForUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.pathSegments.isEmpty) return MediaKind.unknown;
  final name = uri.pathSegments.last;
  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return MediaKind.unknown;
  final ext = name.substring(dot + 1).toLowerCase();
  return _extensionKinds[ext] ?? MediaKind.unknown;
}

String _normalize(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return url;
  return uri.removeFragment().toString();
}

String? _trimUrl(String value) {
  var candidate = value;
  while (candidate.isNotEmpty) {
    final last = candidate[candidate.length - 1];
    if (_trailingJunk.contains(last)) {
      candidate = candidate.substring(0, candidate.length - 1);
      continue;
    }
    // Remove unmatched prose punctuation, not balanced URL characters.
    if (last == ')' &&
        '('.allMatches(candidate).length < ')'.allMatches(candidate).length) {
      candidate = candidate.substring(0, candidate.length - 1);
      continue;
    }
    break;
  }
  if (candidate.length <= 'https://'.length) return null;
  if (candidate.endsWith('://')) return null;
  return candidate;
}
