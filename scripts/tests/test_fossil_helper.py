import hashlib
import importlib.util
import io
from pathlib import Path
import tarfile
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("fossil_helper", Path(__file__).parents[1] / "stage-fossil-helper.py")
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)


def archive(binary, extra=False):
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w:gz") as tar:
        entry = tarfile.TarInfo("fossil")
        entry.size = len(binary)
        tar.addfile(entry, io.BytesIO(binary))
        if extra:
            tar.addfile(tarfile.TarInfo("../untrusted-file"))
    data = output.getvalue()
    return data, {"archive_sha256": hashlib.sha256(data).hexdigest(), "binary_sha256": hashlib.sha256(binary).hexdigest(), "binary_bytes": len(binary)}


class FossilHelperIntegrityTests(unittest.TestCase):
    def test_hash_rejection_retains_the_previous_executable(self):
        data, expected = archive(b"untrusted executable")
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "fossil"
            output.write_bytes(b"previous executable")
            with self.assertRaisesRegex(ValueError, "archive hash mismatch"):
                helper.stage(data + b"tampered", expected, "linux-x86_64", output)
            self.assertEqual(output.read_bytes(), b"previous executable")

    def test_extra_archive_entries_are_never_materialized(self):
        data, expected = archive(b"untrusted executable", extra=True)
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "fossil"
            with self.assertRaisesRegex(ValueError, "archive entries"):
                helper.stage(data, expected, "linux-x86_64", output)
            self.assertEqual(list(Path(directory).iterdir()), [])

    def test_matching_hashes_do_not_allow_a_wrong_platform(self):
        data, expected = archive(b"not an ELF executable".ljust(64, b"\0"))
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "fossil"
            with self.assertRaisesRegex(ValueError, "platform mismatch"):
                helper.stage(data, expected, "linux-x86_64", output)
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
