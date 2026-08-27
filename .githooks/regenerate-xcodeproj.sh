#!/usr/bin/env sh
# Regenerate ios/Tempo.xcodeproj from project.yml.
#
# Why this exists: project.yml declares sources as a directory, so XcodeGen bakes
# the concrete file list into the .xcodeproj at generation time. The .xcodeproj is
# gitignored, so it does not move when the working tree does. Generate on a branch
# that has Services/LaunchGate.swift, check out one that doesn't, and Xcode fails
# with "Build input file cannot be found" on a file git legitimately removed.
#
# Never fails the git operation that called it — a missing xcodegen is a hint, not
# an error, and a failed generate should not block a checkout mid-flight.
set -u

repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
[ -f "$repo_root/ios/project.yml" ] || exit 0

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "hook: xcodegen not installed — run 'brew install xcodegen', then 'cd ios && xcodegen generate'" >&2
  exit 0
fi

if (cd "$repo_root/ios" && xcodegen generate >/dev/null 2>&1); then
  echo "hook: regenerated ios/Tempo.xcodeproj"
else
  echo "hook: xcodegen generate failed — run it by hand in ios/ to see why" >&2
fi
exit 0
