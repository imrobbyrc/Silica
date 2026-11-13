#!/bin/bash
# Builds Silica and runs its LSP integration self-test against the fake language
# server in this directory. The self-test drives the real
# LanguageServerCoordinator (process launch, initialize handshake, document
# sync, definition request, position mapping) inside the app binary and exits
# 0 on pass, 1 on failure.
#
# Usage: scripts/test-lsp-integration.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DD=/tmp/silica-lsp-test-dd

xcodebuild \
    -project "$REPO_ROOT/Silica.xcodeproj" \
    -scheme Silica \
    -configuration Debug \
    -sdk macosx \
    CODE_SIGNING_ALLOWED=NO \
    -derivedDataPath "$DD" \
    build

BINARY="$DD/Build/Products/Debug/Silica.app/Contents/MacOS/Silica"
FAKE_SERVER="$REPO_ROOT/scripts/fake-lsp-server.py"

# The self-test starts on launch (SILICA_LSP_SELFTEST=1) and exits by itself.
# SILICA_LSP_SWIFT_EXEC points the Swift server slot at the fake stdio server,
# so no real sourcekit-lsp session is involved in the test.
SILICA_LSP_SELFTEST=1 \
SILICA_LSP_SWIFT_EXEC="/usr/bin/python3 $FAKE_SERVER" \
    "$BINARY"
