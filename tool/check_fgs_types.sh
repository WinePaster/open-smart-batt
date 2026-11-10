#!/usr/bin/env bash
#
# Asserts the foreground-service declarations of a BUILT APK (design 0102 §3.2).
#
#   tool/check_fgs_types.sh app_flutter/build/app/outputs/flutter-apk/app-debug.apk
#
# Reads the MERGED manifest out of the APK with aapt2, because that is what
# Google Play reads for its foreground-service declaration — the source
# manifest cannot show what plugins contribute. Two things must hold:
#
#   1. connectedDevice (0x10) is the ONLY foregroundServiceType in the app.
#      geolocator_android contributes GeolocatorLocationService with
#      foregroundServiceType="location"; AndroidManifest.xml strips that type.
#      A plugin upgrade that brings a type back turns this red instead of
#      surfacing as a Play Console declaration nobody expected.
#   2. GeolocatorLocationService is still PRESENT. getPositionStream() binds it
#      and silently emits nothing when the bind fails, so removing the whole
#      service (tools:node="remove") would ship a speed card that never gets a
#      fix — no test, no build error, no log anyone reads.
#
# The play AAB is built from the same sources and manifests; only a Dart define
# differs, which cannot change the manifest. Checking the APK covers both.
set -euo pipefail

APK="${1:?usage: $0 <apk>}"
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
AAPT2="$(ls -d "$SDK"/build-tools/* | sort -V | tail -1)/aapt2"

TREE="$("$AAPT2" dump xmltree --file AndroidManifest.xml "$APK")"

# One line, space-separated, so a GitHub ::error annotation stays on one line.
TYPES="$(grep -o 'foregroundServiceType([^)]*)=0x[0-9a-fA-F]*' <<<"$TREE" | sed 's/.*=//' | paste -sd' ' - || true)"
echo "foregroundServiceType values in merged manifest: ${TYPES:-<none>}"

fail=0
if [ "$TYPES" != "0x00000010" ]; then
  echo "::error title=foreground-service types::expected exactly one foregroundServiceType, connectedDevice (0x00000010); got: ${TYPES:-<none>}. A plugin may have added a type — strip it in AndroidManifest.xml (design 0102 §3.2) or, if it is really used, it needs a Play Console declaration."
  fail=1
fi
if ! grep -q 'com.baseflow.geolocator.GeolocatorLocationService' <<<"$TREE"; then
  echo "::error title=geolocator service missing::GeolocatorLocationService is gone from the merged manifest. getPositionStream() needs it bound and fails silently without it — strip only its type (tools:remove), never the service (design 0102 §3.2)."
  fail=1
fi
[ "$fail" = 0 ] && echo "✅ only connectedDevice; geolocator service present without a type"
exit "$fail"
