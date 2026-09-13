#!/usr/bin/env python3
"""Install the research plugin into the official APK's external plugin directory."""
from pathlib import Path
import json
import os
import subprocess
import time

root = Path('/var/tmp/bili-android-emulator-20260912')
adb = root / 'sdk/platform-tools/adb'
environment = dict(os.environ, ADB_SERVER_SOCKET='tcp:127.0.0.1:5038')
serial = 'emulator-5580'
plugin = '/sdcard/koreader/plugins/bili-native-probe.koplugin'
variant = os.environ.get('BILI_NATIVE_PROBE_VARIANT', 'external')
assert variant in {'external', 'private', 'fd', 'storage', 'production'}
probe_name = {
    'external': 'native-android-plugin-main.lua',
    'private': 'native-android-private-plugin-main.lua',
    'fd': 'native-android-fd-plugin-main.lua',
    'storage': 'native-android-storage-plugin-main.lua',
    'production': 'native-android-production-plugin-main.lua',
}[variant]


def command(*args, check=True):
    result = subprocess.run([str(adb), '-P', '5038', '-s', serial, *map(str, args)],
                            env=environment, text=True, capture_output=True, timeout=60)
    if check and result.returncode:
        raise RuntimeError(result.stdout + result.stderr)
    return result


command('shell', 'am', 'force-stop', 'org.koreader.launcher')
command('shell', 'mkdir', '-p', plugin + '/native')
inputs = {
    '/var/tmp/bili-android-emulator-plan-20260912/' + probe_name: plugin + '/main.lua',
    '/var/tmp/bili-android-ndk-20260912/host-build/android-x86/libbiliwasm.so': plugin + '/native/libbiliwasm.so',
    '/tmp/bili-portable-crypto-20260912/final-matrix/android-x86/libbilicrypto.so': plugin + '/native/libbilicrypto.so',
    '/tmp/bili-crypto-research-20260912/efae82c96a7eef44bee5.wasm': plugin + '/sign.wasm',
}
for source, destination in inputs.items():
    command('push', source, destination)
if variant == 'production':
    snapshot = Path(os.environ.get('BILI_NATIVE_PRODUCTION_SNAPSHOT', str(root / 'production-snapshot')))
    command('push', snapshot / 'bilicomics', plugin + '/')
    cache_mode = os.environ.get('BILI_NATIVE_CACHE_MODE', 'reuse')
    assert cache_mode in {'cold', 'reuse'}
    mode_file = root / 'probe-cache-mode.txt'
    mode_file.write_text(cache_mode)
    command('push', mode_file, plugin + '/probe-cache-mode.txt')
    command('shell', 'mkdir', '-p', plugin + '/assets')
    command('push', '/tmp/bili-crypto-research-20260912/efae82c96a7eef44bee5.wasm',
            plugin + '/assets/efae82c96a7eef44bee5.wasm')
    command('push', '/tmp/bili-crypto-research-20260912/image-golden-fixture.json',
            plugin + '/image-golden-fixture.json')
command('shell', 'appops', 'set', 'org.koreader.launcher', 'MANAGE_EXTERNAL_STORAGE', 'allow')
command('shell', 'rm', '-f', '/sdcard/koreader/bili-native-probe.json')
launch = command('shell', 'am', 'start', '-W', '-n', 'org.koreader.launcher/.MainActivity')
(root / 'probe-launch.txt').write_text(launch.stdout + launch.stderr)
for _ in range(30):
    result = command('shell', 'cat', '/sdcard/koreader/bili-native-probe.json', check=False)
    if result.returncode == 0:
        report = json.loads(result.stdout)
        if report.get('phase') == 'complete':
            (root / ('native-plugin-probe-' + variant + '.json')).write_text(json.dumps(report, indent=2) + '\n')
            print(json.dumps(report, indent=2))
            break
    time.sleep(1)
else:
    logcat = command('logcat', '-d', '-v', 'brief', check=False)
    (root / 'probe-logcat.txt').write_text(logcat.stdout + logcat.stderr)
    print('The plugin report was not completed within 30 seconds; inspect probe-logcat.txt')
    raise SystemExit(1)
