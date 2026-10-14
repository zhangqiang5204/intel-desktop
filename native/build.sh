#!/bin/bash
set -euo pipefail
native_dir="$(cd "$(dirname "$0")" && pwd)"
plugin_dir="$(dirname "$native_dir")"
mkdir -p "$plugin_dir/bin"
xcrun swiftc -O -whole-module-optimization -target x86_64-apple-macosx13.0 \
  "$native_dir/main.swift" "$native_dir/VisualDesktop.swift" "$native_dir/BackgroundInput.swift" "$native_dir/BackgroundChatEdit.swift" "$native_dir/NativeObservation.swift" "$native_dir/NativeWindowCapture.swift" "$native_dir/CaptureLifecycle.swift" "$native_dir/NativeServiceInput.swift" "$native_dir/NativeAXAttributes.swift" "$native_dir/NativeTextSelection.swift" "$native_dir/NativeInteraction.swift" -o "$plugin_dir/bin/IntelDesktopHelper" \
  -framework AppKit -framework ApplicationServices -framework Carbon \
  -framework ScreenCaptureKit -framework Vision -framework CoreImage -framework CoreMedia -framework CoreVideo
