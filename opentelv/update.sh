#!/usr/bin/env bash
# Installs a Fire OS update on purpose, then puts OpenTelV back on its own.
#
# The cleanup keeps Amazon's updater from running in the background (lockdown.sh) and,
# with the DNS filter on, from reaching the update servers, so an update started from
# Settings stalls at "Installing". This lets the updater run, opens the update screen,
# waits for the TV to come back on a new build, then re-applies the cleanup and your
# setup: disabled packages, the updater blocked again, the DNS filter (if on), the home
# screen, remote buttons and the WireGuard tunnel at boot.
#
#   ./opentelv/update.sh            backup, update, re-apply (asks once, then runs alone)
#   ./opentelv/update.sh --after    only re-apply: the TV updated some other way
#   ./opentelv/update.sh --unlock   only let the updater run; re-apply later with --after
# Flags: --dry-run, -y
set -uo pipefail
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$DIR/../scripts/lib.sh"

UPDATERS="com.amazon.device.software.ota com.amazon.device.software.ota.override com.amazon.diode"
FORCED=com.amazon.tv.forcedotaupdater.v2
FILTER=dnsfilter.android
HOME_PKG=tv.dumbtv.home
WAIT_MIN=${UPDATE_WAIT_MIN:-90}

mode=full; args=()
for a in "$@"; do
  case $a in
    --after) mode=after ;;
    --unlock) mode=unlock ;;
    *) args+=("$a") ;;
  esac
done
parse_flags "${args[@]+"${args[@]}"}"
load_conf
need_device

# Children run unattended once the owner said yes here.
child=(-y); [[ $DRY_RUN == 1 ]] && child+=(--dry-run)

build() { dev1 getprop ro.build.fingerprint; }

unlock() {
  step "let the updater run"
  for p in $UPDATERS; do
    present "$p" || continue
    bg_on "$p"
    uid=$(uid_of "$p")
    [[ -n $uid ]] && acmd cmd netpolicy remove restrict-background-blacklist "$uid" >/dev/null 2>&1
    note "$p: may run in the background"
  done
  if present "$FORCED"; then acmd pm enable "$FORCED" >/dev/null 2>&1; note "$FORCED: enabled"; fi
  # The filter blocks the update servers; dnsfilter.sh turns it back on afterwards.
  if [[ $DNSFILTER == 1 ]] && present "$FILTER"; then
    acmd pm disable-user --user 0 "$FILTER" >/dev/null 2>&1
    note "DNS filter paused for the update"
  fi
}

# Every step is safe to repeat; each puts back what an update resets.
reapply() {
  step "re-apply OpenTelV"
  "$ROOT/scripts/debloat.sh" "${child[@]}" --no-reboot || die "debloat.sh failed; run it again by hand"
  "$ROOT/scripts/lockdown.sh" "${child[@]}" || die "lockdown.sh failed; run it again by hand"
  if [[ $DNSFILTER == 1 ]]; then "$ROOT/scripts/dnsfilter.sh" "${child[@]}" --no-reboot || die "dnsfilter.sh failed"; fi
  if present "$HOME_PKG"; then
    # home.sh installs even under --dry-run, so a dry run only names it.
    if [[ $DRY_RUN == 1 ]]; then note "[dry-run] ./opentelv/home.sh -y"
    else "$DIR/home.sh" "${child[@]}" || die "home.sh failed; run it again by hand"; fi
    info=$(dev "dumpsys package $HOME_PKG")
    if grep -q 'android.permission.READ_LOGS' <<<"$info"; then
      acmd pm grant "$HOME_PKG" android.permission.READ_LOGS >/dev/null
      note "remote buttons: READ_LOGS granted again"
    fi
    tunnel=$(dev "am broadcast -n $HOME_PKG/.Vpn\\\$Set" | tr -d '\r' | sed -n 's/.*tunnel=\([^ "]*\).*/\1/p')
    if [[ -n $tunnel ]]; then "$DIR/vpn.sh" on "$tunnel" "${child[@]}" || note "vpn.sh on $tunnel failed; run it again by hand"; fi
  elif [[ $LAUNCHER == 1 ]]; then
    "$ROOT/scripts/launcher.sh" "${child[@]}" || die "launcher.sh failed"
  fi
  [[ $DRY_RUN == 1 ]] && return 0
  step "reboot"
  dev "reboot" >/dev/null 2>&1
  wait_back 15 || die "the TV did not come back after the reboot; then: ./scripts/verify.sh"
  "$ROOT/scripts/verify.sh" || note "verify.sh reported problems above; ./opentelv/update.sh --after runs this part again"
}

# Waits for adb to answer again, reconnecting over the network; $1 minutes at most.
wait_back() {
  local end=$(( $(date +%s) + $1 * 60 ))
  sleep 20
  while (( $(date +%s) < end )); do
    [[ $SERIAL == *:* ]] && "$ADB" connect "$SERIAL" >/dev/null 2>&1
    if [[ $("$ADB" -s "$SERIAL" get-state 2>/dev/null) == device ]] &&
       [[ $(dev1 getprop sys.boot_completed) == 1 ]]; then
      sleep 20; return 0
    fi
    sleep 15
  done
  return 1
}

case $mode in
unlock)
  [[ $DRY_RUN == 1 ]] || confirm "Let Amazon's updater run on $SERIAL?" || die "cancelled"
  unlock
  note "Settings > My Fire TV > About > Check for Updates; afterwards: ./opentelv/update.sh --after"
  exit 0 ;;
after)
  [[ $DRY_RUN == 1 ]] || confirm "Re-apply OpenTelV on $SERIAL?" || die "cancelled"
  reapply
  exit 0 ;;
esac

before=$(build)
step "plan"
note "now:  $(dev1 getprop ro.build.version.name)"
note "1. back up your settings and button mappings (./opentelv/backup.sh)"
note "2. let Amazon's updater run, and open the update screen on the TV"
note "3. you pick Check for Updates / Install on the TV; this waits up to $WAIT_MIN minutes"
note "4. when the TV is back on a new build: re-apply OpenTelV, reboot, verify"
if [[ $DRY_RUN == 0 ]]; then confirm "Update $SERIAL and re-apply OpenTelV afterwards?" || die "cancelled"; fi

"$DIR/backup.sh" "update-$(date +%Y-%m-%d_%H%M)" "${child[@]}" || die "backup failed; nothing changed"
unlock
if [[ $DRY_RUN == 1 ]]; then reapply; exit 0; fi

step "update on the TV"
# Fire OS has no public intent for its update screen on every build; About is close.
dev "input keyevent KEYCODE_WAKEUP" >/dev/null
if ! dev "am start -a android.settings.SYSTEM_UPDATE_SETTINGS" | grep -qi error; then
  note "the update screen is open on the TV"
else
  dev "am start -a android.settings.DEVICE_INFO_SETTINGS" >/dev/null
fi
note "on the TV: Settings > My Fire TV > About > Check for Updates, then Install"
note "the TV restarts by itself while installing; leave it plugged in"
note "waiting for a new Fire OS build (up to $WAIT_MIN min; Ctrl+C is safe, then --after later)"

end=$(( $(date +%s) + WAIT_MIN * 60 )); last=0
while (( $(date +%s) < end )); do
  [[ $SERIAL == *:* ]] && "$ADB" connect "$SERIAL" >/dev/null 2>&1
  if [[ $("$ADB" -s "$SERIAL" get-state 2>/dev/null) == device ]] &&
     [[ $(dev1 getprop sys.boot_completed) == 1 ]]; then
    now=$(build)
    if [[ -n $now && $now != "$before" ]]; then
      note "updated: $(dev1 getprop ro.build.version.name)"
      sleep 30  # the first minutes after an update are busy
      reapply
      exit 0
    fi
  fi
  if (( $(date +%s) - last >= 300 )); then
    last=$(date +%s); note "still waiting ($(( (end - last) / 60 )) min left)"
  fi
  sleep 20
done
note "no new build after $WAIT_MIN minutes"
note "if the TV said it is up to date: ./opentelv/update.sh --after puts the cleanup back"
note "if it is still installing: wait, then ./opentelv/update.sh --after"
exit 1
