#!/usr/bin/env bash
# Saves what you customised on a TV, so an update, a factory reset or a new TV can get it
# back. Backups go in backups/ (git-ignored: they describe your TV).
#
#   ./opentelv/backup.sh [NAME]          save into backups/NAME (default: the date and time)
#   ./opentelv/backup.sh restore [NAME]  put a backup on the TV (default: the newest)
#   ./opentelv/backup.sh list
#
# Saved: the home screen's settings (app order, names, hidden tiles, Options, remote button
# mappings, the WireGuard tunnel at boot), its wallpapers and library pictures, dumbtv.conf
# and the list of installed apps. Not saved: WireGuard tunnels themselves (their keys stay
# inside WireGuard; keep your .conf files, and re-import with ./opentelv/wg-import.sh).
# Flags: --dry-run, -y
set -uo pipefail
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$DIR/../scripts/lib.sh"

HOME_PKG=tv.dumbtv.home
BACKUPS=${BACKUPS:-$ROOT/backups}

cmd=save; name=""
case ${1:-} in
  restore|list) cmd=$1; shift ;;
  save) shift ;;
esac
case ${1:-} in -*|"") ;; *) name=$1; shift ;; esac
parse_flags "$@"
load_conf
[[ -z $name || $name =~ ^[A-Za-z0-9_.-]+$ ]] || die "backup names use A-Z a-z 0-9 _ . -"

newest() { ls -1t "$BACKUPS" 2>/dev/null | head -1; }

# The home screen writes its settings into its media folder, the one adb can read on Fire OS 8.
home_export() {
  dev "am broadcast -n $HOME_PKG/.Export" | tr -d '\r' | sed -n 's/.*data="\(.*\)".*/\1/p'
}
has_receiver() { local info; info=$(dev "dumpsys package $HOME_PKG"); grep -q "$HOME_PKG/.$1" <<<"$info"; }

case $cmd in
list)
  [[ -d $BACKUPS ]] && ls -1t "$BACKUPS" || note "no backups yet: ./opentelv/backup.sh"
  ;;

save)
  need_device
  name=${name:-$(date +%Y-%m-%d_%H%M)}
  out=$BACKUPS/$name
  [[ -e $out ]] && die "backups/$name exists already; pick another name"
  step "backup → backups/$name"
  if [[ $DRY_RUN == 1 ]]; then note "[dry-run] would save the home screen, dumbtv.conf and the app list"; exit 0; fi
  mkdir -p "$out"
  if present "$HOME_PKG" && has_receiver Export; then
    copy=$(home_export)
    [[ -n $copy ]] || die "the home screen could not export its settings"
    media=$(dirname "$copy")
    "$ADB" -s "$SERIAL" pull "$media" "$out/media" >/dev/null || die "could not copy $media"
    mv "$out/media/$(basename "$copy")" "$out/home.conf"
    rm -f "$out/media/home.conf" "$out/media/"*.tmp
    dev "rm -f '$copy'" >/dev/null
    note "home screen settings: $(grep -c '=' "$out/home.conf") entries ($(grep -c '^button\.' "$out/home.conf" || true) remote buttons)"
    note "home screen pictures: $(find "$out/media" -type f | wc -l | tr -d ' ') files"
  elif present "$HOME_PKG"; then
    note "the home screen is too old to export from adb; update it (./opentelv/home.sh) or use"
    note "Options > Export settings on the TV, then: adb pull /sdcard/Android/media/$HOME_PKG/home-export.conf"
  else
    note "OpenTelV's home screen is not installed: nothing to save from it"
  fi
  [[ -f $CONF ]] && cp "$CONF" "$out/dumbtv.conf" && note "dumbtv.conf saved"
  dev "pm list packages -3" | tr -d '\r' | sed 's/^package://' | sort > "$out/apps.txt"
  note "installed apps: $(grep -c . "$out/apps.txt")"
  { echo "date=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "model=$(dev1 getprop ro.product.model)"
    echo "fireos=$(dev1 getprop ro.build.version.name)"; } > "$out/about.txt"
  note "restore with: ./opentelv/backup.sh restore $name"
  ;;

restore)
  name=${name:-$(newest)}
  [[ -n $name && -d $BACKUPS/$name ]] || die "no backup ${name:-yet} (./opentelv/backup.sh list)"
  in=$BACKUPS/$name
  need_device
  step "restore backups/$name"
  if [[ -f $in/home.conf ]]; then
    present "$HOME_PKG" || die "install the home screen first: ./opentelv/home.sh"
    has_receiver Export || die "the home screen is too old; update it first: ./opentelv/home.sh"
    note "home screen settings, button mappings and pictures"
  fi
  [[ -f $in/dumbtv.conf && ! -f $CONF ]] && note "dumbtv.conf (none here yet)"
  if [[ $DRY_RUN == 1 ]]; then note "[dry-run] nothing changed"; exit 0; fi
  confirm "Put backups/$name on $SERIAL?" || die "cancelled"

  if [[ -f $in/home.conf ]]; then
    media=/sdcard/Android/media/$HOME_PKG
    dev "mkdir -p $media" >/dev/null
    if [[ -d $in/media ]] && [[ -n $(ls -A "$in/media") ]]; then
      "$ADB" -s "$SERIAL" push "$in/media/." "$media/" >/dev/null || die "could not copy the pictures"
    fi
    # The home screen merges a home.conf pushed here once, on its next refresh.
    "$ADB" -s "$SERIAL" push "$in/home.conf" "$media/home.conf" >/dev/null || die "could not copy home.conf"
    dev "input keyevent KEYCODE_HOME" >/dev/null
    note "home screen settings put back (applied when the home screen shows)"
    if grep -q '^button\.' "$in/home.conf"; then
      dev "pm grant $HOME_PKG android.permission.READ_LOGS" >/dev/null
      note "remote button mappings back (READ_LOGS granted)"
    fi
    tunnel=$(sed -n 's/^vpn\.boot=//p' "$in/home.conf")
    [[ -n $tunnel ]] && note "WireGuard at boot was '$tunnel': import it (wg-import.sh), then ./opentelv/vpn.sh on $tunnel"
  fi
  if [[ -f $in/dumbtv.conf ]]; then
    if [[ ! -f $CONF ]]; then cp "$in/dumbtv.conf" "$CONF"; note "dumbtv.conf put back"
    elif ! cmp -s "$in/dumbtv.conf" "$CONF"; then note "dumbtv.conf differs from the backup; kept yours (the backup's is $in/dumbtv.conf)"
    fi
  fi
  if [[ -f $in/apps.txt ]]; then
    now=$(dev "pm list packages -3" | tr -d '\r' | sed 's/^package://' | sort)
    missing=$(comm -23 "$in/apps.txt" <(printf '%s\n' "$now"))
    keys=""
    while read -r k pkg _; do
      [[ -z ${k:-} || $k == \#* ]] && continue
      grep -qx "$pkg" <<<"$missing" && keys+=" $k"
    done < "$DIR/apps.txt"
    [[ -n $keys ]] && note "apps from the backup that are missing: ./opentelv/apps.sh$keys"
    other=$(grep -vxF -f <(awk '!/^#/ && NF {print $2}' "$DIR/apps.txt") <<<"$missing" | grep -v '^tv.dumbtv.home$' || true)
    [[ -n $other ]] && note "also missing (install by hand): $(echo $other)"
  fi
  ;;
esac
