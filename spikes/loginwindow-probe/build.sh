#!/bin/bash
# Builds the Phase 0 LoginWindow probe (fork-only spike; not part of the macrdp build).
#
#   spikes/loginwindow-probe/build.sh            # ad-hoc signed
#   SIGN_ID="macrdp-dev" spikes/loginwindow-probe/build.sh
#
# TCC pins an ad-hoc signature to its cdhash, so every rebuild invalidates the Screen
# Recording / Accessibility grants (docs/macos-gotchas.md). Rebuild, then re-install
# and re-grant, or sign with a certificate identity (SIGN_ID) to keep grants.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/build/macrdp-lwprobe"
mkdir -p "$HERE/build"

# macOS 14 deployment target: the SDK marks CGDisplayStream / CGWindowListCreateImage
# obsolete from 15, and the probe looks those up at runtime anyway.
xcrun swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
    -o "$OUT" "$HERE/main.swift"

codesign --force --sign "${SIGN_ID:--}" --identifier com.github.jm2.macrdp-lwprobe "$OUT"
codesign -dv "$OUT" 2>&1 | grep -E '^(Identifier|CDHash|Signature|TeamIdentifier)=' || true
echo "built $OUT"
