import 'package:flutter_test/flutter_test.dart';
import 'package:maidl/src/core/download_job.dart';
import 'package:maidl/src/core/link_input.dart';

void main() {
  group('extractFirstUrl', () {
    test('pulls the link out of share-sheet chatter', () {
      expect(
        extractFirstUrl('Look at this https://cdn.example.com/a/b.mp4 wow'),
        'https://cdn.example.com/a/b.mp4',
      );
    });

    test('strips trailing sentence punctuation and quotes', () {
      expect(
        extractFirstUrl('see (https://example.com/pic.png).'),
        'https://example.com/pic.png',
      );
      expect(
        extractFirstUrl('"https://example.com/pic.jpg"'),
        'https://example.com/pic.jpg',
      );
    });

    test('keeps balanced parentheses inside the path', () {
      expect(
        extractFirstUrl('https://example.com/wiki/Foo_(bar).jpg'),
        'https://example.com/wiki/Foo_(bar).jpg',
      );
    });

    test('keeps balanced parentheses at the end of a media URL', () {
      expect(
        extractFirstUrl('https://example.com/media(1)'),
        'https://example.com/media(1)',
      );
    });

    test('ignores non-http schemes and bare words', () {
      expect(extractFirstUrl('ftp://example.com/a.mp4'), isNull);
      expect(extractFirstUrl('just some words'), isNull);
    });
  });

  group('parseLinkInput', () {
    test('rejects empty input', () {
      final result = parseLinkInput('   ');
      expect(result.isValid, isFalse);
      expect(result.error, contains('Paste'));
    });

    test('rejects prose without a link', () {
      final result = parseLinkInput('this is not a link');
      expect(result.isValid, isFalse);
      expect(result.error, contains('http'));
    });

    test('accepts a bare host with a path', () {
      final result = parseLinkInput('cdn.example.com/clip.mp4');
      expect(result.url, 'https://cdn.example.com/clip.mp4');
    });

    test('does not treat a sentence with spaces as a bare host', () {
      expect(parseLinkInput('example.com is nice').isValid, isFalse);
    });

    test('drops the fragment so duplicate links map to one job', () {
      expect(
        parseLinkInput('https://example.com/v.mp4#t=30').url,
        'https://example.com/v.mp4',
      );
    });

    test('accepts uppercase schemes', () {
      expect(parseLinkInput('HTTPS://EXAMPLE.COM/a.png').url, isNotNull);
    });
  });

  group('kindHintForUrl', () {
    test('maps common extensions, ignoring query strings', () {
      expect(kindHintForUrl('https://x.dev/a.MP4?token=1'), MediaKind.video);
      expect(kindHintForUrl('https://x.dev/a.jpeg?w=2'), MediaKind.image);
      expect(kindHintForUrl('https://x.dev/a.heic'), MediaKind.image);
    });

    test('returns unknown for pages and extensionless paths', () {
      expect(kindHintForUrl('https://x.dev/watch'), MediaKind.unknown);
      expect(kindHintForUrl('https://x.dev/a.'), MediaKind.unknown);
    });
  });
}
