#!/usr/bin/env bash
# Puts a WireGuard .conf on the TV for WireGuard's own "Import from file", then
# deletes it: the file holds the tunnel's private key. The import itself is done
# on the TV with the remote, in the regular WireGuard screens; so is any editing
# afterwards (tunnel > pencil icon).
# Usage: ./opentelv/wg-import.sh <tunnel.conf> [-y]
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib.sh"

WG=com.wireguard.android
FILES=me.zhanghai.android.files
DROP=/sdcard/Download

conf=""
args=()
for a in "$@"; do
  case $a in
    -*) args+=("$a") ;;
    *) conf=$a ;;
  esac
done
parse_flags "${args[@]+"${args[@]}"}"
[[ -n $conf ]] || die "usage: ./opentelv/wg-import.sh <tunnel.conf>"
[[ -f $conf ]] || die "no such file: $conf"
grep -q '^\[Interface\]' "$conf" && grep -q '^PrivateKey' "$conf" ||
  die "$conf does not look like a WireGuard config ([Interface] with a PrivateKey)"

# WireGuard names the tunnel after the file: up to 15 of [A-Za-z0-9_=+.-].
name=$(basename "$conf"); name=${name%.conf}
[[ $name =~ ^[A-Za-z0-9_=+.-]{1,15}$ ]] ||
  die "WireGuard rejects the tunnel name '$name': rename the file to 15 or fewer of A-Z a-z 0-9 _ = + . -"

need_device
present "$WG" || die "WireGuard is not installed: ./opentelv/apps.sh wireguard"
# Fire OS has no system file picker, so "Import from file" needs an app that answers
# GET_CONTENT. Material Files is the one apps.sh installs; any other works too.
pickers=$(dev "cmd package query-activities --brief -a android.intent.action.GET_CONTENT -t '*/*'" |
  tr -d '\r' | grep -c '/' || true)
if [[ ${pickers:-0} -eq 0 ]] && ! present "$FILES"; then
  die "no file picker on the TV, so WireGuard cannot import: ./opentelv/apps.sh files"
fi

step "plan"
note "copy $conf to $DROP/$name.conf on the TV"
note "open WireGuard; you import it with the remote"
note "delete the copy afterwards (it holds the private key)"
if [[ $DRY_RUN == 1 ]]; then note "[dry-run] adb push $conf $DROP/$name.conf"; exit 0; fi
confirm "Put $name.conf on $SERIAL for import?" || die "cancelled"

# Removed on every way out, Ctrl+C included.
trap 'dev "rm -f $DROP/$name.conf" >/dev/null 2>&1; note "removed $DROP/$name.conf from the TV"' EXIT
"$ADB" -s "$SERIAL" push "$conf" "$DROP/$name.conf" | tail -1
dev "monkey -p $WG -c android.intent.category.LEANBACK_LAUNCHER 1" >/dev/null

step "on the TV, with the remote"
note "1. WireGuard: + (bottom right) > Import from file or archive"
note "2. Material Files opens (pick it if Android asks which app): Download > $name.conf"
note "3. the tunnel '$name' appears; switch it on, or edit it (tunnel > pencil icon)"
printf '\n  press Enter here once the tunnel shows in WireGuard ' >&2
read -r _
