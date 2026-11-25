#!/usr/bin/env bash
# VPN mode: a WireGuard tunnel that comes up at boot, or Tailscale switched on by hand.
# Nothing is always-on: the home screen asks WireGuard for the tunnel once per boot,
# once the internet is connected (Wi-Fi or Ethernet), so switching it off in WireGuard
# (or using Tailscale) sticks.
#
#   ./opentelv/vpn.sh on [TUNNEL]        WireGuard brings TUNNEL up at every boot, and now
#                                        (TUNNEL: the name WireGuard shows; once set, kept)
#   ./opentelv/vpn.sh on tailscale       no tunnel at boot; switch Tailscale on in its app
#   ./opentelv/vpn.sh off                no VPN at boot; the DNS filter takes the slot back
#                                        if dumbtv.conf turns it on
#   ./opentelv/vpn.sh status [--debug]   what holds the slot, what starts at boot, what is up
#   ./opentelv/vpn.sh check              are the Amazon hosts blocked right now?
#   ./opentelv/vpn.sh blocklist          optional: the OpenTelV list for a DNS server
#                                        (AdGuard Home, Pi-hole) behind the VPN
# Flags: --dry-run, -y
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib.sh"

FILTER=dnsfilter.android
WG=com.wireguard.android
TS=com.tailscale.ipn
HOME_PKG=tv.dumbtv.home
# Same feed dnsfilter.sh builds the on-TV list from.
HAGEZI_URL=https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/wildcard/native.amazon-onlydomains.txt

cmd=${1:-}; shift || true
app=""; tunnel=""
if [[ $cmd == on ]]; then
  case ${1:-} in
    tailscale) app=tailscale; shift ;;
    wireguard) app=wireguard; shift ;;
    *) app=wireguard ;;
  esac
  if [[ $app == wireguard ]]; then
    case ${1:-} in -*|"") ;; *) tunnel=$1; shift ;; esac
  fi
fi
DEBUG=0; rest=()
for a in "$@"; do [[ $a == --debug ]] && DEBUG=1 || rest+=("$a"); done
parse_flags "${rest[@]+"${rest[@]}"}"
load_conf

# The home screen's boot-tunnel receiver (opentelv/home.sh 2026-11 or later).
# Captured first: under pipefail, grep -q quitting early fails a long dumpsys pipe.
home_has_vpn() {
  local info
  present "$HOME_PKG" || return 1
  info=$(dev "dumpsys package $HOME_PKG")
  grep -q 'CONTROL_TUNNELS' <<<"$info"
}
# Talks to it; prints "tunnel=<name> control=<granted|missing>".
home_vpn() {
  dev "am broadcast -n $HOME_PKG/.Vpn\\\$Set $*" | tr -d '\r' | sed -n 's/.*data="\(.*\)".*/\1/p'
}
boot_tunnel() { home_vpn | sed -n 's/^tunnel=\([^ ]*\).*/\1/p'; }
# Is a VPN up now? Prints what shows it, or nothing. Android's own list of networks
# first (any VPN app, whatever its interface is called), then the tunN interface, from
# whichever of ip / ifconfig this Fire OS lets adb read.
tun_up() {
  local out name
  out=$(dev 'dumpsys connectivity' | tr -d '\r' | grep 'NetworkAgentInfo' |
    grep -E 'ni\{VPN|Transports: VPN' | grep -v 'DISCONNECTED' | head -1)
  if [[ -n $out ]]; then
    name=$(grep -oE 'InterfaceName: [A-Za-z0-9_.-]+|iface: ?[A-Za-z0-9_.-]+' <<<"$out" | head -1 | sed 's/.*: *//')
    echo "VPN network${name:+ on $name}"; return
  fi
  out=$(dev 'ip -o link show 2>/dev/null; ip addr show 2>/dev/null; ifconfig 2>/dev/null' | tr -d '\r')
  name=$(grep -oE '(^|[: ])tun[0-9]+' <<<"$out" | head -1 | tr -d ': ')
  [[ -n $name ]] && echo "$name"
}

# Which app's VPN is running: Android names every VPN app's interface tunN, whatever the
# tunnel is called inside the app, so the interface name cannot tell.
vpn_owner() {
  local s
  s=$(dev "dumpsys activity services $WG" | tr -d '\r')
  grep -q 'VpnService' <<<"$s" && { echo WireGuard; return; }
  s=$(dev "dumpsys activity services $TS" | tr -d '\r')
  grep -qE 'IPNService|VpnService' <<<"$s" && echo Tailscale
}

# A command with a time limit. A tunnel that takes the home network leaves a network adb
# session hanging rather than refused, so waiting on it must give up. timeout(1) is GNU;
# macOS without coreutils runs the command unlimited.
limited() {
  local s=$1; shift
  if command -v timeout >/dev/null; then timeout "$s" "$@"
  elif command -v gtimeout >/dev/null; then gtimeout "$s" "$@"
  else "$@"; fi
}
alive() { [[ $(limited 10 "$ADB" -s "$SERIAL" shell echo ok 2>/dev/null </dev/null | tr -d '\r') == ok ]]; }

# adb lost the TV as the tunnel came up: exit 3, so update.sh can stop cleanly.
lan_lost() {
  note "adb lost the TV as '$1' came up. The tunnel carries all traffic, your home network"
  note "too (AllowedIPs = 0.0.0.0/0), so this computer, and the Fire TV remote app, cannot"
  note "reach the TV while it is on. Fix it once, on the TV with the remote:"
  note "  WireGuard > $1 > pencil (edit) > tick Exclude private IPs > save"
  note "then: adb connect <tv-ip>:5555 and ./opentelv/vpn.sh status"
  note "the tunnel at boot is already set; nothing else to run"
  exit 3
}

# Nobody keeps the VPN slot: no always-on app, and the filter (if any) stopped.
free_slot() {
  acmd settings delete secure always_on_vpn_app >/dev/null 2>&1
  acmd settings delete secure always_on_vpn_lockdown >/dev/null 2>&1
  # Disabling the filter app revokes its VPN, which frees the slot.
  if present "$FILTER"; then acmd pm disable-user --user 0 "$FILTER" >/dev/null; fi
}

case $cmd in
blocklist)
  # Two spellings of one list: plain domains (Pi-hole, NextDNS denylist) and
  # ||domain^ (AdGuard Home), which also blocks subdomains as the HaGeZi wildcard
  # list intends. Prime Video and Alexa follow dumbtv.conf, as on the TV.
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/opentelv-vpn.XXXXXX") || die "could not create a temp dir"
  trap 'rm -rf "$WORK"' EXIT
  fetch "$WORK/hagezi.txt" "$HAGEZI_URL" || die "could not download the tracker list"
  mkdir -p "$REPORT"
  compose_blocklist "$WORK/hagezi.txt" | tr -d '\r' | awk 'NF' | sort -u > "$REPORT/opentelv-blocklist.txt"
  sed 's/^/||/; s/$/^/' "$REPORT/opentelv-blocklist.txt" > "$REPORT/opentelv-blocklist.adguard.txt"
  step "blocklist"
  note "$(grep -c . "$REPORT/opentelv-blocklist.txt") hosts (prime=$PRIME alexa=$ALEXA)"
  note "AdGuard Home: Filters > Custom filtering rules, paste report/opentelv-blocklist.adguard.txt"
  note "Pi-hole / NextDNS denylist: report/opentelv-blocklist.txt"
  ;;

on)
  need_device
  if [[ $app == tailscale ]]; then
    present "$TS" || die "Tailscale is not installed: ./opentelv/apps.sh tailscale"
    step "plan"
    note "no WireGuard tunnel at boot; nothing is always-on, so Tailscale can take the slot"
    [[ $DNSFILTER == 1 ]] && note "the on-TV filter ($FILTER) pauses; ./opentelv/vpn.sh off brings it back"
    note "switch a WireGuard tunnel that is on now off first: one VPN at a time"
    note "Tailscale: Exit node > Allow LAN access must be on, or adb loses the TV"
    if [[ $DRY_RUN == 0 ]]; then confirm "Switch $SERIAL to Tailscale?" || die "cancelled"; fi
    # Pre-granting the app-op skips the VPN consent box, which the remote cannot press.
    acmd appops set "$TS" ACTIVATE_VPN allow >/dev/null
    if home_has_vpn; then
      [[ $DRY_RUN == 1 ]] && note "[dry-run] home screen: no tunnel at boot" || home_vpn --es tunnel "''" >/dev/null
    fi
    free_slot
    acmd monkey -p "$TS" -c android.intent.category.LEANBACK_LAUNCHER 1 >/dev/null
    [[ $DRY_RUN == 1 ]] && exit 0
    adb_reconnect
    step "now"
    note "switch Tailscale on in its app (scrcpy or the remote); it stays off after a reboot"
    exit 0
  fi

  present "$WG" || die "WireGuard is not installed: ./opentelv/apps.sh wireguard"
  home_has_vpn || die "the installed home screen cannot start a tunnel at boot; update it: ./opentelv/home.sh"
  [[ -n $tunnel ]] || tunnel=$(boot_tunnel)
  [[ -n $tunnel ]] || die "which tunnel? ./opentelv/vpn.sh on <name>, the name WireGuard shows (wg-import.sh names it after the file)"
  [[ $tunnel =~ ^[A-Za-z0-9_=+.-]{1,15}$ ]] || die "not a WireGuard tunnel name: $tunnel"
  step "plan"
  note "the home screen asks WireGuard for '$tunnel' at every boot, once the internet is connected"
  note "nothing is always-on: switching it off in WireGuard (or using Tailscale) sticks until the next boot"
  note "the tunnel needs Exclude private IPs ticked (WireGuard > $tunnel > pencil), or adb and the remote app lose the TV"
  [[ $DNSFILTER == 1 ]] && note "the on-TV filter ($FILTER) pauses; ./opentelv/vpn.sh off brings it back"
  if [[ $DRY_RUN == 0 ]]; then confirm "Bring '$tunnel' up on $SERIAL now and at every boot?" || die "cancelled"; fi
  # Pre-granting the app-op skips the VPN consent box, which the remote cannot press.
  acmd appops set "$WG" ACTIVATE_VPN allow >/dev/null
  # Lets WireGuard start its tunnel service from the background at boot.
  acmd dumpsys deviceidle whitelist +"$WG" >/dev/null
  acmd pm grant "$HOME_PKG" "$WG.permission.CONTROL_TUNNELS" >/dev/null
  free_slot
  if [[ $DRY_RUN == 1 ]]; then note "[dry-run] home screen: '$tunnel' at boot, and now"; exit 0; fi
  state=$(home_vpn --es tunnel "$tunnel" --ez now true)
  [[ $state == *control=granted* ]] || die "Fire OS refused WireGuard's CONTROL_TUNNELS for the home screen ($state)"
  step "now"
  note "waiting for the tunnel (up to a minute)"
  up=""
  for _ in $(seq 1 12); do
    sleep 5
    if ! alive; then
      if [[ $SERIAL == *:* ]]; then
        limited 10 "$ADB" disconnect "$SERIAL" >/dev/null 2>&1
        limited 10 "$ADB" connect "$SERIAL" >/dev/null 2>&1
      fi
      alive || lan_lost "$tunnel"
    fi
    up=$(tun_up); [[ -n $up ]] && break
  done
  if [[ -n $up ]]; then
    who=$(vpn_owner)
    note "tunnel up: $up${who:+ ($who)}; '$tunnel' comes back at every boot"
  else
    note "no tunnel yet. One-time step on the TV (scrcpy or the remote):"
    note "  WireGuard > Settings (gear / three dots) > Allow remote control apps: on"
    note "  then run ./opentelv/vpn.sh on again"
  fi
  note "if WireGuard's own Settings > Restore on boot is on, switch it off: it starts before the internet is connected"
  note "back to no VPN: ./opentelv/vpn.sh off"
  ;;

off)
  need_device
  step "plan"
  note "no tunnel at boot; nothing always-on"
  [[ $DNSFILTER == 1 ]] && note "the on-TV filter ($FILTER) takes the VPN slot again"
  note "a tunnel that is on now stays on until you switch it off in WireGuard (or reboot)"
  if [[ $DRY_RUN == 0 ]]; then confirm "Turn VPN mode off on $SERIAL?" || die "cancelled"; fi
  if home_has_vpn; then
    [[ $DRY_RUN == 1 ]] && note "[dry-run] home screen: no tunnel at boot" || home_vpn --es tunnel "''" >/dev/null
  fi
  acmd dumpsys deviceidle whitelist -"$WG" >/dev/null 2>&1
  acmd settings delete secure always_on_vpn_app >/dev/null 2>&1
  acmd settings delete secure always_on_vpn_lockdown >/dev/null 2>&1
  if [[ $DNSFILTER == 1 ]] && present "$FILTER"; then
    acmd pm enable --user 0 "$FILTER" >/dev/null
    acmd appops set "$FILTER" ACTIVATE_VPN allow >/dev/null
    acmd settings put secure always_on_vpn_app "$FILTER" >/dev/null
    acmd am start -n "$FILTER/.DNSProxyActivity" >/dev/null
  fi
  [[ $DRY_RUN == 1 ]] && exit 0
  adb_reconnect
  note "always-on VPN: $(dev1 settings get secure always_on_vpn_app)"
  [[ $DNSFILTER == 1 ]] && note "the filter has the slot again; then: ./scripts/verify.sh"
  ;;

status)
  need_device
  step "vpn"
  aon=$(dev1 settings get secure always_on_vpn_app); [[ $aon == null ]] && aon=""
  note "always-on app:  ${aon:-none}${aon:+ (holds the slot: other VPN apps are refused)}"
  if home_has_vpn; then
    b=$(boot_tunnel); note "at boot:        ${b:-nothing}${b:+ (WireGuard, once the internet is connected)}"
  else
    note "at boot:        nothing (the home screen has no boot tunnel: ./opentelv/home.sh)"
  fi
  up=$(tun_up); [[ -n $up ]] && who=$(vpn_owner) || who=""
  note "tunnel now:     ${up:-none}${who:+ ($who)}"
  [[ -n $up ]] && note "                (Android calls every VPN app's interface tunN; the name in the app differs)"
  if [[ $DEBUG == 1 ]]; then
    step "raw (--debug)"
    dev 'dumpsys connectivity' | tr -d '\r' | grep 'NetworkAgentInfo' | cut -c1-300
    dev 'ip -o link show 2>&1; ifconfig 2>&1' | tr -d '\r' | grep -iE 'tun|wg|denied|not found' || note "no tun/wg interface visible to adb"
    dev 'dumpsys package com.wireguard.android' | tr -d '\r' | grep -m1 versionName || note "WireGuard version not found"
  fi
  ;;

check)
  need_device
  step "dns"
  note "always-on VPN: $(dev1 settings get secure always_on_vpn_app)"
  fail=0
  while read -r h; do
    case $(dev "ping -c1 -W2 $h" | head -1) in
      *0.0.0.0*|*127.0.0.1*) printf '%-10s %-38s blocked\n' ok "$h" ;;
      *) printf '%-10s %-38s NOT BLOCKED\n' FAIL "$h"; fail=1 ;;
    esac
  done < <(expected_blocked)
  while read -r h; do
    case $(dev "ping -c1 -W2 $h" | head -1) in
      *0.0.0.0*|*127.0.0.1*) printf '%-10s %-38s WRONGLY BLOCKED\n' FAIL "$h"; fail=1 ;;
      *"unknown host"*|*"not known"*|*"cannot resolve"*|"") printf '%-10s %-38s does not resolve\n' FAIL "$h"; fail=1 ;;
      *) printf '%-10s %-38s resolves\n' ok "$h" ;;
    esac
  done < <(list_of "$DATA/blocklists/verify-allowed.txt")
  [[ $fail == 0 ]] && note "all checks passed" ||
    die "failures above (in VPN mode NOT BLOCKED is expected; ./opentelv/vpn.sh off restores blocking)"
  ;;

*)
  sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 1
  ;;
esac
