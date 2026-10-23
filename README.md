# OpenTelV

**Make your Fire TV yours again: no ads, no tracking, your apps, your home screen,
your remote buttons.**

OpenTelV cleans Amazon Fire TV sticks, Cubes and Fire TV Edition televisions of ads,
tracking and clutter, then sets them up the way you want: a simple home screen, the
apps you use (kept up to date), YouTube without ads, and the remote's app buttons
pointing where you choose.

It runs over ADB from your computer. It doesn't need root, writes nothing to `/system`,
and every change can be undone.

> **Status:** early, and tested on one device so far (Fire TV Stick 4K Plus, Fire OS 8).
> OpenTelV is built on [dumbtv](https://github.com/humblemuzzu/dumbtv), the 2026
> project that started the "make your smart TV dumb again" trend; its cleanup is the
> first step here. OpenTelV's own tools live in [`opentelv/`](opentelv/README.md).

---

## Why this exists

In 2026 people started using AI coding agents to clean up their smart TVs: slow
menus, home screens full of sponsored rows, and services that report what you
watch. [TechCrunch](https://techcrunch.com/2026/10/19/people-are-using-ai-to-make-their-smart-tvs-dumb-again/),
[TechRadar](https://www.techradar.com/entertainment/streaming/your-tv-should-do-what-you-paid-for-people-are-vibe-coding-apps-to-banish-ads-from-their-smart-tvs-and-android-tv-and-its-catching-on)
and many others covered it. dumbtv turned one person's cleanup into scripts that are
safe to run on someone else's TV.

OpenTelV starts where the cleanup ends: getting a cleaned TV set up for daily use,
and making that setup repeatable on the next TV.

## What it does

| | |
|---|---|
| **Cleanup** (dumbtv) | Disables Amazon's ads, sponsored rows, screen fingerprinting (ACR), telemetry and update nags; an on-TV DNS filter blocks what cannot be disabled |
| **Home screen** | dumbtv home, rebuilt: a grid of four apps a line, a small clock, an **All apps** screen (hidden apps too, A to Z), no internet permission |
| **Apps** | One command installs the default set: Appstore apps keep auto-updating, the rest come from their official sources, checksum-checked |
| **YouTube** | SmartTube instead of the stock app: no ads, no Shorts |
| **Remote buttons** | The YouTube button opens SmartTube (or any app you pick) |
| **VPN mode** | Tailscale (with an exit node) or WireGuard as an always-on VPN, and back to the DNS filter with one command |
| **Undo** | Every step has one |

## Quick start

You need a computer with [`adb`](https://developer.android.com/tools/releases/platform-tools),
`bash` and `curl` (macOS, Linux, or Windows with WSL), on the same network as the TV.

**1. Turn on ADB on the TV.** Settings → My Fire TV → About, press OK on the device
name 7 times, then Settings → My Fire TV → Developer Options → ADB debugging. The IP
address is under Settings → My Fire TV → About → Network.

**2. Connect and look first** (changes nothing; saves a snapshot for undo):

```sh
git clone https://github.com/AdrielleU/opentelv && cd opentelv
adb connect <tv-ip>:5555        # press Allow on the TV, tick Always allow
./scripts/preflight.sh
```

Keep the `report/` folder it creates: `restore.sh` uses it to put your exact
settings back.

**3. Clean up** (dumbtv's pass; asks before each step, reboots the TV twice):

```sh
./scripts/configure.sh          # Prime Video? Alexa? DNS filter? SmartTube?
./scripts/all.sh
./scripts/verify.sh
```

On Fire OS 8 the DNS filter needs one setting made in its own app; `all.sh` prints
the steps, and [scrcpy](https://github.com/Genymobile/scrcpy) makes them easy
(details in [opentelv/README.md](opentelv/README.md)).

**4. Set it up** (OpenTelV):

```sh
./opentelv/home.sh                          # OpenTelV's home screen
./opentelv/apps.sh                          # the default apps
./opentelv/buttons.sh map --tag r_btn_app_33   # YouTube button → SmartTube
```

The default apps are Netflix, Disney+, HBO Max, Crunchyroll, Spotify, Wholphin,
Moonlight, Tailscale, WireGuard, Material Files and RustDesk (work in progress, see
below). `./opentelv/apps.sh --list` shows them, `--choose` asks about each.

**Optional:**

```sh
./opentelv/vpn.sh on tailscale              # always-on VPN; DNS blocking pauses
./opentelv/vpn.sh off                       # back to the DNS filter
./opentelv/wg-import.sh home.conf           # import a WireGuard tunnel
```

## Undo

```sh
./opentelv/vpn.sh off               # VPN mode → DNS filter
./opentelv/buttons.sh unmap --tag r_btn_app_33
./launcher/install.sh --undo        # HOME back to Amazon's home screen
./scripts/restore.sh                # the whole cleanup, from the report/ snapshot
```

A factory reset always removes everything OpenTelV did.

## Tested on

| Device | Fire OS | Result |
|---|---|---|
| Fire TV Stick 4K Plus (AFTMA08C15), build RS8185.3891N | 8 (Android 11) | cleanup, DNS filter, home screen, apps, YouTube button: working |

dumbtv's [device catalog](catalog/README.md) covers the cleanup on about twenty more
Fire TV models. OpenTelV's additions have not been tried on them yet; reports are
welcome.

## Work in progress

- **RustDesk** (remote desktop into the TV) installs, but control from another
  computer does not work well on Fire TV yet. It stays in the default set while we
  work on it; see [opentelv/README.md](opentelv/README.md#rustdesk-remote-into-the-tv-by-id-work-in-progress).
- **The Netflix button** cannot be remapped: Fire OS opens Netflix directly, without
  the log entry the other app buttons leave.

## Fire TV first

OpenTelV focuses on **Fire OS**: the one smart TV platform where owners get a real
shell through ADB, so everything here works without exploits. **Android TV / Google
TV comes later**, as its own folder in this project; the Android TV data inherited
from dumbtv (`data/androidtv/`, the `androidtv-*` catalog entries) stays as a starting
point. Samsung, LG, Roku and VIDAA give owners no shell, so they are out of scope
([why](docs/OTHER-TVS.md)).

## Roadmap

- [x] Fork dumbtv as the Fire TV base
- [x] Home screen: grid layout, All apps, small clock
- [x] App installer with a default set, Appstore auto-updates kept
- [x] Remote app buttons mapped to any app
- [x] VPN mode (Tailscale exit node, WireGuard) and WireGuard import
- [ ] RustDesk control that works on Fire TV
- [ ] Automate the Fire OS 8 DNS filter setting (today it is set by hand once)
- [ ] **TV images**: save a set-up TV as a plain-text file (packages, settings, DNS,
      home screen, apps, button mappings) and apply it to other Fire TVs, one or all on
      the network. Not a disk image: Fire OS cannot be replaced
      ([why](docs/WHY-NOT-REPLACE-OS.md))
- [ ] Community library of tested images per model
- [ ] **Later:** Android TV / Google TV, in its own folder

## Safety rules

These come from dumbtv and will not change:

1. **Never write to `/system`.** No `adb root`, no remount, no hosts-file edits.
2. **Never factory-reset the TV.**
3. **Never touch the core packages** in `data/fireos/never-disable.txt`: launcher,
   settings, inputs, tuner, remote pairing.
4. **Never remove an app the owner did not name.**
5. **Disable, never uninstall** Amazon packages, so everything can come back.

## Pulling dumbtv's updates

OpenTelV keeps dumbtv's files as they are upstream, except a few marked `OpenTelV` in
`launcher/`. To bring in dumbtv's fixes:

```sh
git remote add upstream https://github.com/humblemuzzu/dumbtv   # once
git fetch upstream && git merge upstream/main
```

## Documentation

| | |
|---|---|
| [opentelv/README.md](opentelv/README.md) | OpenTelV's tools: apps, home screen, buttons, VPN mode, WireGuard, RustDesk |
| [How it works](docs/HOW-IT-WORKS.md) | the cleanup's five layers: packages, settings, app-ops, DNS, launcher |
| [Troubleshooting](docs/TROUBLESHOOTING.md) | symptoms and fixes |
| [FAQ](docs/FAQ.md) | updates, Prime Video, factory reset, legality |
| [Why not replace the OS](docs/WHY-NOT-REPLACE-OS.md) | the locked boot chain |
| [Device catalog](catalog/README.md) | tested models and quirks |
| [Other TVs](docs/OTHER-TVS.md) | Android TV, Samsung, LG, Roku and the rest |
| [Launcher](launcher/README.md) | the home screen (dumbtv home) |
| [AGENTS.md](AGENTS.md) | instructions for coding agents (dumbtv's cleanup) |
| [Upstream README](docs/UPSTREAM-README.md) | dumbtv's own README |

## Credits

OpenTelV is built on [dumbtv](https://github.com/humblemuzzu/dumbtv) by Muzzammil
Yasin Sabuwala ([@humblemuzzu](https://github.com/humblemuzzu)) and its
contributors. It also relies on
[personalDNSfilter](https://github.com/IngoZenz/personaldnsfilter) by Ingo Zenz,
[HaGeZi's DNS blocklists](https://github.com/hagezi/dns-blocklists),
[SmartTube](https://github.com/yuliskov/SmartTube) by Yuriy Liskov and
[Material Files](https://github.com/zhanghai/MaterialFiles) by Hai Zhang. The remote
button approach follows [FireStick Fixer](https://github.com/Hornet34/firestick-fixer),
which documented it; OpenTelV's code is its own.

## Legal

OpenTelV changes settings on a device you own, using the developer tools Amazon
ships. It does not bypass DRM, unlock the bootloader or touch anyone's account. Fire
TV, Fire OS, Alexa and Prime Video are trademarks of Amazon. OpenTelV is not
affiliated with or endorsed by Amazon. Use it at your own risk.

## Licence

Scripts, docs and the launcher are [MIT](LICENSE), as inherited from dumbtv; keep the
original copyright notice. The device catalog is [CC BY-SA 4.0](catalog/LICENSE).
