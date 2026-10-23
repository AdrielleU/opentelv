#!/usr/bin/env bash
# OpenTelV's build of the home screen (launcher/, with its own layout tweaks: a grid of
# four tiles a line, a chip-sized clock). Installs the APK kept in opentelv/home/, so
# the computer running this needs no Android SDK.
#
#   ./opentelv/home.sh            install it and give it the HOME button
#   ./opentelv/home.sh build      rebuild opentelv/home/opentelv-home.apk from launcher/
#                                 (needs JDK 17 + Android SDK; see opentelv/README.md)
#   ./launcher/install.sh --undo  hand HOME back to Amazon, as for dumbtv's build
# Flags: -y
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib.sh"

PKG=tv.dumbtv.home
APK="$ROOT/opentelv/home/opentelv-home.apk"
TOOLS=${OPENTELV_TOOLCHAIN:-$HOME/.local/opentelv-toolchain}
# The APK's SHA-256, written by `build` and checked before every install.
SUM="$APK.sha256"

sha256() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

cmd=${1:-install}
case $cmd in install|build) shift || true ;; -*) cmd=install ;; esac
parse_flags "$@"

if [[ $cmd == build ]]; then
  # A JDK 17 + SDK installed under $TOOLS, unless JAVA_HOME / ANDROID_HOME say otherwise.
  jdk=$(ls -d "$TOOLS"/jdk-17* 2>/dev/null | tail -1)
  export JAVA_HOME=${JAVA_HOME:-$jdk} ANDROID_HOME=${ANDROID_HOME:-$TOOLS/sdk}
  [[ -n $JAVA_HOME ]] && export PATH="$JAVA_HOME/bin:$PATH"
  (cd "$ROOT/launcher" && ./build.sh) || die "build failed"
  mkdir -p "$(dirname "$APK")"
  cp "$ROOT/launcher/build/dumbtv-home.apk" "$APK"
  sha256 "$APK" > "$SUM"
  note "built $APK"
  note "sha256 $(cat "$SUM") (in $(basename "$SUM"); commit both)"
  note "keep launcher/release.keystore: every later build must be signed with it"
  exit 0
fi

[[ -f $APK ]] || die "no $APK: run ./opentelv/home.sh build on a machine with the SDK"
# Catches a truncated download, a bad merge, or an APK swapped without its checksum.
# Both files come from the same repo, so this checks the file, not who published it;
# Android's signature check guards updates over an installed copy.
[[ -f $SUM ]] || die "no $SUM: the APK cannot be checked, so it is not installed"
want=$(tr -d '[:space:]' < "$SUM")
got=$(sha256 "$APK")
[[ $got == "$want" ]] || die "checksum mismatch for $APK (got $got, want $want) — not installing"
note "checksum ok"
need_device

# dumbtv's release and this build are signed with different keys, and Android only
# updates an app with the key it was installed with. Switching means removing the
# installed one, which resets dumbtv home's own settings (order, names, hidden tiles).
if present "$PKG"; then
  out=$("$ADB" -s "$SERIAL" install -r "$APK" 2>&1 | grep -m1 -E 'Success|Failure|failed' || true)
  if [[ $out == *INSTALL_FAILED_UPDATE_INCOMPATIBLE* ]]; then
    step "switching from dumbtv's build"
    note "the installed home screen is signed with dumbtv's key; this build has OpenTelV's"
    note "it has to be removed first: its order, names and hidden tiles reset"
    confirm "Remove the installed home screen and install OpenTelV's?" || die "cancelled"
    (cd "$ROOT/launcher" && ./install.sh --undo) >/dev/null
    "$ADB" -s "$SERIAL" uninstall "$PKG" | tail -1
  fi
fi

step "home screen"
(cd "$ROOT/launcher" && HOME_APK="$APK" ./install.sh --build)
