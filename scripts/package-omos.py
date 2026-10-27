#!/usr/bin/env python3
"""Package the native runtime, pinned Fossil helper, and standalone installer."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import tarfile
import tempfile


def digest(path):
    with path.open("rb") as file:
        return hashlib.file_digest(file, "sha256").hexdigest()


def validate_inputs(root, platform, lock):
    spec = importlib.util.spec_from_file_location("fossil_helper", root / "scripts/stage-fossil-helper.py")
    validator = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(validator)
    runtime = root / "zig-out/bin/fx"
    with runtime.open("rb") as binary:
        if not validator.matches_platform(binary.read(64), platform):
            raise ValueError("Native runtime platform mismatch")
    helper = root / "zig-out/libexec/fossil"
    expected = lock["platforms"][platform]
    if helper.stat().st_size != expected["binary_bytes"] or digest(helper) != expected["binary_sha256"]:
        raise ValueError("Stage the pinned Fossil helper for this platform before packaging")
    return helper


def main():
    root = Path(__file__).resolve().parent.parent
    lock = json.loads((root / "scripts/fossil-helper.lock.json").read_text())
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", required=True, choices=sorted(lock["platforms"]))
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--compression-level", type=int, choices=range(1, 10), default=6)
    args = parser.parse_args()
    helper = validate_inputs(root, args.platform, lock)
    paths = ["zig-out/bin/fx", "zig-out/libexec/fossil", "scripts/install-omos.sh", "scripts/fossil-helper.lock.json", "deployment/company/mcp.mjs", "src/core/workspace/standard/omos.json", "LICENSE", "THIRD_PARTY_NOTICES.md", "deployment/company/FOSSIL-NOTICES.md", "deployment/INSTALL.md"]
    paths.extend("deployment/company/" + name for name in (
        "worker-broker.mjs", "worker-control.mjs", "worker-http-control.mjs",
        "worker-coordinator.mjs", "worker-recovery.mjs", "worker-snapshot.mjs", "worker-linux.mjs", "worker-validation.mjs", "worker-runtime.mjs", "worker-archive.mjs", "worker-checkpoint.mjs", "worker-native.mjs",
        "worker-server.mjs", "worker-launcher.py", "worker-image.py",
        "omos-company.service", "omos-company-workers.service", "Caddyfile",
        "README.md", "WORKERS.md", "DESIRED.md", "ACTIVITY.md", "INPUT.md",
    ))
    with tempfile.TemporaryDirectory(prefix="omos-package-") as directory:
        tree = Path(directory) / "omos"
        for name in paths:
            destination = tree / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(root / name, destination)
            destination.chmod(0o755 if name in paths[:3] else 0o644)
        installer = tree / "install.sh"
        installer.write_text('#!/bin/sh\nset -eu\ncd -- "$(CDPATH=\'\' cd -- "$(dirname -- "$0")" && pwd)"\nif command -v sha256sum >/dev/null 2>&1; then\n    sha256sum -c SHA256SUMS\nelse\n    shasum -a 256 -c SHA256SUMS\nfi\nexec sh scripts/install-omos.sh --copy\n')
        installer.chmod(0o755)
        paths.append("install.sh")
        manifest = {"version": "omos.installation/v1", "distribution": "preview", "platform": args.platform, "fossil_version": lock["fossil_version"], "fossil_source_revision": lock["source_revision"], "files": [{"path": name, "sha256": digest(tree / name), "bytes": (tree / name).stat().st_size} for name in paths]}
        (tree / "installation.json").write_text(json.dumps(manifest, indent=2) + "\n")
        paths.append("installation.json")
        (tree / "SHA256SUMS").write_text("".join(f"{digest(tree / name)}  {name}\n" for name in paths))
        args.output.parent.mkdir(parents=True, exist_ok=True)
        with tarfile.open(args.output, "w:gz", compresslevel=args.compression_level) as archive:
            archive.add(tree, arcname="omos")
    checksum = digest(args.output)
    Path(str(args.output) + ".sha256").write_text(f"{checksum}  {args.output.name}\n")
    print(json.dumps({"archive": str(args.output), "sha256": checksum, "download_bytes": args.output.stat().st_size, "runtime_bytes": (root / "zig-out/bin/fx").stat().st_size, "fossil_bytes": helper.stat().st_size, "platform": args.platform}))


if __name__ == "__main__":
    main()
