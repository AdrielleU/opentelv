#!/usr/bin/env bash
# Installs the OpenTelV app set (opentelv/apps.txt) on a Fire TV. Appstore apps are
# installed by the Appstore itself, so they stay on its automatic updates; this
# script only opens each app's store page and waits for it to land.
# Usage: ./opentelv/apps.sh [--dry-run] [-y] [--list] [--choose] [key ...]
#   no keys: installs every app in opentelv/apps.txt that is missing (the default set)
#   --choose: asks about each missing app instead
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib.sh"

APPS_TXT="$ROOT/opentelv/apps.txt"
STORE=com.amazon.venezia
WG_BASE=https://download.wireguard.com/android-client
TS_BASE=https://pkgs.tailscale.com/stable
TS_PKG=com.tailscale.ipn
RD_PKG=com.carriez.flutter_hbb
RD_INPUT=$RD_PKG/$RD_PKG.InputService
# Pinned: releases are immutable, so this hash identifies the exact build. The
# universal APK covers both the 32-bit sticks (armeabi-v7a) and the 64-bit ones.
RD_APK_URL=https://github.com/rustdesk/rustdesk/releases/download/1.5.0/rustdesk-1.5.0-universal-signed.apk
RD_APK_SHA256=b7910dea1b6ec4a079aa753e0432c2269b843d89d900c7a3930b6ec13f3ba112
# Material Files: open source, and a system file picker (GET_CONTENT), which Fire OS
# lacks and WireGuard's Import from file needs. Pinned the same way.
MF_PKG=me.zhanghai.android.files
MF_APK_URL=https://github.com/zhanghai/MaterialFiles/releases/download/v1.7.5/app-release-universal.apk
MF_APK_SHA256=f2e7f028fbddf51d7ee90ace27a1ae4b247511e12514d1def6c9e52435feac40
# How long to wait for someone to press Get on the TV, per app.
APPSTORE_WAIT=${APPSTORE_WAIT:-300}

LIST=0
CHOOSE=0
keys=()
args=()
for a in "$@"; do
  case $a in
    --list) LIST=1 ;;
    --choose) CHOOSE=1 ;;
    -*) args+=("$a") ;;
    *) keys+=("$a") ;;
  esac
done
parse_flags "${args[@]+"${args[@]}"}"

field() { list_of "$APPS_TXT" | awk -v k="$1" -v f="$2" '$1==k {print $f; exit}'; }
title() { list_of "$APPS_TXT" | awk -v k="$1" '$1==k {$1=$2=$3=""; sub(/^[[:space:]]+/,""); print; exit}'; }

if [[ $LIST == 1 ]]; then
  list_of "$APPS_TXT" | awk '{k=$1; s=$3; $1=$2=$3=""; sub(/^[[:space:]]+/,""); printf "  %-11s %-9s %s\n", k, s, $0}'
  exit 0
fi

need_device
need_supported_fireos

if [[ ${#keys[@]} -eq 0 ]]; then
  # Every app in apps.txt is in the default set. Installed ones are skipped, except
  # Tailscale, whose run also upgrades it (it has no updater of its own).
  step "$([[ $CHOOSE == 1 ]] && echo "choose apps" || echo "default apps")"
  for k in $(list_of "$APPS_TXT" | awk '{print $1}'); do
    if present "$(field "$k" 2)" && [[ $k != tailscale ]]; then
      note "$(title "$k"): already installed"
      continue
    fi
    if [[ $CHOOSE == 1 ]]; then
      confirm "Install $(title "$k")?" && keys+=("$k")
    else
      keys+=("$k")
    fi
  done
  [[ ${#keys[@]} -eq 0 ]] && { note "nothing to install"; exit 0; }
fi
for k in "${keys[@]}"; do
  [[ -n $(field "$k" 2) ]] || die "unknown app '$k' (see ./opentelv/apps.sh --list)"
done

step "plan"
for k in "${keys[@]}"; do
  case $(field "$k" 3) in
    appstore)  note "$(title "$k"): Amazon Appstore (auto-updates)" ;;
    wireguard) note "$(title "$k"): official APK from $WG_BASE (updates itself)" ;;
    tailscale) note "$(title "$k"): official APK from $TS_BASE (run this again to update)" ;;
    files)     note "$(title "$k"): pinned GitHub release (run this again after bumping the pin)" ;;
    rustdesk)  note "$(title "$k"): pinned GitHub release, plus screen-capture and input grants (work in progress on Fire TV)" ;;
  esac
done
if [[ $DRY_RUN == 1 ]]; then
  for k in "${keys[@]}"; do
    case $(field "$k" 3) in
      appstore)  note "[dry-run] am start -d amzn://apps/android?p=$(field "$k" 2)" ;;
      wireguard) note "[dry-run] download $WG_BASE/latest.sig, then the APK it names; adb install -r" ;;
      tailscale) note "[dry-run] download the latest APK from $TS_BASE and its .sha256; adb install -r" ;;
      files)     note "[dry-run] download $MF_APK_URL; adb install -r" ;;
      rustdesk)
        note "[dry-run] download $RD_APK_URL; adb install -r"
        note "[dry-run] appops set $RD_PKG PROJECT_MEDIA allow; SYSTEM_ALERT_WINDOW allow"
        note "[dry-run] add $RD_INPUT to enabled_accessibility_services (kept alongside the others)" ;;
    esac
  done
  exit 0
fi
confirm "Install ${#keys[@]} app(s) on $SERIAL?" || die "cancelled"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/opentelv-apps.XXXXXX") || die "could not create a temp dir"
trap 'rm -rf "$WORK"' EXIT

sha256() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

# Presses the store page's Get button the way the remote would. Amazon offers no
# install command (the install is a free "purchase" on the account, which is what
# keeps it updating), so the button is the only way in. The button is found by its
# label in a uiautomator dump and tapped; a page showing a price or Buy is never
# pressed, so a paid app added to apps.txt still waits for a person.
press_get() {
  local try ui node b
  for try in 1 2 3; do
    sleep 4
    ui=$(dev "uiautomator dump /sdcard/opentelv-ui.xml >/dev/null 2>&1; cat /sdcard/opentelv-ui.xml; rm -f /sdcard/opentelv-ui.xml")
    if grep -qE '(text|content-desc)="[^"]*(\$[0-9]|[Bb]uy)' <<<"$ui"; then
      note "the page shows a price: not pressing anything"; return 1
    fi
    node=$(grep -oE '<node [^>]*>' <<<"$ui" |
      grep -iE '(text|content-desc)="(get|download|install|free)"' | head -1)
    if [[ -n $node ]]; then
      b=$(sed -n 's/.*bounds="\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]".*/\1 \2 \3 \4/p' <<<"$node")
      set -- $b
      [[ $# -eq 4 ]] && { dev "input tap $((($1 + $3) / 2)) $((($2 + $4) / 2))" >/dev/null; note "pressed Get"; return 0; }
    fi
  done
  # No readable button (the page did not dump): the Appstore focuses Get on load,
  # so OK on the remote is what a person would press.
  [[ -z $ui ]] && { dev "input keyevent 23" >/dev/null; note "pressed OK"; return 0; }
  return 1
}

# True while the store page shows a download or install under way.
downloading() {
  dev "uiautomator dump /sdcard/opentelv-ui.xml >/dev/null 2>&1; cat /sdcard/opentelv-ui.xml; rm -f /sdcard/opentelv-ui.xml" |
    grep -qiE '(text|content-desc)="[^"]*(downloading|installing|cancel|[0-9]+ ?%)'
}

# The Appstore opens straight to an app's page from its deep link; press_get presses
# Get. The TV reporting the package is the answer either way.
user_pkgs() { dev "pm list packages -3" | tr -d '\r' | sed 's/^package://' | sort -u; }

install_appstore() {
  local pkg=$1 name=$2 waited=0 before new
  grep -qx "package:$STORE" <<<"$(dev "pm list packages -d" | tr -d '\r')" &&
    die "the Appstore ($STORE) is disabled; run: adb shell pm enable $STORE"
  before=$(user_pkgs)
  dev "am start -a android.intent.action.VIEW -d 'amzn://apps/android?p=$pkg'" >/dev/null
  note "the Appstore page for $name is open on the TV"
  press_get || note "could not press Get: press Get / Download with the remote"
  while ! present "$pkg"; do
    [[ $waited -ge $APPSTORE_WAIT ]] && { note "$name: not installed after ${APPSTORE_WAIT}s, skipped"; return 1; }
    # The Fire TV build of an app can carry another package name than apps.txt has.
    # Whatever the Appstore just installed counts, and the name is reported so
    # apps.txt can be fixed.
    new=$(comm -13 <(printf '%s\n' "$before") <(user_pkgs) | head -1)
    if [[ -n $new ]]; then
      note "$name installed as $new (apps.txt says $pkg: change it to $new)"
      return 0
    fi
    # The Appstore's TV pages can ignore a touch tap and only take the remote's OK.
    # OK is sent once, and only while the page shows no download in progress: on a
    # running download, focus may sit on Cancel.
    if [[ $waited -eq 20 ]] && ! downloading; then
      dev "input keyevent 23" >/dev/null
      note "no download started; pressed OK"
    fi
    [[ $waited -eq 60 ]] && note "still not installed: press Get / Download with the remote"
    [[ $waited -gt 0 && $((waited % 15)) -eq 0 ]] && note "waiting for $name (${waited}s)"
    sleep 5; waited=$((waited + 5))
  done
  note "$name installed"
}

# latest.sig is a signify-signed manifest: "<sha256>  <apk name>". Fetched over
# HTTPS from WireGuard's own host; the APK must match the hash it lists.
install_wireguard() {
  local sig=$WORK/latest.sig apk_name want got out
  fetch "$sig" "$WG_BASE/latest.sig" || die "could not download $WG_BASE/latest.sig"
  read -r want apk_name <<<"$(grep -E '^[0-9a-f]{64}  com\.wireguard\.android-.*\.apk$' "$sig" | tail -1)"
  [[ -n ${apk_name:-} ]] || die "latest.sig has no APK line; format changed upstream"
  fetch "$WORK/$apk_name" "$WG_BASE/$apk_name" || die "could not download $apk_name"
  got=$(sha256 "$WORK/$apk_name")
  [[ $got == "$want" ]] || die "checksum mismatch for $apk_name (got $got) — not installing"
  note "checksum ok ($apk_name)"
  out=$("$ADB" -s "$SERIAL" install -r "$WORK/$apk_name" 2>&1 | tail -1)
  note "$out"
  adb_reconnect
  present com.wireguard.android || { note "WireGuard: not installed"; return 1; }
  note "WireGuard installed"
}

# Tailscale is not in every Appstore region, and not on every model. Tailscale
# publishes the same app for direct download, with a .sha256 beside each APK. A
# sideloaded copy does not update itself, so this also upgrades it when run again.
install_tailscale() {
  local apk_name ver have got want out
  apk_name=$(curl -fsSL --retry 3 "$TS_BASE/?mode=json" | grep -oE 'tailscale-android-universal-[0-9.]+\.apk' | head -1)
  [[ -n $apk_name ]] || die "could not read the latest Tailscale APK from $TS_BASE"
  ver=${apk_name#tailscale-android-universal-}; ver=${ver%.apk}
  have=$(dev "dumpsys package $TS_PKG" | sed -n 's/.*versionName=\([0-9.]*\).*/\1/p' | head -1)
  if [[ -n $have ]]; then
    [[ $have == "$ver" ]] && { note "Tailscale $have is the latest"; return 0; }
    note "updating Tailscale $have -> $ver"
  fi
  fetch "$WORK/$apk_name" "$TS_BASE/$apk_name" || die "could not download $apk_name"
  want=$(curl -fsSL --retry 3 "$TS_BASE/$apk_name.sha256" | awk '{print $1}')
  got=$(sha256 "$WORK/$apk_name")
  [[ -n $want && $got == "$want" ]] || die "checksum mismatch for $apk_name (got $got, want ${want:-none}) — not installing"
  note "checksum ok ($apk_name)"
  out=$("$ADB" -s "$SERIAL" install -r "$WORK/$apk_name" 2>&1 | tail -1)
  note "$out"
  adb_reconnect
  present "$TS_PKG" || { note "Tailscale: not installed"; return 1; }
  note "Tailscale $ver installed"
}

# The app asks for screen capture with a consent box and for input control through
# Accessibility settings, both built for a touchscreen; on a Fire TV the remote cannot
# get through them, which is why it "connects but cannot control". The shell user can
# grant both: the PROJECT_MEDIA app-op skips the consent box (as ACTIVATE_VPN does for
# the DNS filter), and the input service is added to the enabled list next to
# whatever is there already, such as dumbtv home's Guard.
install_rustdesk() {
  install_pinned "$RD_APK_URL" "$RD_APK_SHA256" "$RD_PKG" RustDesk || return 1
  setup_rustdesk
}

# A GitHub release APK whose hash is pinned in this file: releases are immutable, so
# the hash identifies the exact build. $1 url, $2 sha256, $3 package, $4 name.
install_pinned() {
  local apk=$WORK/pinned.apk got out
  fetch "$apk" "$1" || die "could not download $1"
  got=$(sha256 "$apk")
  [[ $got == "$2" ]] || die "checksum mismatch for $1 (got $got) — not installing"
  note "checksum ok"
  out=$("$ADB" -s "$SERIAL" install -r "$apk" 2>&1 | tail -1)
  note "$out"
  adb_reconnect
  present "$3" || { note "$4: not installed"; return 1; }
  note "$4 installed"
}

setup_rustdesk() {
  local cur
  dev "appops set $RD_PKG PROJECT_MEDIA allow" >/dev/null
  dev "appops set $RD_PKG SYSTEM_ALERT_WINDOW allow" >/dev/null
  dev "dumpsys deviceidle whitelist +$RD_PKG" >/dev/null
  cur=$(dev1 settings get secure enabled_accessibility_services)
  case $cur in null|"") cur="" ;; esac
  case ":$cur:" in
    *":$RD_INPUT:"*) ;;
    *) dev "settings put secure enabled_accessibility_services '${cur:+$cur:}$RD_INPUT'" >/dev/null ;;
  esac
  dev "settings put secure accessibility_enabled 1" >/dev/null
  case ":$(dev1 settings get secure enabled_accessibility_services):" in
    *":$RD_INPUT:"*) note "input control: granted" ;;
    *) note "input control: Fire OS refused the accessibility grant; remote viewing only" ;;
  esac
  note "screen capture: pre-approved"
}

# The TV's own address: the host part of a network serial, else wlan0/eth0.
tv_ip() {
  case $SERIAL in
    [0-9]*.*.*.*:*) printf '%s' "${SERIAL%:*}" ;;
    *) dev 'ip -f inet addr show' | awk '/inet / && !/127\.0\.0\.1/ && !/tun/ {sub(/\/.*/,"",$2); print $2; exit}' ;;
  esac
}
# A /24 around the TV, good enough for the whitelist hint on a home network.
lan_cidr() { tv_ip | awk -F. 'NF==4 {printf "%s.%s.%s.0/24", $1,$2,$3}'; }

failed=""
for k in "${keys[@]}"; do
  pkg=$(field "$k" 2)
  step "$(title "$k")"
  # Sideloaded Tailscale has no updater; its installer checks for a newer build.
  if [[ $(field "$k" 3) == tailscale ]]; then install_tailscale || failed="$failed $k"; continue; fi
  if present "$pkg"; then
    note "already installed"
    # Grants are lost when the app is reinstalled or Fire OS resets settings.
    [[ $k == rustdesk ]] && setup_rustdesk
    continue
  fi
  case $(field "$k" 3) in
    appstore)  install_appstore "$pkg" "$(title "$k")" || failed="$failed $k" ;;
    wireguard) install_wireguard || failed="$failed $k" ;;
    files)     install_pinned "$MF_APK_URL" "$MF_APK_SHA256" "$MF_PKG" "Material Files" || failed="$failed $k" ;;
    rustdesk)  install_rustdesk || failed="$failed $k" ;;
  esac
done

step "after"
note "Appstore auto-updates: Settings > Applications > Appstore > Automatic Updates: On"
note "home screen order: dumbtv home > Options (Fire OS 8 hides home.conf from adb)"
for k in "${keys[@]}"; do
  case $k in
    wholphin)  note "Wholphin: the Appstore build has no Seerr integration (GitHub/Play builds only)" ;;
    moonlight) note "Moonlight: pair with Sunshine on your PC; on the home network no VPN is needed" ;;
    tailscale|wireguard)
      note "$(title "$k"): set it up, then ./opentelv/vpn.sh on $k"
      [[ $k == wireguard ]] && note "  import a tunnel: ./opentelv/wg-import.sh <tunnel.conf> (needs: apps.sh files)"
      note "  Tailscale: turn on Exit node > Allow LAN access BEFORE picking the exit node,"
      note "  or adb, scrcpy, RustDesk by IP and Moonlight at home all lose the TV" ;;
    files)     note "Material Files: WireGuard's Import from file now has a picker" ;;
    rustdesk)
      note "RustDesk, once, with scrcpy (the app's screens are touch-only):"
      note "  open it: adb shell monkey -p $RD_PKG -c android.intent.category.LAUNCHER 1"
      note "  Share screen tab > Start service; note the ID at the top"
      note "  ... menu > Set permanent password (long and unique: this is the key to the TV)"
      note "  settings: enable 'Start on boot' so the ID answers after a reboot"
      note "  connect by IP on the home network instead of the ID (no relay):"
      note "    Settings > Screen sharing > Direct IP access: on (port 21118)"
      note "    IP whitelist: $(lan_cidr) so only this network can connect"
      note "    then from a computer: RustDesk > enter $(tv_ip) as the ID"
      note "  never forward port 21118 on the router; away from home use the TV's Tailscale IP" ;;
  esac
done
[[ -z $failed ]] || die "not installed:$failed — run again with those keys"
