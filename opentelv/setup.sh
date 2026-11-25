#!/usr/bin/env bash
# OpenTelV's setup for a new Fire TV, after dumbtv's cleanup (./scripts/all.sh): the
# home screen, the default apps, the YouTube button, and optionally a WireGuard tunnel
# that comes up at every boot once the internet is connected.
#
#   ./opentelv/setup.sh                       home screen, apps, YouTube button
#   ./opentelv/setup.sh --vpn home.conf       the same, then import home.conf into
#                                             WireGuard and bring it up at every boot
#   --tag r_btn_app_33                        the YouTube button's tag (this is the
#                                             AFTMA08C15 remote's); --tag "" skips it
# Flags: --dry-run, -y (passed to every step)
set -uo pipefail
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$DIR/../scripts/lib.sh"

vpn_conf=""; tag=r_btn_app_33; flags=()
while [[ $# -gt 0 ]]; do
  case $1 in
    --vpn) vpn_conf=${2:-}; shift 2 || die "--vpn needs a WireGuard .conf" ;;
    --vpn=*) vpn_conf=${1#--vpn=}; shift ;;
    --tag) tag=${2-}; shift 2 || die "--tag needs a button tag (or \"\")" ;;
    --tag=*) tag=${1#--tag=}; shift ;;
    *) flags+=("$1"); shift ;;
  esac
done
parse_flags "${flags[@]+"${flags[@]}"}"
if [[ -n $vpn_conf ]]; then
  [[ -f $vpn_conf ]] || die "no such file: $vpn_conf"
  tunnel=$(basename "$vpn_conf"); tunnel=${tunnel%.conf}
fi
need_device

# bash 3.2 (macOS) errors on "${flags[@]}" when the array is empty under set -u.
run() { "$@" ${flags[@]+"${flags[@]}"}; }

step "1/4 home screen"
run "$DIR/home.sh" || exit 1

step "2/4 apps"
run "$DIR/apps.sh" || exit 1

step "3/4 YouTube button"
if [[ -z $tag ]]; then
  note "skipped (--tag \"\")"
elif ! present org.smarttube.stable; then
  note "skipped: SmartTube is not installed (./scripts/configure.sh --youtube 1, then ./scripts/youtube.sh)"
elif [[ $DRY_RUN == 1 ]]; then
  note "[dry-run] ./opentelv/buttons.sh map --tag $tag"
else
  run "$DIR/buttons.sh" map --tag "$tag" || exit 1
fi

step "4/4 VPN"
if [[ -z $vpn_conf ]]; then
  note "skipped; later: ./opentelv/setup.sh --vpn <tunnel.conf>, or wg-import.sh then vpn.sh on"
else
  note "while WireGuard is open for the import, also switch on (once):"
  note "  WireGuard > Settings > Allow remote control apps"
  run "$DIR/wg-import.sh" "$vpn_conf" || exit 1
  run "$DIR/vpn.sh" on "$tunnel" || exit 1
fi

[[ $DRY_RUN == 1 ]] || "$DIR/vpn.sh" status
