#!/usr/bin/env python3
"""Reject unsupported or unsafe ZIP metadata before destination creation."""

from __future__ import annotations

import ctypes as C
import io
import json
import os
import pathlib
import platform
import shlex
import shutil
import struct
import subprocess
import tempfile
import threading
import time
import unittest
import zipfile


ROOT = pathlib.Path(__file__).resolve().parents[1]
ZIP = ROOT / "src/genex/archive/native/zip.c"


class ZipValidatorTests(unittest.TestCase):
    def test_store_deflate_and_adversarial_metadata(self) -> None:
        if platform.system() not in {"Darwin", "Linux"} or not all(
            shutil.which(tool) for tool in ("cc", "pkg-config")):
            self.skipTest("native C compiler or pkg-config is unavailable")
        env = dict(os.environ)
        if platform.system() == "Darwin":
            sdk = json.loads((ROOT / "tests/profiles/native-app/"
                              "cli-toolchain.lock.json").read_text())[
                                  "macosx-arm64"]["sdk_root"]
            if not pathlib.Path(sdk).is_dir():
                self.skipTest("pinned macOS SDK is unavailable")
            env["SDKROOT"] = sdk
        unicode_flags = subprocess.run(
            ["pkg-config", "--cflags", "--libs", "libutf8proc"],
            env=env, capture_output=True, text=True, check=False)
        if unicode_flags.returncode:
            self.skipTest("libutf8proc pkg-config metadata is unavailable")
        with tempfile.TemporaryDirectory(prefix="gene-archive-zip-") as tmp:
            base = pathlib.Path(tmp).resolve()
            library_path = base / ("libzip.dylib" if platform.system() == "Darwin"
                                   else "libzip.so")
            command = ["cc", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
                       "-DGENE_ARCHIVE_TEST_PAUSE_BEFORE_PUBLISH",
                       "-dynamiclib" if platform.system() == "Darwin" else
                       "-shared", "-fPIC", "-pthread", str(ZIP), "-lz",
                       *shlex.split(unicode_flags.stdout), "-o", str(library_path)]
            built = subprocess.run(command, env=env, capture_output=True,
                                   text=True, check=False)
            self.assertEqual(built.returncode, 0, built.stdout + built.stderr)
            library = C.CDLL(str(library_path))
            library.gene_archive_zip_validate.argtypes = [C.c_char_p]
            library.gene_archive_zip_validate.restype = C.c_int
            library.gene_archive_zip_extract.argtypes = [C.c_char_p, C.c_char_p]
            library.gene_archive_zip_extract.restype = C.c_int
            library.gene_archive_zip_job_start.argtypes = [C.c_char_p,
                                                            C.c_char_p]
            library.gene_archive_zip_job_start.restype = C.c_void_p
            library.gene_archive_zip_job_poll.argtypes = [C.c_void_p]
            library.gene_archive_zip_job_poll.restype = C.c_int
            library.gene_archive_zip_job_cancel.argtypes = [C.c_void_p]
            library.gene_archive_zip_job_release.argtypes = [C.c_void_p]
            library.gene_archive_zip_job_error.argtypes = [C.c_void_p]
            library.gene_archive_zip_job_error.restype = C.c_char_p
            library.gene_archive_zip_last_error.restype = C.c_char_p

            def validate(data: bytes) -> tuple[int, str]:
                archive = base / "input.zip"
                archive.write_bytes(data)
                result = library.gene_archive_zip_validate(os.fsencode(archive))
                return result, library.gene_archive_zip_last_error().decode()

            def extract(data: bytes, destination: pathlib.Path) -> tuple[int, str]:
                archive = base / "input.zip"
                archive.write_bytes(data)
                result = library.gene_archive_zip_extract(
                    os.fsencode(archive), os.fsencode(destination))
                return result, library.gene_archive_zip_last_error().decode()

            def make(entries: list[tuple[str, bytes]],
                     method=zipfile.ZIP_DEFLATED) -> bytes:
                out = io.BytesIO()
                with zipfile.ZipFile(out, "w", compression=method) as z:
                    for name, body in entries:
                        z.writestr(name, body,
                                   compress_type=(zipfile.ZIP_STORED if
                                                  name.endswith("/") else method))
                return out.getvalue()

            valid = make([("dir/", b""), ("dir/naïve.txt", b"abc\x00def"),
                          ("plain.bin", bytes(range(256)))])
            self.assertEqual(validate(valid), (3, ""))
            published = base / "published"
            self.assertEqual(extract(valid, published), (3, ""))
            self.assertEqual((published / "dir/naïve.txt").read_bytes(),
                             b"abc\x00def")
            self.assertEqual((published / "plain.bin").read_bytes(),
                             bytes(range(256)))
            self.assertEqual(extract(valid, published)[0], -1)
            self.assertEqual((published / "plain.bin").read_bytes(),
                             bytes(range(256)))
            raced = base / "raced"
            competitor_errors: list[str] = []

            def create_competitor() -> None:
                deadline = time.monotonic() + 3
                while not list(base.glob(".gene-archive-*")):
                    if time.monotonic() > deadline:
                        competitor_errors.append("staging directory never appeared")
                        return
                    time.sleep(0.001)
                try:
                    raced.mkdir()
                    (raced / "winner.txt").write_text("competitor")
                except OSError as error:
                    competitor_errors.append(str(error))

            competitor = threading.Thread(target=create_competitor)
            competitor.start()
            race_result = extract(valid, raced)
            competitor.join(timeout=3)
            self.assertEqual(competitor_errors, [])
            self.assertEqual(race_result[0], -1)
            self.assertIn("exclusive ZIP destination", race_result[1])
            self.assertEqual((raced / "winner.txt").read_text(), "competitor")
            async_output = base / "async_output"
            (base / "input.zip").write_bytes(valid)
            job = library.gene_archive_zip_job_start(
                os.fsencode(base / "input.zip"), os.fsencode(async_output))
            self.assertTrue(job)
            try:
                deadline = time.monotonic() + 5
                while (status := library.gene_archive_zip_job_poll(job)) == 0:
                    self.assertLess(time.monotonic(), deadline)
                    time.sleep(0.001)
                self.assertEqual(status, 4)
            finally:
                library.gene_archive_zip_job_release(job)
            self.assertEqual((async_output / "plain.bin").read_bytes(),
                             bytes(range(256)))
            cancelled_output = base / "cancelled_output"
            job = library.gene_archive_zip_job_start(
                os.fsencode(base / "input.zip"), os.fsencode(cancelled_output))
            self.assertTrue(job)
            try:
                deadline = time.monotonic() + 5
                while not list(base.glob(".gene-archive-*")):
                    self.assertLess(time.monotonic(), deadline)
                    time.sleep(0.001)
                library.gene_archive_zip_job_cancel(job)
                while (status := library.gene_archive_zip_job_poll(job)) == 0:
                    self.assertLess(time.monotonic(), deadline)
                    time.sleep(0.001)
                self.assertEqual(status, -2)
                self.assertIn("cancelled",
                              library.gene_archive_zip_job_error(job).decode())
            finally:
                library.gene_archive_zip_job_release(job)
            self.assertFalse(cancelled_output.exists())
            jobs: list[int] = []
            for i in range(16):
                job = library.gene_archive_zip_job_start(
                    os.fsencode(base / "input.zip"),
                    os.fsencode(base / f"bounded-{i}"))
                self.assertTrue(job)
                jobs.append(job)
            self.assertFalse(library.gene_archive_zip_job_start(
                os.fsencode(base / "input.zip"),
                os.fsencode(base / "seventeenth")))
            for job in jobs:
                library.gene_archive_zip_job_release(job)
            implicit = make([("nested/first", b"a"), ("nested/", b"")])
            self.assertEqual(extract(implicit, base / "implicit"), (2, ""))
            self.assertEqual((base / "implicit/nested/first").read_bytes(), b"a")
            self.assertEqual(validate(make([("plain.txt", b"hi")],
                                           zipfile.ZIP_STORED)), (1, ""))

            class Unseekable(io.BytesIO):
                def seek(self, *_args, **_kwargs):
                    raise OSError("stream is not seekable")

            streamed = Unseekable()
            with zipfile.ZipFile(streamed, "w", compression=zipfile.ZIP_DEFLATED) as z:
                z.writestr("streamed.txt", b"streamed payload" * 20)
            self.assertEqual(validate(streamed.getvalue()), (1, ""))
            descriptor_changed = bytearray(streamed.getvalue())
            descriptor_at = descriptor_changed.index(b"PK\x07\x08")
            descriptor_changed[descriptor_at + 4] ^= 1
            self.assertIn("descriptor disagrees",
                          validate(bytes(descriptor_changed))[1])

            for unsafe in ("../escape", "/absolute", "dir/../escape",
                           "dir\\file", "dir//file", "./file", "C:drive"):
                with self.subTest(unsafe=unsafe):
                    result, error = validate(make([(unsafe, b"bad")]))
                    self.assertEqual(result, -1)
                    self.assertIn("unsafe ZIP path", error)
            result, error = validate(make([("A.txt", b"a"), ("a.txt", b"b")]))
            self.assertEqual(result, -1)
            self.assertIn("duplicate normalized ZIP path", error)
            for names in (("é.txt", "e\u0301.txt"),
                          ("Straße.txt", "STRASSE.txt")):
                result, error = validate(make([(names[0], b"a"),
                                               (names[1], b"b")]))
                self.assertEqual(result, -1)
                self.assertIn("duplicate normalized ZIP path", error)
            for names in (("É/one.txt", "e\u0301/two.txt"),
                          ("A/one.txt", "a/two.txt")):
                result, error = validate(make([(names[0], b"a"),
                                               (names[1], b"b")]))
                self.assertEqual(result, -1)
                self.assertIn("directory component", error)

            symlink = zipfile.ZipInfo("link")
            symlink.create_system = 3
            symlink.external_attr = 0o120777 << 16
            out = io.BytesIO()
            with zipfile.ZipFile(out, "w") as z:
                z.writestr(symlink, "target")
            self.assertIn("link, device", validate(out.getvalue())[1])
            self.assertEqual(extract(out.getvalue(), base / "symlink_out")[0], -1)
            self.assertFalse((base / "symlink_out").exists())

            def modify(data: bytes, *, central_offset: int, local_offset: int,
                       width: int, value: int) -> bytes:
                changed = bytearray(data)
                fmt = {2: "<H", 4: "<I"}[width]
                struct.pack_into(fmt, changed, changed.index(b"PK\x01\x02") +
                                 central_offset, value)
                struct.pack_into(fmt, changed, local_offset, value)
                return bytes(changed)

            ordinary = make([("safe.txt", b"payload")])
            # Both headers must agree, but shared unsupported flags still fail.
            encrypted = modify(ordinary, central_offset=8, local_offset=6,
                               width=2, value=1)
            self.assertIn("unsupported feature", validate(encrypted)[1])
            method = modify(ordinary, central_offset=10, local_offset=8,
                            width=2, value=12)
            self.assertIn("unsupported feature", validate(method)[1])
            oversized = modify(ordinary, central_offset=24, local_offset=22,
                               width=4, value=128 * 1024 * 1024 + 1)
            self.assertIn("size cap", validate(oversized)[1])
            zip64 = bytearray(ordinary)
            end_at = zip64.rindex(b"PK\x05\x06")
            struct.pack_into("<H", zip64, end_at + 10, 0xffff)
            self.assertIn("ZIP64", validate(bytes(zip64))[1])
            wrong_crc = bytearray(ordinary)
            central_at = wrong_crc.index(b"PK\x01\x02")
            wrong_crc[central_at + 16] ^= 1
            self.assertIn("checksum", validate(bytes(wrong_crc))[1])
            wrong_crc_both = bytearray(ordinary)
            wrong_crc_both[14] ^= 1
            wrong_crc_both[central_at + 16] ^= 1
            damaged_destination = base / "damaged"
            self.assertEqual(extract(bytes(wrong_crc_both), damaged_destination)[0],
                             -1)
            self.assertFalse(damaged_destination.exists())
            bomb = bytearray(make([("bomb.bin", b"x" * (2 * 1024 * 1024))]))
            bomb_central = bomb.index(b"PK\x01\x02")
            struct.pack_into("<I", bomb, 22, 1)
            struct.pack_into("<I", bomb, bomb_central + 24, 1)
            self.assertEqual(extract(bytes(bomb), base / "bomb_out")[0], -1)
            self.assertFalse((base / "bomb_out").exists())
            real_parent = base / "real_parent"
            real_parent.mkdir()
            (base / "linked_parent").symlink_to(real_parent, target_is_directory=True)
            self.assertEqual(extract(valid, base / "linked_parent/out")[0], -1)
            self.assertFalse((real_parent / "out").exists())
            truncated = ordinary[:-5]
            self.assertEqual(validate(truncated)[0], -1)
            changed = bytearray(ordinary)
            name_at = changed.index(b"safe.txt")
            changed[name_at] = 0xff
            self.assertEqual(validate(bytes(changed))[0], -1)
            self.assertEqual(validate(b"not a ZIP archive")[0], -1)
            self.assertEqual(list(base.glob(".gene-archive-*")), [])


if __name__ == "__main__":
    unittest.main()
