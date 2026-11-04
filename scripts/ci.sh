#!/usr/bin/env bash
# Single CI entry point used both locally and by GitHub Actions.
#   scripts/ci.sh          build (warnings shown) + run all unit tests
#   scripts/ci.sh build    build only
#   scripts/ci.sh test     tests only
set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT="SpaceSweeper.xcodeproj"
SCHEME="SpaceSweeper"
DERIVED="build/DerivedData"
RESULTS="build/TestResults.xcresult"
DESTINATION="platform=macOS,arch=arm64"
STEP="${1:-all}"

# Ad-hoc signing so CI machines without a developer team can build.
COMMON=(-project "$PROJECT" -scheme "$SCHEME" -destination "$DESTINATION"
        -derivedDataPath "$DERIVED" CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO)

run() {
  if command -v xcbeautify >/dev/null 2>&1; then
    "$@" | xcbeautify
  else
    "$@"
  fi
}

if [[ "$STEP" == "all" || "$STEP" == "build" ]]; then
  echo "▸ Building $SCHEME"
  run xcodebuild "${COMMON[@]}" -configuration Debug build
fi

if [[ "$STEP" == "all" || "$STEP" == "test" ]]; then
  echo "▸ Testing $SCHEME"
  rm -rf "$RESULTS"
  run xcodebuild "${COMMON[@]}" -resultBundlePath "$RESULTS" test
fi

echo "✔ CI step '$STEP' passed"
