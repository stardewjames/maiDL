/// Link resolver configuration shared with the native layer.
///
/// Only social links are sent to a resolver; direct media URLs still go
/// straight to the download engine.
library;

enum ResolverMode {
  off('off'),
  ytdlp('ytdlp'),
  cobalt('cobalt');

  const ResolverMode(this.wire);

  final String wire;

  static ResolverMode fromWire(Object? value) {
    for (final mode in values) {
      if (mode.wire == value) return mode;
    }
    return ResolverMode.off;
  }
}

class ResolverSettings {
  const ResolverSettings({
    this.mode = ResolverMode.off,
    this.ytdlpUrl = '',
    this.cobaltUrl = '',
  });

  final ResolverMode mode;
  final String ytdlpUrl;
  final String cobaltUrl;

  String? get activeUrl {
    final value = switch (mode) {
      ResolverMode.off => '',
      ResolverMode.ytdlp => ytdlpUrl,
      ResolverMode.cobalt => cobaltUrl,
    }.trim();
    return value.isEmpty ? null : value;
  }

  bool get isEnabled => mode != ResolverMode.off && activeUrl != null;

  ResolverSettings copyWith({
    ResolverMode? mode,
    String? ytdlpUrl,
    String? cobaltUrl,
  }) {
    return ResolverSettings(
      mode: mode ?? this.mode,
      ytdlpUrl: ytdlpUrl ?? this.ytdlpUrl,
      cobaltUrl: cobaltUrl ?? this.cobaltUrl,
    );
  }

  factory ResolverSettings.fromWire(Object? value) {
    if (value is! Map) return const ResolverSettings();
    final map = value.cast<Object?, Object?>();
    return ResolverSettings(
      mode: ResolverMode.fromWire(map['mode']),
      ytdlpUrl: (map['ytdlpUrl'] as String? ?? '').trim(),
      cobaltUrl: (map['cobaltUrl'] as String? ?? '').trim(),
    );
  }

  Map<String, Object?> toWire() => {
    'mode': mode.wire,
    'ytdlpUrl': ytdlpUrl,
    'cobaltUrl': cobaltUrl,
  };

  @override
  bool operator ==(Object other) =>
      other is ResolverSettings &&
      other.mode == mode &&
      other.ytdlpUrl == ytdlpUrl &&
      other.cobaltUrl == cobaltUrl;

  @override
  int get hashCode => Object.hash(mode, ytdlpUrl, cobaltUrl);
}
