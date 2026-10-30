#!/usr/bin/env bash
set -euo pipefail

# This dependency is for fixture generation/probing only, never the shipped app.
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'iOS video verification requires macOS with Xcode command-line tools.' >&2
  exit 1
fi
if ! command -v ffmpeg >/dev/null 2>&1 || ! command -v ffprobe >/dev/null 2>&1; then
  if ! command -v brew >/dev/null 2>&1; then
    echo 'Install ffmpeg (including ffprobe), or Homebrew, before running this smoke.' >&2
    exit 1
  fi
  brew install ffmpeg
fi

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/maidl-video-smoke.XXXXXX")"
trap 'rm -rf -- "$work_dir"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Software encoders avoid dependence on a runner's hardware encoder availability.
ffmpeg -hide_banner -loglevel error -nostdin -y \
  -f lavfi -i 'testsrc2=size=160x96:rate=12' \
  -f lavfi -i 'sine=frequency=880:sample_rate=48000' \
  -t 1 -map 0:v:0 -map 1:a:0 \
  -c:v libx264 -preset ultrafast -threads:v 1 -pix_fmt yuv420p \
  -c:a aac -b:a 96k -movflags +faststart "$work_dir/h264-aac.mp4"
ffmpeg -hide_banner -loglevel error -nostdin -y \
  -i "$work_dir/h264-aac.mp4" -map 0 -c copy -f mov "$work_dir/h264-aac.mov"

# An .mp4 suffix is not proof of an H.264 video stream.
ffmpeg -hide_banner -loglevel error -nostdin -y \
  -i "$work_dir/h264-aac.mp4" -map 0 -c:v libx265 -preset ultrafast \
  -x265-params 'pools=1:frame-threads=1:log-level=error' \
  -pix_fmt yuv420p -tag:v hvc1 -c:a copy "$work_dir/hevc-aac.mp4"
ffmpeg -hide_banner -loglevel error -nostdin -y \
  -i "$work_dir/h264-aac.mp4" -map 0 -c copy -f mov "$work_dir/mov-disguised.mp4"
ffmpeg -hide_banner -loglevel error -nostdin -y \
  -i "$work_dir/h264-aac.mp4" -map 0 -c:v prores_ks -profile:v 0 \
  -threads:v 1 -pix_fmt yuv422p10le -c:a pcm_s16le "$work_dir/prores-pcm.mov"
# Set an input display matrix explicitly; recent FFmpeg ignores a rotate tag.
ffmpeg -hide_banner -loglevel error -nostdin -y \
  -display_rotation:v:0 90 -i "$work_dir/prores-pcm.mov" -map 0 -c copy \
  "$work_dir/prores-pcm-rotated.mov"
ffmpeg -hide_banner -loglevel error -nostdin -y \
  -i "$work_dir/h264-aac.mp4" -map 0:v:0 -c copy -an -f mov "$work_dir/silent.mov"
ffmpeg -hide_banner -loglevel error -nostdin -y \
  -i "$work_dir/hevc-aac.mp4" -map 0:v:0 -c copy -an "$work_dir/silent-hevc.mp4"
ffmpeg -hide_banner -loglevel error -nostdin -y \
  -i "$work_dir/h264-aac.mp4" -map 0:a:0 -c copy -vn "$work_dir/audio-only.m4a"
# YouTube-style adaptive merge output: fragmented MP4.
ffmpeg -hide_banner -loglevel error -nostdin -y \
  -i "$work_dir/h264-aac.mp4" -map 0 -c copy \
  -movflags frag_keyframe+empty_moov "$work_dir/fragmented.mp4"
printf 'not an audiovisual container\n' > "$work_dir/corrupt.mp4"

# Compile the shipping implementation, not a test double or a copied converter.
xcrun swiftc -swift-version 5 -parse-as-library \
  -target "$(uname -m)-apple-macosx12.0" \
  -framework AVFoundation -framework AudioToolbox \
  "$repo_root/ios/Shared/VideoCompatibility.swift" \
  "$repo_root/tool/ios_video_smoke.swift" \
  -o "$work_dir/ios-video-smoke"
"$work_dir/ios-video-smoke" "$work_dir" "$(command -v ffprobe)"
