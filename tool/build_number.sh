#!/usr/bin/env bash
#
# Single source of truth for the app build number.
#   Android  versionCode          (--build-number)
#   iOS      CFBundleVersion      (--build-number)
#
# Prints one 8-digit integer: YYMMDDNN
#
#   YYMMDD  build date
#   NN      15-minute bucket of that day (00..95)
#
# Usage:
#   tool/build_number.sh
#   flutter build apk --release --build-number="$(tool/build_number.sh)"
#
# Why this shape -- see docs/VERSIONING.md for the full rationale:
#
#   * Stateless. Derived from the clock alone, so CI and a local machine agree
#     without a shared counter. The previous scheme used github.run_number,
#     which is per-workflow-file and silently restarts at 1 if release.yml is
#     ever renamed or recreated -- an unrecoverable versionCode regression.
#
#   * 8 digits, never more. Android caps versionCode at 2,100,000,000. This
#     scheme tops out at 99123195, comfortably under. A minute-resolution
#     variant (YYMMDDHHMM) would produce e.g. 2607281530 -- over the ceiling
#     and rejected. Do not "improve" the resolution here.
#
#   * Distinct numbers for same-day releases. App Store Connect rejects a
#     duplicate CFBundleVersion within one version train, so two releases cut
#     on the same day must not collide. 15-minute buckets are coarse enough to
#     stay in two digits and fine enough that back-to-back releases differ.
#
set -euo pipefail

# Pinned timezone. CI runners are UTC; the maintainer is UTC+8. Left unpinned,
# an evening local build and a CI build minutes later disagree -- and can
# disagree *downwards*, which Android rejects as a downgrade on install.
export TZ="${BUILD_NUMBER_TZ:-Asia/Taipei}"

# 10# forces base-10: "08" and "09" are invalid octal and would abort the shell.
minutes=$(( 10#$(date +%H) * 60 + 10#$(date +%M) ))

printf '%s%02d\n' "$(date +%y%m%d)" "$(( minutes / 15 ))"
