# opentelv/

OpenTelV's own additions. Everything outside this folder (and the top-level
README) is [dumbtv](https://github.com/humblemuzzu/dumbtv), kept as it is upstream
so its fixes merge in cleanly.

## Apps

```sh
./opentelv/apps.sh --list                 # what it can install
./opentelv/apps.sh                        # the default set: every app below that is missing
./opentelv/apps.sh --choose               # asks about each missing app instead
./opentelv/apps.sh spotify moonlight      # just these
./opentelv/apps.sh --dry-run rustdesk     # show the plan, change nothing
```

| Key | App | Source | Updates |
|---|---|---|---|
| `netflix` | Netflix | Amazon Appstore | Appstore, automatic |
| `disneyplus` | Disney+ | Amazon Appstore | Appstore, automatic |
| `hbomax` | HBO Max | Amazon Appstore | Appstore, automatic |
| `crunchyroll` | Crunchyroll | Amazon Appstore | Appstore, automatic |
| `spotify` | Spotify | Amazon Appstore | Appstore, automatic |
| `wholphin` | Wholphin (Jellyfin client) | Amazon Appstore | Appstore, automatic |
| `moonlight` | Moonlight (game streaming from a PC running Sunshine) | Amazon Appstore | Appstore, automatic |
| `tailscale` | Tailscale | pkgs.tailscale.com (not in every Fire TV Appstore), checksum-checked | run `apps.sh tailscale` again: it upgrades |
| `wireguard` | WireGuard | download.wireguard.com (not in the Appstore) | the app's own updater |
| `files` | [Material Files](https://github.com/zhanghai/MaterialFiles) (the file picker WireGuard import needs) | pinned GitHub release, checksum-checked | bump the pin in `apps.sh`, run again |
| `rustdesk` | RustDesk (remote desktop into the TV; **work in progress**) | pinned GitHub release, checksum-checked | bump the pin in `apps.sh`, run again |

For Appstore apps the script opens the app's store page on the TV and presses
**Get** itself, as the remote would (it finds the button on screen and taps it). If
it cannot, or the page shows a price, it leaves the press to you. Amazon has no
install command: the install is a free "purchase" on your account, made by the
Appstore, and that is what keeps the app on automatic updates. Turn those on once: **Settings › Applications › Appstore ›
Automatic Updates**.

WireGuard's APK is checked against the SHA-256 in WireGuard's signed `latest.sig`
manifest before it is installed.

To add an app, add a line to [`apps.txt`](apps.txt). Any Appstore app works with
`appstore` as its source; the package name is in `adb shell pm list packages -3` on
a TV that has it, or in the app's Play Store URL.

### VPN mode: Tailscale exit node or WireGuard

Android has one VPN slot, and by default dumbtv's DNS filter holds it. VPN mode
hands the slot to Tailscale or WireGuard; `off` hands it back.

```sh
./opentelv/vpn.sh on tailscale  # Tailscale holds the slot, starts at boot
./opentelv/vpn.sh on wireguard  # or the backup
./opentelv/vpn.sh off           # back to the default: the on-TV filter
```

| | Default | VPN mode |
|---|---|---|
| Amazon ad, tracking and update packages | disabled | disabled |
| Protected packages (no background, no data) | yes | yes |
| DNS blocking of Amazon hosts | on | **paused** |
| Traffic | your network | through the VPN / exit node |

Before the first `on tailscale`, sign in to Tailscale on the TV with scrcpy and turn
on **Exit node › Allow LAN access** *before* picking the exit node. Without it, adb,
scrcpy, RustDesk by IP and Moonlight at home all lose the TV (`adb connect` to the
TV's Tailscale IP still works).

`./scripts/verify.sh` reports `vpn` and the blocked hosts as failures in VPN mode;
that is expected. Streaming apps may refuse commercial VPN exit IPs; an exit node at
home or on your own PC is usually fine.

Optional, later: to keep DNS blocking in VPN mode too, run AdGuard Home or Pi-hole
behind the VPN and set it as the VPN's DNS; `./opentelv/vpn.sh blocklist` writes the
OpenTelV list for it.

### WireGuard tunnels

Fire OS has no system file picker, so WireGuard's **Import from file** needs a file
manager; `apps.sh files` installs [Material Files](https://github.com/zhanghai/MaterialFiles)
(open source, on Google Play and F-Droid, installed here from its GitHub release so
no Appstore region lock applies). Then:

```sh
./opentelv/wg-import.sh home.conf
```

It copies the file to the TV's Download folder and opens WireGuard. With the
remote: **+ › Import from file or archive › Download › home.conf**. Press Enter on
the computer and the copy is deleted (it holds the private key; it is also deleted
if you press Ctrl+C). The file name becomes the tunnel name: 15 characters at most.

To create or change a tunnel without a file, use WireGuard's own screens with the
remote: **+ › Create from scratch**, or open a tunnel and press the pencil icon.

### RustDesk: remote into the TV by ID (work in progress)

**Work in progress: control from another computer does not work well on Fire TV yet.**
It stays installed and in the default set while we work on it. RustDesk's Android app normally "connects but cannot
control" on a Fire TV ([rustdesk#9571](https://github.com/rustdesk/rustdesk/discussions/9571)):
it asks for screen capture with a consent box and for input through Accessibility
settings, both touch-only. `apps.sh` grants both over adb instead:

- `appops set com.carriez.flutter_hbb PROJECT_MEDIA allow`: no consent box
- its `InputService` added to `enabled_accessibility_services`, next to dumbtv
  home's Guard (which keeps HOME working)

Then, once, with scrcpy (the app's screens do not work with the remote): open
RustDesk, **Share screen › Start service**, note the **ID**, set a **permanent
password**, and turn on **Start on boot**. From any computer or phone with RustDesk,
enter that ID and password.

**By IP address on the home network** (no ID, no relay): in RustDesk on the TV,
**Settings › Screen sharing › Direct IP access** on (port 21118), and set the **IP
whitelist** to your network: the TV's address with the last number as `0/24`. From a computer on the same
network, type the TV's IP into RustDesk's ID box. `apps.sh` prints both values for
your TV. Never forward port 21118 on the router; away from home, use the TV's
Tailscale IP (`100.x.y.z`) instead. RustDesk keeps these settings in
its private storage, which adb cannot write on Fire OS 8, so they are set once by
hand.

Limits: the TV must be on (not in standby), and ID sessions go through RustDesk's
public relay unless you run your own server. Anyone with the ID and password
controls the TV, so use a long password. Re-run `./opentelv/apps.sh rustdesk` if
control stops after a Fire OS settings reset: it re-applies the grants.

If you only need remote control from your own computer, scrcpy over
`adb connect` does the same with no extra app on the TV.

## Home screen

OpenTelV builds dumbtv home with small layout changes:

- **Grid by default, four tiles a line.** Options › **Grid columns** (new) picks 3–6
  or "As many as fit"; Options › Layout › Rows brings back the single strip.
- **Smaller clock and date**, the size of the Options and Settings buttons.
- **All apps** (left of Options): every installed app, hidden ones dimmed, strictly A
  to Z by the name on its tile. OK opens one; hold OK to show it on, or hide it from,
  the home screen.

- **Remote app buttons** can open another app, such as the YouTube button opening
  SmartTube (see below).

```sh
./opentelv/home.sh              # install it (the APK in opentelv/home/; no SDK needed)
./launcher/install.sh --undo    # hand HOME back to Amazon
```

`home.sh` checks the APK against `opentelv/home/opentelv-home.apk.sha256` and
refuses to install on a mismatch or a missing checksum; `home.sh build` writes both,
and they are committed together.

dumbtv's release is signed with dumbtv's key, this build with OpenTelV's, and Android
will not update one with the other. The first `home.sh` removes the installed copy,
so dumbtv home's own settings (order, names, hidden tiles) reset once.

To change the layout: edit `launcher/src/`, then `./opentelv/home.sh build` (JDK 17
and the Android SDK; the build machine keeps them in `~/.local/opentelv-toolchain`).
**Back up `launcher/release.keystore`**: it is the signing key, git ignores it, and a
build signed with any other key cannot update the one on the TV.

The changed upstream files are `launcher/src/tv/dumbtv/home/{Config,Grid,Guard,Home}.java`,
`launcher/AndroidManifest.xml` and one line in `launcher/install.sh`, each marked
`OpenTelV` (`AllApps.java` and `Buttons.java` are new); a dumbtv update that
touches them may need a hand merge.

### Remote app buttons

Fire OS handles the YouTube, Netflix, Prime Video and Disney+ buttons itself; no app
sees the key. It does log each press (an Appstore start tagged `r_btn_app_NN`, even
when the button's app is not installed), and the home screen can follow that log:

```sh
./opentelv/buttons.sh map                      # press YouTube when asked: opens SmartTube
./opentelv/buttons.sh map --tag r_btn_app_33   # same, without pressing (YouTube on this remote)
./opentelv/buttons.sh map com.netflix.ninja    # or any installed package
./opentelv/buttons.sh unmap                    # press the button to reset it
```

The script grants the home screen `READ_LOGS` (read-only; nothing leaves the TV, the
app has no internet permission), reads which tag the button you press carries, and
stores `button.<tag>=<package>` in the home screen's settings. Opening the same app
from the home screen is never redirected: only button presses carry the tag. Back from
the mapped app returns to the home screen.

Needs OpenTelV's home screen (`./opentelv/home.sh`). The approach follows
[FireStick Fixer](https://github.com/Hornet34/firestick-fixer), which documents it on
this stick (AFTMA08C15, Fire OS 8); OpenTelV's code is its own.

## Pulling dumbtv updates

Commit your own work first, then (the `upstream` remote is added once):

```sh
git remote add upstream https://github.com/humblemuzzu/dumbtv   # once
git fetch upstream
git merge upstream/main
```

Conflicts can only come from files both sides changed. Keep OpenTelV changes in
this folder and they will not.
