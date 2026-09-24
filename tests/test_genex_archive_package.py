#!/usr/bin/env python3
"""Build and install the declared zlib codec package without a checkout."""

from __future__ import annotations

import json
import gzip
import os
import pathlib
import platform
import random
import shutil
import subprocess
import tempfile
import unittest
import zipfile


ROOT = pathlib.Path(__file__).resolve().parents[1]
ARCHIVE = ROOT / "src/genex/archive"


def invoke(argv: list[str], env: dict[str, str], timeout: int = 180):
    return subprocess.run(argv, cwd=ROOT, env=env, capture_output=True,
                          text=True, timeout=timeout, check=False)


class GenexArchivePackageTests(unittest.TestCase):
    def test_declared_codec_survives_offline_install(self) -> None:
        if (platform.system(), platform.machine()) not in {
            ("Darwin", "arm64"), ("Linux", "x86_64")}:
            self.skipTest("native archive target is unavailable")
        if not all(shutil.which(tool) for tool in ("nim", "cc", "pkg-config")):
            self.skipTest("Nim, C compiler, or pkg-config is unavailable")
        env = dict(os.environ)
        if platform.system() == "Darwin":
            sdk = json.loads((ROOT / "tests/profiles/native-app/"
                              "cli-toolchain.lock.json").read_text())[
                                  "macosx-arm64"]["sdk_root"]
            if not pathlib.Path(sdk).is_dir():
                self.skipTest("pinned macOS SDK is unavailable")
            env["SDKROOT"] = sdk
        zlib = invoke(["pkg-config", "--modversion", "zlib"], env)
        if zlib.returncode:
            self.skipTest("zlib pkg-config metadata is unavailable")
        unicode = invoke(["pkg-config", "--modversion", "libutf8proc"], env)
        if unicode.returncode:
            self.skipTest("libutf8proc pkg-config metadata is unavailable")
        with tempfile.TemporaryDirectory(prefix="gene-archive-package-") as tmp:
            base = pathlib.Path(tmp).resolve()
            source = base / "source"
            source.mkdir()
            shutil.copytree(ARCHIVE, source / "archive")
            app = source / "app"
            (app / "src").mkdir(parents=True)
            (app / "package.gene").write_text('''
{^format 1 ^name "acme/archive_installed" ^version "0.1.0"
 ^applications [(application "archive_installed" ^entry "src/main.gene")
                (application "archive_unawaited" ^entry "src/unawaited.gene")]
 ^dependencies {^archive (dep "genex/archive" "0.1.0" ^path "../archive")}}
''')
            (app / "src/main.gene").write_text('''
(import [codec_abi inspect_zip extract_zip_sync extract_zip _open_codec
         gzip_reader gzip_writer ArchiveError]
  ^from "." ^pkg "archive")
(import $io [IoResource AsyncReader AsyncWriter IoClosed])
(fn collect_codec [codec]
  (var chunks [])
  (var item (codec .pull 65536))
  (while (!= item void)
    (if (!= item nil) (chunks .push item))
    (set item (codec .pull 65536)))
  ($binary/concat chunks))
(fn read_gzip_bytes [bytes]
  (let pipe ($io/pipe))
  (await ($io/write_all pipe/1 bytes))
  (pipe/1 .IoResource:close)
  (await (pipe/1 .IoResource:wait_closed))
  (let reader (gzip_reader pipe/0 ^own_reader true))
  (var chunks [])
  (try
    (var item (await (reader .AsyncReader:read 3)))
    (while (!= item nil)
      (chunks .push item)
      (set item (await (reader .AsyncReader:read 3))))
    ($binary/concat chunks)
    ensure
      (reader .IoResource:close)
      (await (reader .IoResource:wait_closed))))
(fn main [args] : Int
  (let payload ($binary/from_list [104 101 108 108 111 0 119 111 114 108 100]))
  (let encoder (_open_codec 2))
  (encoder .feed payload)
  (var prefix [])
  (var part (encoder .pull 65536))
  (while (!= part nil)
    (if (!= part void) (prefix .push part))
    (set part (encoder .pull 65536)))
  (encoder .action 2)
  (let compressed ($binary/concat [($binary/concat prefix)
                                   (collect_codec encoder)]))
  (encoder .close)
  (let decoder (_open_codec 1))
  (decoder .feed compressed)
  (var restored_parts [])
  (var decoded (decoder .pull 65536))
  (while (!= decoded nil)
    (if (== decoded void)
      (fail (new ArchiveError "codec ended before source EOF")))
    (restored_parts .push decoded)
    (set decoded (decoder .pull 65536)))
  (decoder .action 2)
  (let codec_finished (== (decoder .pull 65536) void))
  (let restored ($binary/concat restored_parts))
  (decoder .close)
  (let concatenated (read_gzip_bytes ($fs/read_bytes args/12)))
  (let trailing_rejected
    (try (read_gzip_bytes ($fs/read_bytes args/13)) false
      catch ArchiveError true))
  (let pipe ($io/pipe))
  (let writer (gzip_writer pipe/1 ^own_writer true))
  (let first ($binary/slice payload 0 5))
  (let second ($binary/slice payload 5 (- ($binary/size payload) 5)))
  (let written1 (await (writer .AsyncWriter:write first)))
  (await (writer .AsyncWriter:flush))
  (let flushed_without_finish (not (/finished (writer .status))))
  (let written2 (await (writer .AsyncWriter:write second)))
  (await (writer .finish))
  (let finish_rejects_write
    (try (writer .AsyncWriter:write payload) false
      catch IoClosed true))
  (writer .IoResource:close)
  (await (writer .IoResource:wait_closed))
  (await (writer .IoResource:wait_closed))
  (let reader (gzip_reader pipe/0 ^own_reader true))
  (var pieces [])
  (var piece (await (reader .AsyncReader:read 3)))
  (while (!= piece nil)
    (pieces .push piece)
    (set piece (await (reader .AsyncReader:read 3))))
  (reader .IoResource:close)
  (await (reader .IoResource:wait_closed))
  (await (reader .IoResource:wait_closed))
  (let abort_pipe ($io/pipe))
  (let abort_writer (gzip_writer abort_pipe/1 ^own_writer true))
  (await (abort_writer .AsyncWriter:write payload))
  (abort_writer .IoResource:close)
  (await (abort_writer .IoResource:wait_closed))
  (let abort_reader (gzip_reader abort_pipe/0 ^own_reader true))
  (var aborted false)
  (try
    (while true
      (let next (await (abort_reader .AsyncReader:read 16)))
      (if (== next nil) (break)))
    catch ArchiveError (set aborted true))
  (abort_reader .IoResource:close)
  (await (abort_reader .IoResource:wait_closed))
  (let blocked_pipe ($io/pipe))
  (let waiting (gzip_reader blocked_pipe/0 ^own_reader true))
  (let blocked_read (waiting .AsyncReader:read 4))
  ($sleep 0)
  (waiting .IoResource:close)
  (await (waiting .IoResource:wait_closed))
  (let read_cancelled (match (blocked_read .join)
    (when TaskOutcome/cancelled true)
    (else false)))
  (blocked_pipe/1 .IoResource:close)
  (await (blocked_pipe/1 .IoResource:wait_closed))
  (let slow_pipe ($io/pipe))
  (let slow_writer (gzip_writer slow_pipe/1 ^own_writer true))
  (let large ($fs/read_bytes args/11))
  (let pending_write (slow_writer .AsyncWriter:write large))
  ($sleep 20)
  (slow_writer .IoResource:close)
  (await (slow_writer .IoResource:wait_closed))
  (let write_cancelled (match (pending_write .join)
    (when TaskOutcome/cancelled true)
    (else false)))
  (slow_pipe/0 .IoResource:close)
  (await (slow_pipe/0 .IoResource:wait_closed))
  (let archive_package ($pkg/dependency this_pkg "archive"))
  (let diagnostic_lease ($pkg/native_binary archive_package "codec"))
  (let diagnostic_library ($ffi/open (diagnostic_lease .path)))
  (let live_streams ($ffi/bind diagnostic_library "gene_archive_live_streams"
                               [] C/Int64))
  (let abandoned_pipe ($io/pipe))
  (var abandoned_reader (gzip_reader abandoned_pipe/0))
  (var abandoned_writer (gzip_writer abandoned_pipe/1))
  (set abandoned_reader nil)
  (set abandoned_writer nil)
  ($sleep 0)
  (let abandoned_released (== (live_streams) 0))
  (abandoned_pipe/0 .IoResource:close)
  (abandoned_pipe/1 .IoResource:close)
  (await (abandoned_pipe/0 .IoResource:wait_closed))
  (await (abandoned_pipe/1 .IoResource:wait_closed))
  ($ffi/Library/close diagnostic_library)
  (diagnostic_lease .close)
  (let retry_pipe ($io/pipe))
  (let retry_writer (gzip_writer retry_pipe/1 ^own_writer true))
  (let early_write (retry_writer .AsyncWriter:write payload))
  (early_write .cancel)
  (let early_write_cancelled (match (early_write .join)
    (when TaskOutcome/cancelled true)
    (else false)))
  (let retry_written (await (retry_writer .AsyncWriter:write payload)))
  (await (retry_writer .finish))
  (retry_writer .IoResource:close)
  (await (retry_writer .IoResource:wait_closed))
  (let retry_reader (gzip_reader retry_pipe/0 ^own_reader true))
  (let early_read (retry_reader .AsyncReader:read 3))
  (early_read .cancel)
  (let early_read_cancelled (match (early_read .join)
    (when TaskOutcome/cancelled true)
    (else false)))
  (let retry_bytes (await (retry_reader .AsyncReader:read 3)))
  (retry_reader .IoResource:close)
  (await (retry_reader .IoResource:wait_closed))
  (let before_start (extract_zip args/7 args/9))
  (before_start .cancel)
  (let immediate_cancelled (match (before_start .join)
    (when TaskOutcome/cancelled true)
    (else false)))
  (let cancelling (extract_zip args/7 args/8))
  ($sleep 1)
  (cancelling .cancel)
  (let cancelled (match (cancelling .join)
    (when TaskOutcome/cancelled true)
    (else false)))
  (let committed (extract_zip args/0 args/10))
  (var commit_wait 0)
  (while (&& (not ($fs/exists? args/10)) (< commit_wait 5000))
    ($sleep 1)
    (set commit_wait (+ commit_wait 1)))
  (if (not ($fs/exists? args/10))
    (fail (new ArchiveError "ZIP commit was not observed")))
  (committed .cancel)
  (let postcommit (match (committed .join)
    (when (TaskOutcome/ok value) value)
    (else -1)))
  ($println ($json/stringify {^abi (codec_abi)
                             ^gzip_ok (== restored payload)
                             ^gzip_codec_finished codec_finished
                             ^gzip_concatenated_ok
                               (== concatenated ($binary/from_str "helloworld"))
                             ^gzip_trailing_rejected trailing_rejected
                             ^gzip_stream_ok (== ($binary/concat pieces) payload)
                             ^gzip_written (+ written1 written2)
                             ^gzip_flushed_without_finish flushed_without_finish
                             ^gzip_finish_rejects_write finish_rejects_write
                             ^gzip_abort_rejected aborted
                             ^gzip_read_cancelled read_cancelled
                             ^gzip_write_cancelled write_cancelled
                             ^gzip_abandoned_released abandoned_released
                             ^gzip_immediate_write_retry
                               (&& early_write_cancelled
                                   (== retry_written ($binary/size payload)))
                             ^gzip_immediate_read_retry
                               (&& early_read_cancelled
                                   (== retry_bytes ($binary/slice payload 0 3)))
                             ^entries (inspect_zip args/0)
                             ^published (await (extract_zip args/0 args/2))
                             ^sync_published (extract_zip_sync args/0 args/6)
                             ^rejected
                               (try (await (extract_zip args/1 args/3)) false
                                 catch ArchiveError true)
                             ^crc_rejected
                               (try (await (extract_zip args/4 args/5)) false
                                 catch ArchiveError true)
                             ^unicode_rejected
                               (try (await (extract_zip args/14 args/15)) false
                                 catch ArchiveError true)
                             ^immediate_cancelled immediate_cancelled
                             ^cancelled cancelled
                             ^postcommit postcommit
                             ^leases
                               (/materialized_resource_leases
                                 ($runtime/gc_stats))}))
  0)
''')
            (app / "src/unawaited.gene").write_text('''
(import [extract_zip] ^from "." ^pkg "archive")
(fn main [args] : Int
  (let pending (extract_zip args/0 args/1))
  ($sleep 100)
  0)
''')
            gene = base / "gene"
            built = invoke(["nim", "c", "--path:src", "--hints:off",
                            f"--nimcache:{base / 'nimcache'}", f"-o:{gene}",
                            "src/gene.nim"], env)
            self.assertEqual(built.returncode, 0, built.stdout + built.stderr)
            resolved = invoke([str(gene), "pkg", "resolve", "--package-root",
                               str(app)], env)
            self.assertEqual(resolved.returncode, 0,
                             resolved.stdout + resolved.stderr)
            many = base / "many.zip"
            with zipfile.ZipFile(many, "w", compression=zipfile.ZIP_STORED) as z:
                for i in range(4000):
                    z.writestr(f"dir/file-{i:04d}.txt", b"payload")
            unawaited_output = base / "unawaited_output"
            unawaited = invoke([str(gene), "run", "--package-root", str(app),
                                "archive_unawaited", str(many),
                                str(unawaited_output)], env)
            self.assertEqual(unawaited.returncode, 0,
                             unawaited.stdout + unawaited.stderr)
            self.assertEqual((unawaited_output / "dir/file-3999.txt").read_bytes(),
                             b"payload")
            self.assertEqual(list(base.glob(".gene-archive-*")), [])
            prefix = base / "prefix"
            installed = invoke([str(gene), "install", "archive_installed",
                                "--prefix", str(prefix), "--package-root",
                                str(app)], env)
            self.assertEqual(installed.returncode, 0,
                             installed.stdout + installed.stderr)
            source.rename(base / "source.hidden")
            sample = base / "sample.zip"
            with zipfile.ZipFile(sample, "w", compression=zipfile.ZIP_DEFLATED) as z:
                z.writestr("dir/", b"", compress_type=zipfile.ZIP_STORED)
                z.writestr("dir/first.txt", b"first")
                z.writestr("second.bin", b"\x00\xff")
            unsafe = base / "unsafe.zip"
            with zipfile.ZipFile(unsafe, "w") as z:
                z.writestr("../escape", b"bad")
            damaged = base / "damaged.zip"
            damaged_bytes = bytearray(sample.read_bytes())
            local = damaged_bytes.index(b"PK\x03\x04", 4)
            central = damaged_bytes.index(b"PK\x01\x02")
            central = damaged_bytes.index(b"PK\x01\x02", central + 4)
            damaged_bytes[local + 14] ^= 1
            damaged_bytes[central + 16] ^= 1
            damaged.write_bytes(damaged_bytes)
            output = base / "published"
            sync_output = base / "sync_published"
            rejected_output = base / "rejected"
            damaged_output = base / "damaged_output"
            cancelled_output = base / "cancelled_output"
            immediate_output = base / "immediate_output"
            postcommit_output = base / "postcommit_output"
            large = base / "large.bin"
            large.write_bytes(random.Random(17).randbytes(1048576))
            concatenated = base / "concatenated.gz"
            concatenated.write_bytes(gzip.compress(b"hello", mtime=0) +
                                     gzip.compress(b"world", mtime=0))
            trailing = base / "trailing.gz"
            trailing.write_bytes(gzip.compress(b"hello", mtime=0) + b"JUNK")
            unicode_archive = base / "unicode_collision.zip"
            with zipfile.ZipFile(unicode_archive, "w") as z:
                z.writestr("É/one.txt", b"a")
                z.writestr("e\u0301/two.txt", b"b")
            unicode_output = base / "unicode_output"
            launch_env = dict(os.environ,
                              GENE_USER_PACKAGES=str(base / "empty-packages"),
                              GENE_ARTIFACT_STORE=str(base / "empty-artifacts"),
                              GENE_C_COMPILER=str(base / "missing-compiler"))
            launch_env.pop("SDKROOT", None)
            launched = invoke([str(prefix / "bin/archive_installed"),
                               str(sample), str(unsafe), str(output),
                               str(rejected_output), str(damaged),
                               str(damaged_output), str(sync_output),
                               str(many), str(cancelled_output),
                               str(immediate_output), str(postcommit_output),
                               str(large), str(concatenated), str(trailing),
                               str(unicode_archive), str(unicode_output)],
                              launch_env)
            self.assertEqual(launched.returncode, 0,
                             launched.stdout + launched.stderr)
            self.assertEqual(json.loads(launched.stdout),
                             {"abi": 1, "gzip_ok": True,
                              "gzip_codec_finished": True,
                              "gzip_concatenated_ok": True,
                              "gzip_trailing_rejected": True,
                              "gzip_stream_ok": True, "gzip_written": 11,
                              "gzip_flushed_without_finish": True,
                              "gzip_finish_rejects_write": True,
                              "gzip_abort_rejected": True,
                              "gzip_read_cancelled": True,
                              "gzip_write_cancelled": True,
                              "gzip_abandoned_released": True,
                              "gzip_immediate_write_retry": True,
                              "gzip_immediate_read_retry": True,
                              "entries": 3, "published": 3,
                              "sync_published": 3, "rejected": True,
                              "crc_rejected": True, "cancelled": True,
                              "immediate_cancelled": True, "postcommit": 3,
                              "unicode_rejected": True,
                              "leases": 0})
            self.assertEqual((output / "dir/first.txt").read_bytes(), b"first")
            self.assertEqual((output / "second.bin").read_bytes(), b"\x00\xff")
            self.assertEqual((sync_output / "second.bin").read_bytes(),
                             b"\x00\xff")
            self.assertFalse(rejected_output.exists())
            self.assertFalse(damaged_output.exists())
            self.assertFalse(cancelled_output.exists())
            self.assertFalse(immediate_output.exists())
            self.assertFalse(unicode_output.exists())
            self.assertEqual((postcommit_output / "second.bin").read_bytes(),
                             b"\x00\xff")
            self.assertEqual(list(base.glob(".gene-archive-*")), [])


if __name__ == "__main__":
    unittest.main()
