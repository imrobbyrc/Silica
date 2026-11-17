#!/bin/bash
# Builds Silica and runs Git diff detection/patch tests against a temporary repo.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DD="${SILICA_TEST_DERIVED_DATA:-/tmp/silica-git-diff-test-dd}"

xcodebuild \
    -project "$REPO_ROOT/Silica.xcodeproj" \
    -scheme Silica \
    -configuration Debug \
    -sdk macosx \
    CODE_SIGNING_ALLOWED=NO \
    -derivedDataPath "$DD" \
    build

SILICA_GIT_DIFF_SELFTEST=1 "$DD/Build/Products/Debug/Silica.app/Contents/MacOS/Silica"
