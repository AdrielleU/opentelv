#!/usr/bin/env bash
# Switches Android's one VPN slot between the on-TV DNS filter (the default) and a
# VPN app. In VPN mode the disabled Amazon packages stay disabled; only the DNS
# blocking pauses, until `off` hands the slot back to the filter.
#
#   ./opentelv/vpn.sh on tailscale       VPN mode: the app starts at boot, the on-TV
#   ./opentelv/vpn.sh on wireguard       filter is switched off
#   ./opentelv/vpn.sh off                back to the on-TV filter (the default)
#   ./opentelv/vpn.sh check              are the Amazon hosts blocked right now?
#   ./opentelv/vpn.sh blocklist          optional: the OpenTelV list for a DNS server
#                                        (AdGuard Home, Pi-hole) behind the VPN
# Flags: --dry-run, -y
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib.sh"

FILTER=dnsfilter.android
# Same feed dnsfilter.sh builds the on-TV list from.
HAGEZI_URL=https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/wildcard/native.amazon-onlydomains.txt

cmd=${1:-}; shift || true
app=""
if [[ $cmd == on ]]; then app=${1:-}; shift || true; fi
parse_flags "$@"
load_conf

vpn_pkg() {
  case $1 in
    tailscale) echo com.tailscale.ipn ;;
    wireguard) echo com.wireguard.android ;;
    *) die "on what? tailscale or wireguard" ;;
  esac
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
  pkg=$(vpn_pkg "$app")
  need_device
  present "$pkg" || die "$app is not installed: ./opentelv/apps.sh $app"
  step "plan"
  note "$app holds the VPN slot and starts at boot (always-on VPN)"
  note "the on-TV filter ($FILTER) pauses: Amazon's DNS is not blocked in VPN mode"
  note "the disabled Amazon packages stay disabled; ./opentelv/vpn.sh off brings the filter back"
  [[ $app == tailscale ]] && note "Tailscale: Exit node > Allow LAN access must be on, or adb loses the TV"
  if [[ $DRY_RUN == 0 ]]; then confirm "Switch $SERIAL to $app?" || die "cancelled"; fi
  # Pre-granting the app-op skips the VPN consent box, which the remote cannot press.
  acmd appops set "$pkg" ACTIVATE_VPN allow >/dev/null
  acmd settings put secure always_on_vpn_app "$pkg" >/dev/null
  acmd settings put secure always_on_vpn_lockdown 0 >/dev/null
  # Disabling the filter app revokes its VPN, which frees the slot.
  acmd pm disable-user --user 0 "$FILTER" >/dev/null
  acmd monkey -p "$pkg" -c android.intent.category.LEANBACK_LAUNCHER 1 >/dev/null
  [[ $DRY_RUN == 1 ]] && exit 0
  adb_reconnect
  step "now"
  note "always-on VPN: $(dev1 settings get secure always_on_vpn_app)"
  note "connect $app on the TV (scrcpy) if it is not connected yet"
  note "back to the default: ./opentelv/vpn.sh off"
  ;;

off)
  need_device
  step "plan"
  note "back to the on-TV filter: $FILTER holds the VPN slot again"
  if [[ $DRY_RUN == 0 ]]; then confirm "Switch $SERIAL back to the on-TV filter?" || die "cancelled"; fi
  acmd pm enable --user 0 "$FILTER" >/dev/null
  acmd appops set "$FILTER" ACTIVATE_VPN allow >/dev/null
  acmd settings put secure always_on_vpn_app "$FILTER" >/dev/null
  acmd am start -n "$FILTER/.DNSProxyActivity" >/dev/null
  [[ $DRY_RUN == 1 ]] && exit 0
  adb_reconnect
  note "always-on VPN: $(dev1 settings get secure always_on_vpn_app)"
  note "the filter takes the slot from Tailscale/WireGuard; then: ./scripts/verify.sh"
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
  sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 1
  ;;
esac
