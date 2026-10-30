#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != Darwin ]]; then
  echo 'iOS storage verification requires macOS with Xcode command-line tools.' >&2
  exit 1
fi

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/maidl-storage-smoke.XXXXXX")"
trap 'rm -rf -- "$work_dir"' EXIT

xcrun swiftc -swift-version 5 -parse-as-library \
  "$repo_root/ios/Shared/SharedConfig.swift" \
  "$repo_root/ios/Shared/JobRecord.swift" \
  "$repo_root/ios/Shared/MediaTypes.swift" \
  "$repo_root/ios/Shared/JobStore.swift" \
  "$repo_root/ios/Shared/LinkExtractor.swift" \
  "$repo_root/tool/ios_storage_smoke.swift" \
  -o "$work_dir/ios-storage-smoke"

"$work_dir/ios-storage-smoke"
