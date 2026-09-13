#!/usr/bin/env python3
"""Fetch and verify the pinned Android NDK on the authorized remote build host."""
from pathlib import Path
import hashlib
import json
import shutil
import subprocess
import time
import urllib.request
import xml.etree.ElementTree as ET
import zipfile

root = Path('/var/tmp/bili-android-ndk-20260912')
root.mkdir(parents=True, exist_ok=True)
repository_url = 'https://dl.google.com/android/repository/repository2-3.xml'
archive_url = 'https://dl.google.com/android/repository/android-ndk-r27c-linux.zip'
revision = '27.2.12479018'
archive_path = root / 'android-ndk-r27c-linux.zip'
ndk_path = root / 'android-ndk-r27c'
repository = urllib.request.urlopen(repository_url, timeout=60).read()
(root / 'official-repository.xml').write_bytes(repository)
tree = ET.fromstring(repository)
package = next(node for node in tree.iter()
               if node.tag.endswith('remotePackage') and node.get('path') == 'ndk;' + revision)
archives = next(node for node in package if node.tag.endswith('archives'))
linux_archive = next(node for node in archives
                     if next(child.text for child in node if child.tag.endswith('host-os')) == 'linux')
complete = next(node for node in linux_archive if node.tag.endswith('complete'))
size = int(next(node.text for node in complete if node.tag.endswith('size')))
sha1 = next(node.text for node in complete if node.tag.endswith('checksum'))
assert size == 663987688 and sha1 == '090e8083a715fdb1a3e402d0763c388abb03fb4e'
assert shutil.disk_usage(root).free > size + 256 * 1024 * 1024
started = time.monotonic()
if not archive_path.exists() or archive_path.stat().st_size != size:
    downloaded = 0
    next_report = 32 * 1024 * 1024
    with urllib.request.urlopen(archive_url, timeout=60) as response, archive_path.open('wb') as output:
        while True:
            chunk = response.read(4 * 1024 * 1024)
            if not chunk:
                break
            output.write(chunk)
            downloaded += len(chunk)
            if downloaded >= next_report:
                print(json.dumps({'downloaded_bytes': downloaded, 'total_bytes': size}), flush=True)
                next_report += 32 * 1024 * 1024
assert archive_path.stat().st_size == size
actual_sha1 = hashlib.sha1()
sha256 = hashlib.sha256()
with archive_path.open('rb') as source:
    while chunk := source.read(4 * 1024 * 1024):
        actual_sha1.update(chunk)
        sha256.update(chunk)
assert actual_sha1.hexdigest() == sha1, 'The official NDK checksum does not match'
with zipfile.ZipFile(archive_path) as archive:
    expanded_size = sum(info.file_size for info in archive.infolist())
    for info in archive.infolist():
        destination = (root / info.filename).resolve()
        assert destination.is_relative_to(root.resolve()), 'Archive entry escapes the isolated workspace'
assert shutil.disk_usage(root).free > expanded_size + 256 * 1024 * 1024
subprocess.run(['unzip', '-q', '-o', str(archive_path), '-d', str(root)], check=True)
properties = (ndk_path / 'source.properties').read_text()
assert revision in properties
result = {
    'repository_url': repository_url,
    'archive_url': archive_url,
    'ndk_revision': revision,
    'ndk_release': 'r27c',
    'archive_bytes': size,
    'expanded_bytes': expanded_size,
    'official_sha1': sha1,
    'computed_sha256': sha256.hexdigest(),
    'checksum_verification': 'Official HTTPS repository SHA-1 matched; SHA-256 additionally recorded',
    'ndk_path': str(ndk_path),
    'elapsed_seconds': round(time.monotonic() - started, 3),
}
(root / 'verified-ndk.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result, indent=2), flush=True)
