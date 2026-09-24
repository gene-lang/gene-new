#!/usr/bin/env python3
"""Pin IANA 2026d zones through an offline installed Gene application."""

from __future__ import annotations

import json
import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
TZDB = ROOT / "src/genex/tzdb"


def invoke(argv: list[str], env: dict[str, str], timeout: int = 180):
    return subprocess.run(argv, cwd=ROOT, env=env, capture_output=True,
                          text=True, timeout=timeout, check=False)


class GenexTzdbTests(unittest.TestCase):
    def test_pinned_zones_survive_offline_install(self) -> None:
        self.assertEqual((TZDB / "VERSION").read_text().strip(), "2026d")
        if not shutil.which("nim"):
            self.skipTest("Nim is unavailable")
        with tempfile.TemporaryDirectory(prefix="gene-tzdb-package-") as tmp:
            base = pathlib.Path(tmp)
            source = base / "source"
            source.mkdir()
            shutil.copytree(TZDB, source / "tzdb")
            app = source / "app"
            (app / "src").mkdir(parents=True)
            (app / "package.gene").write_text('''
{^format 1 ^name "acme/tzdb_installed" ^version "0.1.0"
 ^applications [(application "tzdb_installed" ^entry "src/main.gene")]
 ^dependencies {^tzdb (dep "genex/tzdb" "0.1.0" ^path "../tzdb")}}
''')
            (app / "src/main.gene").write_text('''
(import [to_local resolve_local release_id] ^from "." ^pkg "tzdb")
(fn main [args] : Int
  (let summer (to_local 2024-07-01T12:00Z "America/New_York"))
  (let winter (to_local 2024-01-01T12:00Z "America/New_York"))
  (let historical (to_local 1880-01-01T12:00Z "America/New_York"))
  (let future (to_local 2100-07-01T12:00Z "Europe/London"))
  (let local ($datetime 2024 11 3 1 30))
  (let earlier (resolve_local local "America/New_York" ^fold "earlier"))
  (let later (resolve_local local "America/New_York" ^fold "later"))
  (let rejected_fold
    (try (resolve_local local "America/New_York") false
      catch Error true))
  (let rejected_gap
    (try (resolve_local ($datetime 2024 3 10 2 30)
           "America/New_York") false
      catch Error true))
  (let rejected_unknown
    (try (to_local 2024-07-01T12:00Z "Unknown/Zone") false
      catch Error true))
  (let rejected_traversal
    (try (to_local 2024-07-01T12:00Z "../../LICENSE") false
      catch Error true))
  ($println ($json/stringify
    {^release (release_id)
     ^summer_offset summer/offset_seconds
     ^winter_offset winter/offset_seconds
     ^historical_offset historical/offset_seconds
     ^historical_hour (historical/datetime .hour)
     ^historical_second (historical/datetime .second)
     ^historical_offset_free (== (historical/datetime .offset) nil)
     ^future_offset future/offset_seconds
     ^earlier ($temporal/format_rfc3339 earlier/instant)
     ^later ($temporal/format_rfc3339 later/instant)
     ^rejected_fold rejected_fold ^rejected_gap rejected_gap
     ^rejected_unknown rejected_unknown
     ^rejected_traversal rejected_traversal
     ^recorded_release summer/tzdb_release}))
  0)
''')
            env = dict(os.environ)
            gene = base / "gene"
            built = invoke(["nim", "c", "--path:src", "--hints:off",
                            f"--nimcache:{base / 'nimcache'}", f"-o:{gene}",
                            "src/gene.nim"], env)
            self.assertEqual(built.returncode, 0, built.stdout + built.stderr)
            resolved = invoke([str(gene), "pkg", "resolve", "--package-root",
                               str(app)], env)
            self.assertEqual(resolved.returncode, 0,
                             resolved.stdout + resolved.stderr)
            developed = invoke([str(gene), "run", "--package-root", str(app),
                                "tzdb_installed"], env)
            self.assertEqual(developed.returncode, 0,
                             developed.stdout + developed.stderr)
            self.assertEqual(json.loads(developed.stdout)["release"], "2026d")
            prefix = base / "prefix"
            installed = invoke([str(gene), "install", "tzdb_installed",
                                "--prefix", str(prefix), "--package-root",
                                str(app)], env)
            self.assertEqual(installed.returncode, 0,
                             installed.stdout + installed.stderr)
            launch_env = dict(env,
                              GENE_USER_PACKAGES=str(base / "empty-packages"),
                              GENE_ARTIFACT_STORE=str(base / "empty-artifacts"),
                              GENE_C_COMPILER=str(base / "missing-compiler"))
            expected = {
                "release": "2026d", "recorded_release": "2026d",
                "summer_offset": -14400, "winter_offset": -18000,
                "historical_offset": -17762, "historical_hour": 7,
                "historical_second": 58, "historical_offset_free": True,
                "future_offset": 3600,
                "earlier": "2024-11-03T05:30:00Z",
                "later": "2024-11-03T06:30:00Z",
                "rejected_fold": True, "rejected_gap": True,
                "rejected_unknown": True, "rejected_traversal": True,
            }
            original = source / "tzdb"
            prior = source / "tzdb.old"
            original.rename(prior)
            replacement = source / "tzdb"
            shutil.copytree(prior, replacement)
            (replacement / "VERSION").write_text("2026e\n")
            module = replacement / "src/tzdb.gene"
            module.write_text(module.read_text().replace("2026d", "2026e"))
            with_replacement = invoke([str(prefix / "bin/tzdb_installed")],
                                      launch_env)
            self.assertEqual(with_replacement.returncode, 0,
                             with_replacement.stdout + with_replacement.stderr)
            self.assertEqual(json.loads(with_replacement.stdout), expected)
            source.rename(base / "source.hidden")
            without_checkout = invoke([str(prefix / "bin/tzdb_installed")],
                                      launch_env)
            self.assertEqual(without_checkout.returncode, 0,
                             without_checkout.stdout + without_checkout.stderr)
            self.assertEqual(json.loads(without_checkout.stdout), expected)


if __name__ == "__main__":
    unittest.main()
