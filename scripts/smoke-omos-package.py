#!/usr/bin/env python3
"""Exercise a preview bundle after removing its unpacked installation files."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile


def run(command, cwd, env):
    result = subprocess.run(command, cwd=cwd, env=env, capture_output=True, text=True, timeout=120)
    if result.returncode:
        raise RuntimeError(f"Bundle smoke command failed: {result.stderr}")
    return result.stdout


def smoke(archive):
    with tempfile.TemporaryDirectory(prefix="omos-installation-smoke-") as directory:
        # macOS temporary paths commonly begin with /var, whose canonical
        # location is /private/var. Compare the same absolute paths as omos.
        root = Path(directory).resolve()
        unpacked = root / "unpacked"
        unpacked.mkdir()
        with tarfile.open(archive, "r:gz") as source:
            source.extractall(unpacked, filter="data")
        bundle = unpacked / "omos"
        manifest = json.loads((bundle / "installation.json").read_text())
        bindings = []
        profiles = []
        for name in ("first", "second"):
            home = root / name
            home.mkdir()
            env = {key: value for key, value in os.environ.items() if not key.startswith(("FX_", "OMOS_", "FOSSIL_"))}
            env.update(HOME=str(home), XDG_BIN_HOME=str(home / "bin"), FX_DISABLE_KEYCHAIN="1", FX_SOUND="0", FX_AUTO_UPGRADE="0")
            for key in ("XDG_CONFIG_HOME", "AI_GATEWAY_API_KEY", "VERCEL_OIDC_TOKEN", "GEMINI_API_KEY"):
                env.pop(key, None)
            run(["sh", str(bundle / "install.sh")], root, env)
            binding = json.loads((home / ".fx/omos-workspace.json").read_text())
            assert binding["repository"] == str(home / ".fx/instances/personal.fossil")
            bindings.append(binding)
            profiles.append((home, env))
        assert bindings[0]["workspace_id"] != bindings[1]["workspace_id"]
        shutil.rmtree(unpacked)
        export = root / "portable.fossil"
        for index, (home, env) in enumerate(profiles):
            # Native operations must use the installed, verified helper. No
            # system Fossil or unpacked bundle remains reachable through PATH.
            env["PATH"] = str(home / "empty-path")
            for alias in ("omos", "omo"):
                executable = home / "bin" / alias
                result = json.loads(run([str(executable), "fossil", "tasks", "--json"], root, env))
                assert result["tasks"] == []
            executable = str(home / "bin/omos")
            if index == 0:
                run([executable, "fossil", "export", str(export), "--json"], root, env)
            else:
                run([executable, "fossil", "use", str(export), "--json"], root, env)
                restored = json.loads((home / ".fx/omos-workspace.json").read_text())
                assert restored["workspace_id"] == bindings[0]["workspace_id"]
            run([executable, "fossil", "verify", "--json"], root, env)
        return {"version": "omos.installation-smoke/v1", "platform": manifest["platform"], "distribution": manifest["distribution"], "aliases": ["omos", "omo"], "unique_empty_instances": True, "unpacked_source_removed": True, "system_fossil_unavailable": True, "portable_restore_verified": True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    args = parser.parse_args()
    print(json.dumps(smoke(args.archive.resolve())))


if __name__ == "__main__":
    main()
