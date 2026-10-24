#!/usr/bin/env python3
"""Stage a pinned upstream Fossil executable for an installation bundle."""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import struct
import tarfile
import tempfile
import urllib.request


def matches_platform(binary, target):
    if target.startswith("linux-"):
        machine = {"linux-x86_64": 62, "linux-aarch64": 183}[target]
        valid = len(binary) >= 64 and binary[:6] == b"\x7fELF\x02\x01" and struct.unpack_from("<H", binary, 18)[0] == machine
    else:
        machine = {"macos-x86_64": 0x1000007, "macos-aarch64": 0x100000C}[target]
        valid = len(binary) >= 32 and binary[:4] == b"\xcf\xfa\xed\xfe" and struct.unpack_from("<I", binary, 4)[0] == machine
    return valid


def stage(archive, expected, target, output):
    if hashlib.sha256(archive).hexdigest() != expected["archive_sha256"]:
        raise ValueError("Fossil archive hash mismatch")
    with tarfile.open(fileobj=io.BytesIO(archive), mode="r:gz") as source:
        members = source.getmembers()
        if len(members) != 1 or members[0].name != "fossil" or not members[0].isfile():
            raise ValueError("Unexpected Fossil archive entries")
        if members[0].size != expected["binary_bytes"] or members[0].size > 40 * 1024 * 1024:
            raise ValueError("Fossil executable size mismatch")
        binary = source.extractfile(members[0]).read()
    if hashlib.sha256(binary).hexdigest() != expected["binary_sha256"]:
        raise ValueError("Fossil executable hash mismatch")
    if not matches_platform(binary, target):
        raise ValueError("Fossil executable platform mismatch")
    output.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".fossil-stage-", dir=output.parent)
    try:
        with os.fdopen(descriptor, "wb") as file:
            file.write(binary)
            file.flush()
            os.fchmod(file.fileno(), 0o755)
            os.fsync(file.fileno())
        os.replace(temporary, output)
        directory = os.open(output.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        Path(temporary).unlink(missing_ok=True)
    return {"sha256": expected["binary_sha256"], "bytes": len(binary), "platform": target}


def main():
    root = Path(__file__).resolve().parent.parent
    lock = json.loads((root / "scripts/fossil-helper.lock.json").read_text())
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", required=True, choices=sorted(lock["platforms"]))
    parser.add_argument("--archive", type=Path, help="Use an already downloaded, hash-verified archive")
    parser.add_argument("--output", type=Path, default=root / "zig-out/libexec/fossil")
    args = parser.parse_args()
    expected = lock["platforms"][args.platform]
    if args.archive:
        if args.archive.stat().st_size > 20 * 1024 * 1024:
            raise ValueError("Fossil archive exceeds the download limit")
        archive = args.archive.read_bytes()
    else:
        with urllib.request.urlopen(expected["url"], timeout=60) as response:
            archive = response.read(20 * 1024 * 1024 + 1)
        if len(archive) > 20 * 1024 * 1024:
            raise ValueError("Fossil archive exceeds the download limit")
    result = stage(archive, expected, args.platform, args.output)
    print(json.dumps({**result, "version": lock["fossil_version"], "source_revision": lock["source_revision"]}))


if __name__ == "__main__":
    main()
