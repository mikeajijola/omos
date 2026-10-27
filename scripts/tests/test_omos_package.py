import hashlib
import importlib.util
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import unittest


scripts = Path(__file__).parents[1]
spec = importlib.util.spec_from_file_location("omos_package", scripts / "package-omos.py")
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)


def elf(machine):
    header = bytearray(64)
    header[:6] = b"\x7fELF\x02\x01"
    struct.pack_into("<H", header, 18, machine)
    return bytes(header)


class InstallationInputsTests(unittest.TestCase):
    def test_unstartable_runtime_preserves_fresh_and_existing_installations(self):
        for existing in (False, True):
            with self.subTest(existing=existing), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                source = root / "source"
                (source / "scripts").mkdir(parents=True)
                installer = source / "scripts/install-omos.sh"
                shutil.copyfile(scripts / "install-omos.sh", installer)
                runtime = source / "zig-out/bin/fx"
                runtime.parent.mkdir(parents=True)
                runtime.write_text("#!/bin/sh\nexit 126\n")
                runtime.chmod(0o700)
                for relative, content in (
                    ("deployment/company/mcp.mjs", "export {};\n"),
                    ("src/core/workspace/standard/omos.json", "{}\n"),
                    ("zig-out/libexec/fossil", "#!/bin/sh\nexit 0\n"),
                ):
                    component = source / relative
                    component.parent.mkdir(parents=True, exist_ok=True)
                    component.write_text(content)
                (source / "zig-out/libexec/fossil").chmod(0o700)
                home = root / "home"
                home.mkdir()
                aliases = [home / ".local/bin" / name for name in ("omos", "omo")]
                previous = home / ".fx/releases/previous/fx"
                if existing:
                    previous.parent.mkdir(parents=True)
                    previous.write_bytes(b"previous runtime")
                    aliases[0].parent.mkdir(parents=True)
                    for alias in aliases:
                        alias.symlink_to(previous)
                    (home / ".fx/omos-workspace.json").write_bytes(b"retained binding")
                def files():
                    return {
                        str(path.relative_to(home)): path.read_bytes()
                        for path in home.rglob("*")
                        if path.is_file() and not path.is_symlink()
                    }

                before = files()
                result = subprocess.run(
                    ["sh", str(installer), "--copy"],
                    env={"HOME": str(home), "PATH": "/usr/bin:/bin"},
                    capture_output=True, text=True, timeout=10,
                )
                self.assertEqual(before, files())
                for alias in aliases:
                    self.assertEqual(alias.is_symlink(), existing)
                    if existing:
                        self.assertEqual(alias.readlink(), previous)
                self.assertEqual(result.returncode, 1)
                self.assertIn("runtime cannot start on this host", result.stderr)
                self.assertNotIn("Installed", result.stdout)

    def fixture(self, root, runtime):
        (root / "scripts").mkdir()
        shutil.copyfile(scripts / "stage-fossil-helper.py", root / "scripts/stage-fossil-helper.py")
        (root / "zig-out/bin").mkdir(parents=True)
        (root / "zig-out/libexec").mkdir()
        (root / "zig-out/bin/fx").write_bytes(runtime)
        helper = elf(62)
        destination = root / "zig-out/libexec/fossil"
        destination.write_bytes(helper)
        return destination, {"platforms": {"linux-x86_64": {"binary_sha256": hashlib.sha256(helper).hexdigest(), "binary_bytes": len(helper)}}}

    def test_matching_helper_does_not_allow_the_wrong_runtime_platform(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            _, lock = self.fixture(root, elf(183))
            with self.assertRaisesRegex(ValueError, "runtime platform mismatch"):
                package.validate_inputs(root, "linux-x86_64", lock)

    def test_runtime_platform_does_not_allow_a_changed_helper(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            helper, lock = self.fixture(root, elf(62))
            helper.write_bytes(elf(183))
            with self.assertRaisesRegex(ValueError, "pinned Fossil"):
                package.validate_inputs(root, "linux-x86_64", lock)

    def test_preview_accepts_matching_platform_and_exact_helper_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            helper, lock = self.fixture(root, elf(62))
            self.assertEqual(package.validate_inputs(root, "linux-x86_64", lock), helper)


if __name__ == "__main__":
    unittest.main()
