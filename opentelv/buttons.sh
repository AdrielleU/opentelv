#!/usr/bin/env bash
# Points a remote app button (YouTube, Netflix, Prime Video, ...) at another app, through
# OpenTelV's home screen (./opentelv/home.sh). You press the button once; the script reads
# its tag from the TV's log and hands the mapping to the home screen.
#
#   ./opentelv/buttons.sh map [package]   default org.smarttube.stable (SmartTube)
#   ./opentelv/buttons.sh unmap           the button goes back to Amazon's behaviour
#   --tag r_btn_app_33                    skip pressing: use a known tag (YouTube on
#                                         the AFTMA08C15 remote is r_btn_app_33,
#                                         Disney+ r_btn_app_12)
# Flags: -y
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib.sh"

HOME_PKG=tv.dumbtv.home
WAIT=${BUTTON_WAIT:-60}

cmd=${1:-}; shift || true
target=""
tag=""
args=()
for a in "$@"; do
  case $a in
    --tag=*) tag=${a#--tag=} ;;
    --tag) want_tag=1 ;;
    *) if [[ ${want_tag:-0} == 1 ]]; then tag=$a; want_tag=0; else args+=("$a"); fi ;;
  esac
done
set -- "${args[@]+"${args[@]}"}"
[[ -z $tag || $tag =~ ^r_btn_[A-Za-z0-9_]+$ ]] || die "not a button tag: $tag (like r_btn_app_33)"
if [[ $cmd == map ]]; then
  case ${1:-} in -*|"") target=org.smarttube.stable ;; *) target=$1; shift ;; esac
fi
[[ $cmd == map || $cmd == unmap ]] || { sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 1; }
parse_flags "$@"
need_device

present "$HOME_PKG" || die "OpenTelV's home screen is not installed: ./opentelv/home.sh"
# Captured first: under pipefail, grep -q quitting early fails a long dumpsys pipe.
info=$(dev "dumpsys package $HOME_PKG")
grep -q 'android.permission.READ_LOGS' <<<"$info" ||
  die "the installed home screen has no button support; update it: ./opentelv/home.sh"
[[ $cmd == unmap ]] || present "$target" || die "$target is not installed"

# Read-only access to the system log, where Fire OS records the button presses.
dev "pm grant $HOME_PKG android.permission.READ_LOGS" >/dev/null
info=$(dev "dumpsys package $HOME_PKG")
grep -q 'android.permission.READ_LOGS: granted=true' <<<"$info" ||
  die "Fire OS refused READ_LOGS for $HOME_PKG"
note "READ_LOGS granted to the home screen"

if [[ -z $tag ]]; then
step "press the button"
note "press the remote button you want to $( [[ $cmd == map ]] && echo "point at $target" || echo "reset" ) (within ${WAIT}s)"
# Only presses from now on (-T 1). Every buffer and any line with the tag: the script
# only needs the tag here; which lines count as a press is the home screen's decision.
# timeout(1) is GNU; macOS without coreutils waits until a press instead.
limit=()
if command -v timeout >/dev/null; then limit=(timeout "$WAIT"); elif command -v gtimeout >/dev/null; then limit=(gtimeout "$WAIT"); fi
# </dev/null: adb reads the terminal, and under timeout it runs in the background,
# where a terminal read stops it (SIGTTIN) before it prints a single line.
tag=$("${limit[@]+"${limit[@]}"}" "$ADB" -s "$SERIAL" logcat -b all -v brief -T 1 </dev/null 2>/dev/null |
      grep --line-buffered -E 'clickStreamReftag=r_btn_' |
      head -1 | sed -n 's/.*clickStreamReftag=\(r_btn_[A-Za-z0-9_]*\).*/\1/p')
[[ -n $tag ]] || die "no app button press seen in ${WAIT}s. To see what the TV logs instead:
  adb logcat -c; adb logcat -b all -v brief | grep -iE 'r_btn|clickStream|START u0|venezia'
  then press the button"
note "that button is $tag"
fi

if [[ $cmd == map ]]; then
  confirm "Map $tag to $target?" || die "cancelled"
  pkg=$target
else
  pkg=""
fi
out=$(dev "am broadcast -n $HOME_PKG/.Buttons\\\$Map --es tag $tag --es pkg '$pkg'")
grep -q 'result=1' <<<"$out" || die "the home screen did not take the mapping: $out"
step "done"
if [[ $cmd == map ]]; then
  note "$tag now opens $target; press it to try (Back returns to the home screen)"
else
  note "$tag is back to Amazon's behaviour"
fi
