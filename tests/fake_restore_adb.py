#!/usr/bin/env python3
"""A TV showing Android's restore confirmation, for tests/test_appdata.py.

Focus starts in the password field; TAB moves it to "Do not restore", then "Restore my
data". `adb restore` waits until the request is answered, or gives up after a few seconds
the way Android does after 60 s."""
import os
import sys
import time
from pathlib import Path

d = Path(os.environ['FAKE_DIR'])
focus, log, keys = d / 'focus', d / 'log', d / 'keys'
if not focus.exists():
    focus.write_text('enc_password')
args = sys.argv[1:]

if args[2] == 'restore':
    for _ in range(300):
        if (d / 'answered').exists():
            sys.exit(0)
        time.sleep(0.1)
    with log.open('a') as f:
        f.write('I BackupManagerService: Full backup/restore timed out waiting for user confirmation\n')
        f.write('I BackupManagerService: adb restore processing complete.\n')
    sys.exit(0)

cmd = ' '.join(args[3:])


def answer(how):
    with keys.open('a') as f:
        f.write(f'ALLOW by {how}\n')
    with log.open('a') as f:
        if not os.environ.get('REFUSED'):
            f.write('I BackupManagerService: Sig + version match; taking data\n')
        f.write('I BackupManagerService: adb restore processing complete.\n')
    (d / 'answered').touch()


if (d / 'answered').exists() and cmd == 'dumpsys window':
    print('  mCurrentFocus=Window{1 u0 tv.dumbtv.home/tv.dumbtv.home.Home}')
elif cmd.startswith('uiautomator dump'):
    print('<node resource-id="com.android.backupconfirm:id/button_allow" class="android.widget.Button" '
          'clickable="true" bounds="[960,984][1920,1080]" />')
elif cmd.startswith('input tap'):
    x, y = int(args[-2]), int(args[-1])
    if 960 <= x <= 1920 and 984 <= y <= 1080 and not os.environ.get('TAP_IGNORED'):
        answer('tap')
elif cmd == 'dumpsys window':
    print('  mCurrentFocus=Window{1 u0 com.android.backupconfirm/com.android.backupconfirm.BackupRestoreConfirmation}')
elif cmd == 'dumpsys activity top':
    for view in ('enc_password', 'button_deny', 'button_allow'):
        flags = '.F......' if focus.read_text() == view else '........'
        print(f'  android.widget.View{{1 VFED..C.. {flags} 0,0-1,1 #7f04 app:id/{view}}}')
elif cmd.startswith('input keyevent'):
    key = args[-1]
    with keys.open('a') as f:
        f.write(f'{key} {focus.read_text()}\n')
    if key == 'KEYCODE_TAB' and not os.environ.get('TAB_IGNORED'):
        order = ['enc_password', 'button_deny', 'button_allow']
        focus.write_text(order[min(order.index(focus.read_text()) + 1, 2)])
    if key == 'KEYCODE_DPAD_CENTER' and focus.read_text() == 'button_allow':
        answer('OK key')
elif cmd == 'logcat -d -s BackupManagerService':
    print(log.read_text() if log.exists() else '')
