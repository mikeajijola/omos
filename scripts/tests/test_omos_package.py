import hashlib
import importlib.util
from pathlib import Path
import shutil
import struct
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
