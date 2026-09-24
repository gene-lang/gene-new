#!/usr/bin/env python3
"""Qualify OpenSSL context rotation and nonblocking TLS handshake semantics."""

from __future__ import annotations

import ctypes as C
import json
import os
import pathlib
import platform
import queue
import select
import shlex
import shutil
import socket
import ssl
import subprocess
import tempfile
import threading
import time
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
TLS = ROOT / "src/genex/tls/native/tls.c"


class TlsAdapterTests(unittest.TestCase):
    def test_reload_retains_old_sessions_and_client_auth(self) -> None:
        if (platform.system(), platform.machine()) not in {
            ("Darwin", "arm64"), ("Linux", "x86_64")}:
            self.skipTest("native TLS target is unavailable")
        if not all(shutil.which(tool) for tool in
                   ("cc", "pkg-config", "openssl")):
            self.skipTest("C compiler, pkg-config, or openssl is unavailable")
        env = dict(os.environ)
        if platform.system() == "Darwin":
            sdk = json.loads((ROOT / "tests/profiles/native-app/"
                              "cli-toolchain.lock.json").read_text())[
                                  "macosx-arm64"]["sdk_root"]
            if not pathlib.Path(sdk).is_dir():
                self.skipTest("pinned macOS SDK is unavailable")
            env["SDKROOT"] = sdk
        flags = subprocess.run(["pkg-config", "--cflags", "--libs", "openssl"],
                               env=env, capture_output=True, text=True,
                               check=False)
        if flags.returncode:
            self.skipTest("OpenSSL pkg-config metadata is unavailable")
        with tempfile.TemporaryDirectory(prefix="gene-tls-adapter-") as tmp:
            base = pathlib.Path(tmp).resolve()
            library_path = base / ("libtls.dylib" if platform.system() == "Darwin"
                                   else "libtls.so")
            command = ["cc", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
                       "-DGENE_TLS_TEST_PAUSE_BEFORE_RELOAD",
                       "-dynamiclib" if platform.system() == "Darwin" else
                       "-shared", "-fPIC", "-pthread", str(TLS),
                       *shlex.split(flags.stdout), "-o", str(library_path)]
            built = subprocess.run(command, env=env, capture_output=True,
                                   text=True, check=False)
            self.assertEqual(built.returncode, 0, built.stdout + built.stderr)
            lib = C.CDLL(str(library_path))
            lib.gene_tls_server_open.argtypes = [C.c_char_p, C.c_char_p,
                                                  C.c_char_p, C.c_int]
            lib.gene_tls_server_open.restype = C.c_void_p
            lib.gene_tls_server_reload.argtypes = [C.c_void_p, C.c_char_p,
                                                    C.c_char_p, C.c_char_p,
                                                    C.c_int]
            lib.gene_tls_server_reload.restype = C.c_int
            lib.gene_tls_server_close.argtypes = [C.c_void_p]
            lib.gene_tls_reload_start.argtypes = [C.c_void_p, C.c_char_p,
                                                  C.c_char_p, C.c_char_p,
                                                  C.c_int]
            lib.gene_tls_reload_start.restype = C.c_void_p
            lib.gene_tls_reload_poll.argtypes = [C.c_void_p]
            lib.gene_tls_reload_poll.restype = C.c_int
            lib.gene_tls_reload_cancel.argtypes = [C.c_void_p]
            lib.gene_tls_reload_release.argtypes = [C.c_void_p]
            lib.gene_tls_reload_error.argtypes = [C.c_void_p]
            lib.gene_tls_reload_error.restype = C.c_char_p
            lib.gene_tls_connection_open.argtypes = [C.c_void_p, C.c_int]
            lib.gene_tls_connection_open.restype = C.c_void_p
            lib.gene_tls_connection_handshake.argtypes = [C.c_void_p]
            lib.gene_tls_connection_handshake.restype = C.c_int
            lib.gene_tls_connection_read.argtypes = [C.c_void_p, C.c_void_p,
                                                     C.c_size_t,
                                                     C.POINTER(C.c_size_t)]
            lib.gene_tls_connection_read.restype = C.c_int
            lib.gene_tls_connection_write.argtypes = [C.c_void_p, C.c_void_p,
                                                      C.c_size_t,
                                                      C.POINTER(C.c_size_t)]
            lib.gene_tls_connection_write.restype = C.c_int
            lib.gene_tls_connection_close.argtypes = [C.c_void_p]
            lib.gene_tls_last_error.restype = C.c_char_p
            lib.gene_tls_live_contexts.restype = C.c_uint64
            lib.gene_tls_live_connections.restype = C.c_uint64
            self.assertEqual(lib.gene_tls_abi(), 1)

            def cert(name: str) -> tuple[pathlib.Path, pathlib.Path]:
                certificate, key = base / f"{name}.crt", base / f"{name}.key"
                created = subprocess.run(
                    ["openssl", "req", "-x509", "-newkey", "rsa:2048",
                     "-nodes", "-days", "1", "-keyout", str(key), "-out",
                     str(certificate), "-subj", "/CN=localhost", "-addext",
                     "subjectAltName=DNS:localhost"], env=env,
                    capture_output=True, text=True, timeout=20, check=False)
                self.assertEqual(created.returncode, 0, created.stderr)
                return certificate, key

            cert_a, key_a = cert("a")
            cert_b, key_b = cert("b")

            def trust(ca: pathlib.Path, client: tuple[pathlib.Path,
                                                       pathlib.Path] | None = None):
                context = ssl.create_default_context(cafile=str(ca))
                context.minimum_version = ssl.TLSVersion.TLSv1_2
                if client: context.load_cert_chain(*map(str, client))
                return context

            def wait_socket(sock: socket.socket, status: int, deadline: float):
                remaining = deadline - time.monotonic()
                self.assertGreater(remaining, 0)
                select.select([sock] if status == 0 else [],
                              [sock] if status == 2 else [], [], remaining)

            def connect(server: int, client_context: ssl.SSLContext):
                server_sock, client_sock = socket.socketpair()
                server_sock.setblocking(False)
                connection = lib.gene_tls_connection_open(server,
                                                           server_sock.fileno())
                self.assertTrue(connection, lib.gene_tls_last_error())
                answer: queue.Queue[ssl.SSLSocket | Exception] = queue.Queue()

                def handshake_client():
                    try:
                        answer.put(client_context.wrap_socket(
                            client_sock, server_hostname="localhost"))
                    except Exception as error:
                        answer.put(error)
                        client_sock.close()

                peer = threading.Thread(target=handshake_client, daemon=True)
                peer.start()
                deadline = time.monotonic() + 5
                status = 0
                while status in (0, 2):
                    status = lib.gene_tls_connection_handshake(connection)
                    if status in (0, 2): wait_socket(server_sock, status, deadline)
                peer.join(timeout=5)
                self.assertFalse(peer.is_alive())
                client = answer.get_nowait()
                return connection, server_sock, client, status

            def exchange(connection: int, server_sock: socket.socket,
                         client: ssl.SSLSocket, payload: bytes):
                client.sendall(payload)
                output = C.create_string_buffer(65536)
                produced = C.c_size_t()
                deadline = time.monotonic() + 5
                while True:
                    status = lib.gene_tls_connection_read(connection, output,
                                                           65536, C.byref(produced))
                    if status == 1: break
                    self.assertIn(status, (0, 2), lib.gene_tls_last_error())
                    wait_socket(server_sock, status, deadline)
                self.assertEqual(output.raw[:produced.value], payload)
                reply = C.create_string_buffer(b"echo:" + payload)
                consumed = C.c_size_t()
                while True:
                    status = lib.gene_tls_connection_write(
                        connection, reply, len(reply.value), C.byref(consumed))
                    if status == 1: break
                    self.assertIn(status, (0, 2), lib.gene_tls_last_error())
                    wait_socket(server_sock, status, deadline)
                self.assertEqual(consumed.value, len(reply.value))
                self.assertEqual(client.recv(65536), reply.value)

            server = lib.gene_tls_server_open(os.fsencode(cert_a),
                                               os.fsencode(key_a), None, 0)
            self.assertTrue(server, lib.gene_tls_last_error())
            self.assertEqual(lib.gene_tls_live_contexts(), 1)
            old_conn, old_sock, old_client, status = connect(server, trust(cert_a))
            self.assertEqual(status, 1, lib.gene_tls_last_error())
            self.assertIsInstance(old_client, ssl.SSLSocket)
            exchange(old_conn, old_sock, old_client, b"old")

            cancelled = lib.gene_tls_reload_start(
                server, os.fsencode(cert_b), os.fsencode(key_b), None, 0)
            self.assertTrue(cancelled)
            deadline = time.monotonic() + 5
            while lib.gene_tls_live_contexts() != 2:
                self.assertLess(time.monotonic(), deadline)
                time.sleep(0.001)
            lib.gene_tls_reload_cancel(cancelled)
            while (cancel_status := lib.gene_tls_reload_poll(cancelled)) == 0:
                self.assertLess(time.monotonic(), deadline)
                time.sleep(0.001)
            self.assertEqual(cancel_status, -2)
            lib.gene_tls_reload_release(cancelled)
            self.assertEqual(lib.gene_tls_live_contexts(), 1)

            self.assertEqual(lib.gene_tls_server_reload(
                server, os.fsencode(cert_b), os.fsencode(key_a), None, 0), -1)
            self.assertEqual(lib.gene_tls_live_contexts(), 1)
            reloading = lib.gene_tls_reload_start(
                server, os.fsencode(cert_b), os.fsencode(key_b), None, 0)
            self.assertTrue(reloading)
            deadline = time.monotonic() + 5
            while (reload_status := lib.gene_tls_reload_poll(reloading)) == 0:
                self.assertLess(time.monotonic(), deadline)
                time.sleep(0.001)
            self.assertEqual(reload_status, 1,
                             lib.gene_tls_reload_error(reloading))
            lib.gene_tls_reload_release(reloading)
            self.assertEqual(lib.gene_tls_live_contexts(), 2)
            new_conn, new_sock, new_client, status = connect(server, trust(cert_b))
            self.assertEqual(status, 1, lib.gene_tls_last_error())
            self.assertIsInstance(new_client, ssl.SSLSocket)
            exchange(old_conn, old_sock, old_client, b"still-old")
            exchange(new_conn, new_sock, new_client, b"new")
            self.assertNotEqual(old_client.getpeercert(binary_form=True),
                                new_client.getpeercert(binary_form=True))
            old_client.close()
            lib.gene_tls_connection_close(old_conn)
            old_sock.close()
            self.assertEqual(lib.gene_tls_live_contexts(), 1)

            bad_conn, bad_sock, bad_client, status = connect(server, trust(cert_a))
            self.assertNotEqual(status, 1)
            self.assertIsInstance(bad_client, ssl.SSLError)
            lib.gene_tls_connection_close(bad_conn)
            bad_sock.close()
            self.assertEqual(lib.gene_tls_server_reload(
                server, os.fsencode(cert_b), os.fsencode(key_b),
                os.fsencode(cert_a), 1), 0)
            no_cert_conn, no_cert_sock, no_cert_client, status = connect(
                server, trust(cert_b))
            self.assertNotEqual(status, 1)
            if isinstance(no_cert_client, ssl.SSLSocket): no_cert_client.close()
            lib.gene_tls_connection_close(no_cert_conn)
            no_cert_sock.close()
            yes_conn, yes_sock, yes_client, status = connect(
                server, trust(cert_b, (cert_a, key_a)))
            self.assertEqual(status, 1, lib.gene_tls_last_error())
            self.assertIsInstance(yes_client, ssl.SSLSocket)
            exchange(yes_conn, yes_sock, yes_client, b"mutual")
            yes_client.close()
            lib.gene_tls_connection_close(yes_conn)
            yes_sock.close()
            new_client.close()
            lib.gene_tls_connection_close(new_conn)
            new_sock.close()
            lib.gene_tls_server_close(server)
            self.assertEqual(lib.gene_tls_live_connections(), 0)
            self.assertEqual(lib.gene_tls_live_contexts(), 0)

            closing = lib.gene_tls_server_open(os.fsencode(cert_a),
                                                os.fsencode(key_a), None, 0)
            self.assertTrue(closing)
            pending = lib.gene_tls_reload_start(
                closing, os.fsencode(cert_b), os.fsencode(key_b), None, 0)
            self.assertTrue(pending)
            lib.gene_tls_server_close(closing)
            lib.gene_tls_server_close(closing) # still pinned by the reload job
            deadline = time.monotonic() + 5
            while (status := lib.gene_tls_reload_poll(pending)) == 0:
                self.assertLess(time.monotonic(), deadline)
                time.sleep(0.001)
            self.assertEqual(status, -1)
            self.assertIn("closed", lib.gene_tls_reload_error(pending).decode())
            lib.gene_tls_reload_release(pending)
            self.assertEqual(lib.gene_tls_live_contexts(), 0)

            retained = lib.gene_tls_server_open(os.fsencode(cert_a),
                                                 os.fsencode(key_a), None, 0)
            self.assertTrue(retained)
            retained_conn, retained_sock, retained_client, status = connect(
                retained, trust(cert_a))
            self.assertEqual(status, 1)
            lib.gene_tls_server_close(retained)
            self.assertEqual(lib.gene_tls_live_contexts(), 1)
            self.assertIsInstance(retained_client, ssl.SSLSocket)
            exchange(retained_conn, retained_sock, retained_client, b"held")
            retained_client.close()
            lib.gene_tls_connection_close(retained_conn)
            retained_sock.close()
            self.assertEqual(lib.gene_tls_live_contexts(), 0)

            bounded = lib.gene_tls_server_open(os.fsencode(cert_a),
                                                os.fsencode(key_a), None, 0)
            self.assertTrue(bounded)
            jobs = [lib.gene_tls_reload_start(
                bounded, os.fsencode(cert_b), os.fsencode(key_b), None, 0)
                for _ in range(16)]
            self.assertTrue(all(jobs))
            self.assertFalse(lib.gene_tls_reload_start(
                bounded, os.fsencode(cert_b), os.fsencode(key_b), None, 0))
            for job in jobs:
                lib.gene_tls_reload_cancel(job)
                lib.gene_tls_reload_release(job)
            lib.gene_tls_server_close(bounded)
            self.assertEqual(lib.gene_tls_live_contexts(), 0)


if __name__ == "__main__":
    unittest.main()
