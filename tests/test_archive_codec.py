#!/usr/bin/env python3
"""Exercise the package's bounded zlib stream ABI with binary chunk edges."""

from __future__ import annotations

import ctypes as C
import json
import os
import pathlib
import platform
import shutil
import subprocess
import tempfile
import unittest
import zlib


ROOT = pathlib.Path(__file__).resolve().parents[1]
CODEC = ROOT / "src/genex/archive/native/codec.c"
CAPACITY = 97


class ArchiveCodecTests(unittest.TestCase):
    def test_binary_streams_flush_finish_and_crc(self) -> None:
        if platform.system() not in {"Darwin", "Linux"} or not shutil.which("cc"):
            self.skipTest("native C compiler is unavailable")
        build_env = dict(os.environ)
        if platform.system() == "Darwin":
            sdk = json.loads((ROOT / "tests/profiles/native-app/"
                              "cli-toolchain.lock.json").read_text())[
                                  "macosx-arm64"]["sdk_root"]
            if not pathlib.Path(sdk).is_dir():
                self.skipTest("pinned macOS SDK is unavailable")
            build_env["SDKROOT"] = sdk
        with tempfile.TemporaryDirectory(prefix="gene-archive-codec-") as tmp:
            library_path = pathlib.Path(tmp) / (
                "libcodec.dylib" if platform.system() == "Darwin" else
                "libcodec.so")
            command = ["cc", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
                       "-dynamiclib" if platform.system() == "Darwin" else
                       "-shared", "-fPIC", str(CODEC), "-lz", "-o",
                       str(library_path)]
            built = subprocess.run(command, capture_output=True, text=True,
                                   check=False, env=build_env)
            self.assertEqual(built.returncode, 0, built.stdout + built.stderr)
            library = C.CDLL(str(library_path))
            library.gene_archive_stream_open.argtypes = [C.c_int]
            library.gene_archive_stream_open.restype = C.c_void_p
            library.gene_archive_stream_step.argtypes = [
                C.c_void_p, C.c_void_p, C.c_size_t, C.c_void_p, C.c_size_t,
                C.c_int, C.POINTER(C.c_size_t), C.POINTER(C.c_size_t)]
            library.gene_archive_stream_step.restype = C.c_int
            library.gene_archive_stream_close.argtypes = [C.c_void_p]
            library.gene_archive_stream_close.restype = C.c_int
            library.gene_archive_stream_feed.argtypes = [C.c_void_p, C.c_void_p,
                                                         C.c_size_t]
            library.gene_archive_stream_feed.restype = C.c_int
            library.gene_archive_stream_action.argtypes = [C.c_void_p, C.c_size_t]
            library.gene_archive_stream_action.restype = C.c_int
            library.gene_archive_stream_pull.argtypes = [C.c_void_p, C.c_void_p,
                                                         C.c_size_t]
            library.gene_archive_stream_pull.restype = C.c_int
            library.gene_archive_stream_error.argtypes = [C.c_void_p]
            library.gene_archive_stream_error.restype = C.c_char_p
            library.gene_archive_live_streams.restype = C.c_uint64
            library.gene_archive_crc32.argtypes = [C.c_uint32, C.c_void_p,
                                                    C.c_size_t]
            library.gene_archive_crc32.restype = C.c_uint32
            self.assertEqual(library.gene_archive_codec_abi(), 1)

            def step(state: int, chunk: bytes, action: int):
                source = C.create_string_buffer(chunk) if chunk else None
                output = C.create_string_buffer(CAPACITY)
                consumed = C.c_size_t()
                produced = C.c_size_t()
                status = library.gene_archive_stream_step(
                    state, source, len(chunk), output, CAPACITY, action,
                    C.byref(consumed), C.byref(produced))
                return status, consumed.value, output.raw[:produced.value]

            def encode(mode: int, payload: bytes, flush: bool) -> bytes:
                state = library.gene_archive_stream_open(mode)
                self.assertTrue(state)
                output = bytearray()
                try:
                    position = 0
                    did_flush = False
                    for _ in range(100_000):
                        if flush and not did_flush and position >= len(payload) // 2:
                            status, consumed, emitted = step(state, b"", 1)
                            self.assertNotEqual(status, 1)
                            self.assertGreaterEqual(status, 0)
                            self.assertEqual(consumed, 0)
                            output += emitted
                            if len(emitted) < CAPACITY:
                                did_flush = True
                            continue
                        chunk = payload[position:position + 73]
                        action = 2 if position + len(chunk) == len(payload) else 0
                        status, consumed, emitted = step(state, chunk, action)
                        self.assertGreaterEqual(
                            status, 0, library.gene_archive_stream_error(state))
                        position += consumed
                        output += emitted
                        if status == 1:
                            self.assertEqual(position, len(payload))
                            self.assertEqual(step(state, b"x", 2)[0], -1)
                            return bytes(output)
                    self.fail("encoder failed to finish within bounded steps")
                finally:
                    self.assertEqual(library.gene_archive_stream_close(state), 0)

            def decode(mode: int, encoded: bytes):
                state = library.gene_archive_stream_open(mode)
                self.assertTrue(state)
                output = bytearray()
                position = 0
                try:
                    for _ in range(100_000):
                        chunk = encoded[position:position + 61]
                        status, consumed, emitted = step(state, chunk, 0)
                        if status < 0:
                            return status, bytes(output)
                        position += consumed
                        output += emitted
                        if status == 1:
                            self.assertEqual(position, len(encoded))
                            return status, bytes(output)
                        if status == 2 and position == len(encoded):
                            return status, bytes(output)
                    self.fail("decoder failed to settle within bounded steps")
                finally:
                    self.assertEqual(library.gene_archive_stream_close(state), 0)

            payload = bytes(range(256)) * 800 + b"\x00tail\xff"
            bounded = library.gene_archive_stream_open(2)
            self.assertTrue(bounded)
            try:
                prefix = C.create_string_buffer(payload[:100])
                self.assertEqual(library.gene_archive_stream_feed(
                    bounded, prefix, 100), 100)
                self.assertEqual(library.gene_archive_stream_feed(
                    bounded, prefix, 100), -1)
                self.assertEqual(library.gene_archive_stream_action(bounded, 2),
                                 -1)
                output = C.create_string_buffer(65536)
                self.assertGreaterEqual(library.gene_archive_stream_pull(
                    bounded, output, 65536), 0)
                self.assertEqual(library.gene_archive_stream_action(bounded, 2),
                                 0)
                for _ in range(10):
                    if library.gene_archive_stream_pull(bounded, output, 65536) == -1:
                        break
                else:
                    self.fail("bounded codec finish did not terminate")
            finally:
                self.assertEqual(library.gene_archive_stream_close(bounded), 0)
            zipped = encode(2, payload, True)
            self.assertEqual(zlib.decompress(zipped, wbits=31), payload)
            self.assertEqual(decode(1, zipped), (1, payload))
            raw = encode(4, payload, False)
            self.assertEqual(zlib.decompress(raw, wbits=-15), payload)
            self.assertEqual(decode(3, raw), (1, payload))
            self.assertNotEqual(decode(1, zipped[:-4])[0], 1)
            damaged = bytearray(zipped)
            damaged[-8] ^= 0x01
            self.assertLess(decode(1, bytes(damaged))[0], 0)
            first = C.create_string_buffer(payload[:100])
            second = C.create_string_buffer(payload[100:])
            crc = library.gene_archive_crc32(0, first, 100)
            crc = library.gene_archive_crc32(crc, second, len(payload) - 100)
            self.assertEqual(crc, zlib.crc32(payload))
            self.assertEqual(library.gene_archive_live_streams(), 0)


if __name__ == "__main__":
    unittest.main()
