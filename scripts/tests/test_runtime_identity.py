"""CI and the VM gate reject a toolchain that differs from the frozen runtime contract."""
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import runtime_identity

CONTRACT = json.loads(runtime_identity.MANIFEST.read_text())


class ToolchainTest(unittest.TestCase):
    def check(self, otp=CONTRACT["otp"], elixir=CONTRACT["elixir"], timeout="timeout (GNU coreutils) 9.4"):
        with tempfile.TemporaryDirectory() as root:
            release = Path(root) / "releases" / "28"
            release.mkdir(parents=True)
            (release / "OTP_VERSION").write_text(otp + "\n")

            def run(argv, **kwargs):
                if argv[0] == "erl":
                    return root if "code:root_dir()" in argv[3] else "28"
                return {"elixir": elixir, "timeout": timeout}[argv[0]]

            with patch.object(runtime_identity.subprocess, "check_output", side_effect=run):
                return runtime_identity.toolchain()

    def test_matching_toolchain_reports_the_patch_level_that_elixir_version_hides(self):
        self.assertEqual(self.check(), {"otp": CONTRACT["otp"], "elixir": CONTRACT["elixir"]})
        self.assertEqual(CONTRACT["otp"].count("."), 3)

    def test_other_otp_patch_level_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "otp 28.5.0.6 differs"):
            self.check(otp="28.5.0.6")

    def test_other_elixir_version_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "elixir 1.19.5 differs"):
            self.check(elixir="1.19.5")

    def test_non_gnu_timeout_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "GNU timeout"):
            self.check(timeout="BusyBox v1.36.1 multi-call binary")


if __name__ == "__main__":
    unittest.main()
