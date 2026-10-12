#!/usr/bin/env python3
"""Regression coverage for SDK propagation in the native bootstrap driver."""
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location(
    "genex_build_aot", ROOT / "src/genex/tools/build_aot.py")
driver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(driver)


class NativeEnvironmentTests(unittest.TestCase):
    def test_explicit_sdk_is_preserved_without_probing(self):
        with patch.dict(os.environ, {"SDKROOT": "/chosen/sdk"}, clear=True), \
                patch.object(driver.platform, "system", return_value="Darwin"), \
                patch.object(driver.subprocess, "run") as run:
            self.assertEqual(driver.native_environment("custom-cc"),
                             {"SDKROOT": "/chosen/sdk"})
            run.assert_not_called()

    def test_non_macos_is_unchanged(self):
        with patch.dict(os.environ, {"CC": "gcc"}, clear=True), \
                patch.object(driver.platform, "system", return_value="Linux"), \
                patch.object(driver.subprocess, "run") as run:
            self.assertEqual(driver.native_environment("gcc"), {"CC": "gcc"})
            run.assert_not_called()

    def test_working_default_does_not_choose_an_sdk(self):
        with patch.dict(os.environ, {"CC": "custom-cc"}, clear=True), \
                patch.object(driver.platform, "system", return_value="Darwin"), \
                patch.object(driver.subprocess, "run", return_value=
                             subprocess.CompletedProcess([], 0, "", "")) as run:
            self.assertEqual(driver.native_environment("custom-cc"),
                             {"CC": "custom-cc"})
            self.assertEqual(run.call_count, 1)
            self.assertEqual(run.call_args.args[0][0], "custom-cc")

    def test_newest_linkable_sdk_uses_numeric_order_and_propagatable_environment(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            for version in ["27.0", "26.5", "26.10"]:
                (directory / f"MacOSX{version}.sdk").mkdir()
            (directory / "MacOSX27.sdk").symlink_to(directory / "MacOSX27.0.sdk")
            attempts = []

            def run(argv, **kwargs):
                if argv[0] == "xcrun":
                    return subprocess.CompletedProcess(argv, 0,
                        str(directory / "MacOSX.sdk") + "\n", "")
                self.assertEqual(argv[0], "custom-cc")
                sdk = kwargs["env"].get("SDKROOT", "")
                attempts.append(sdk)
                return subprocess.CompletedProcess(argv,
                    0 if sdk.endswith("MacOSX26.10.sdk") else 1, "", "bad SDK")

            with patch.dict(os.environ, {"CC": "custom-cc", "KEEP": "yes"}, clear=True), \
                    patch.object(driver.platform, "system", return_value="Darwin"), \
                    patch.object(driver.subprocess, "run", side_effect=run):
                environment = driver.native_environment("custom-cc")
                self.assertEqual(environment["SDKROOT"], str(directory / "MacOSX26.10.sdk"))
                self.assertEqual(environment["KEEP"], "yes")
                self.assertNotIn("SDKROOT", os.environ)
            self.assertEqual(attempts, ["", str(directory / "MacOSX27.0.sdk"),
                                       str(directory / "MacOSX26.10.sdk")])

    def test_no_compatible_sdk_explains_the_failure(self):
        with patch.dict(os.environ, {}, clear=True), \
                patch.object(driver.platform, "system", return_value="Darwin"), \
                patch.object(driver.subprocess, "run", return_value=
                             subprocess.CompletedProcess([], 1, "", "unknown architecture")):
            with self.assertRaisesRegex(SystemExit, "CC/SDKROOT.*\nunknown architecture"):
                driver.native_environment("cc")


if __name__ == "__main__":
    unittest.main()
