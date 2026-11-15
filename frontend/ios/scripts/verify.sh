#!/bin/zsh
# Verifies the native app without Xcode (Command Line Tools only):
#   1. builds TagKit and runs its test cases (macOS),
#   2. compiles the SwiftUI module + app shell for macOS AND Mac Catalyst. Catalyst uses the
#      iOS UIKit/AVAudioSession APIs, so the `#if os(iOS)` code paths are compiled too.
# With Xcode installed, prefer: open ios/CampusGuard.xcodeproj and press Cmd-U / Cmd-B.
set -euo pipefail
cd "${0:A:h}/.."
KIT=Packages/CampusGuardKit

SDK="${SDK:-}"
if [[ -z "$SDK" ]]; then
  # Prefer the active developer dir's SDK (matches its swiftc and macro plugins), then the
  # newest Command Line Tools SDK the installed compiler can read.
  for s in $(xcrun --sdk macosx --show-sdk-path) $(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX[0-9]*.sdk 2>/dev/null | sort -rV); do
    if echo 'import Foundation' | swiftc -typecheck -sdk "$s" - >/dev/null 2>&1; then SDK="$s"; break; fi
  done
fi
echo "SDK: $SDK"
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

for TARGET in arm64-apple-macos15 arm64-apple-ios18.0-macabi; do
  O="$OUT/$TARGET"; mkdir -p "$O"
  FLAGS=(-swift-version 6 -sdk "$SDK" -target "$TARGET" -warnings-as-errors)
  if [[ $TARGET == *macabi ]]; then
    FLAGS+=(-Fsystem "$SDK/System/iOSSupport/System/Library/Frameworks" -I "$SDK/System/iOSSupport/usr/lib/swift" -L "$SDK/System/iOSSupport/usr/lib/swift")
  fi
  echo "== $TARGET: TagKit"
  swiftc "${FLAGS[@]}" -enable-testing -parse-as-library -emit-library -emit-module -module-name TagKit \
    -emit-module-path "$O/TagKit.swiftmodule" $KIT/Sources/TagKit/*.swift -o "$O/libTagKit.dylib"
  echo "== $TARGET: CampusGuardUI"
  swiftc "${FLAGS[@]}" -parse-as-library -emit-library -emit-module -module-name CampusGuardUI \
    -emit-module-path "$O/CampusGuardUI.swiftmodule" -I "$O" -L "$O" -lTagKit \
    $KIT/Sources/CampusGuardUI/**/*.swift -o "$O/libCampusGuardUI.dylib"
  echo "== $TARGET: app shell"
  swiftc "${FLAGS[@]}" -typecheck -parse-as-library -I "$O" CampusGuard/*.swift
done

echo "== TagKit tests"
O="$OUT/arm64-apple-macos15"
swiftc -swift-version 6 -sdk "$SDK" -target arm64-apple-macos15 -parse-as-library -I "$O" -L "$O" -lTagKit \
  -Xlinker -rpath -Xlinker "$O" $KIT/Tests/TagKitTests/TagKitCases.swift scripts/cli-runner.swift -o "$O/tagkit-tests"
"$O/tagkit-tests"
echo "All checks passed."
