#!/usr/bin/env python3
"""Install the declared OpenSSL adapter and load it without checkout/compiler."""

from __future__ import annotations

import json
import os
import pathlib
import platform
import shutil
import signal
import socket
import ssl
import subprocess
import tempfile
import time
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
TLS = ROOT / "src/genex/tls"


def invoke(argv: list[str], env: dict[str, str], timeout: int = 180):
    return subprocess.run(argv, cwd=ROOT, env=env, capture_output=True,
                          text=True, timeout=timeout, check=False)


class GenexTlsPackageTests(unittest.TestCase):
    def test_openssl_adapter_survives_offline_install(self) -> None:
        if (platform.system(), platform.machine()) not in {
            ("Darwin", "arm64"), ("Linux", "x86_64")}:
            self.skipTest("native TLS target is unavailable")
        if not all(shutil.which(tool) for tool in
                   ("nim", "cc", "pkg-config", "openssl")):
            self.skipTest("Nim, C compiler, pkg-config, or openssl is unavailable")
        env = dict(os.environ)
        if platform.system() == "Darwin":
            sdk = json.loads((ROOT / "tests/profiles/native-app/"
                              "cli-toolchain.lock.json").read_text())[
                                  "macosx-arm64"]["sdk_root"]
            if not pathlib.Path(sdk).is_dir():
                self.skipTest("pinned macOS SDK is unavailable")
            env["SDKROOT"] = sdk
        version = invoke(["pkg-config", "--modversion", "openssl"], env)
        if version.returncode or int(version.stdout.split(".")[0]) < 3:
            self.skipTest("OpenSSL 3 pkg-config metadata is unavailable")
        with tempfile.TemporaryDirectory(prefix="gene-tls-package-") as tmp:
            base = pathlib.Path(tmp).resolve()
            source = base / "source"
            source.mkdir()
            shutil.copytree(TLS, source / "tls")
            app = source / "app"
            (app / "src").mkdir(parents=True)
            certificate, key = base / "server.crt", base / "server.key"
            cert = invoke(["openssl", "req", "-x509", "-newkey", "rsa:2048",
                           "-nodes", "-days", "1", "-keyout", str(key),
                           "-out", str(certificate), "-subj", "/CN=localhost",
                           "-addext", "subjectAltName=DNS:localhost"], env)
            self.assertEqual(cert.returncode, 0, cert.stderr)
            next_certificate, next_key = base / "next.crt", base / "next.key"
            next_cert = invoke(["openssl", "req", "-x509", "-newkey", "rsa:2048",
                                "-nodes", "-days", "1", "-keyout", str(next_key),
                                "-out", str(next_certificate), "-subj", "/CN=localhost",
                                "-addext", "subjectAltName=DNS:localhost"], env)
            self.assertEqual(next_cert.returncode, 0, next_cert.stderr)
            with socket.socket() as reserved:
                reserved.bind(("127.0.0.1", 0))
                port = reserved.getsockname()[1]
            (app / "package.gene").write_text('''
{^format 1 ^name "acme/tls_installed" ^version "0.1.0"
 ^applications [(application "tls_installed" ^entry "src/main.gene")
                (application "tls_https" ^entry "src/https.gene")]
 ^dependencies {^tls (dep "genex/tls" "0.1.0" ^path "../tls")}}
''')
            (app / "src/main.gene").write_text('''
(import [adapter_abi] ^from "." ^pkg "tls")
(fn main [args] : Int
  ($println ($json/stringify {^abi (adapter_abi)}))
  0)
''')
            (app / "src/https.gene").write_text(f'''
(import $net/http [listen serve text])
(let AsyncReader $io/AsyncReader)
(fn main [args] : Int
  (let server (listen ^host "127.0.0.1" ^port {port}
                ^tls {{^cert_file "{certificate}" ^key_file "{key}"}}))
  (let failed (try
    (await (server .reload_tls
      {{^cert_file "{next_certificate}" ^key_file "{key}"}}))
    false
    catch Error true))
  ($println ($json/stringify {{^failed failed}}))
  (await (server .reload_tls
    {{^cert_file "{next_certificate}" ^key_file "{next_key}"}}))
  (serve server
    (fn [req]
      (var total 0)
      (while true
        (let part (await (req/body .AsyncReader:read 4096)))
        (if ($nil? part) (then (break)))
        (set total (+ total ($binary/size part))))
      (text ($to_str total)))
    ^body_mode "stream" ^max_requests 1)
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
            prefix = base / "prefix"
            installed = invoke([str(gene), "install", "tls_installed",
                                "--prefix", str(prefix), "--package-root",
                                str(app)], env)
            self.assertEqual(installed.returncode, 0,
                             installed.stdout + installed.stderr)
            installed_https = invoke([str(gene), "install", "tls_https",
                                      "--prefix", str(prefix), "--package-root",
                                      str(app)], env)
            self.assertEqual(installed_https.returncode, 0,
                             installed_https.stdout + installed_https.stderr)
            source.rename(base / "source.hidden")
            launch_env = dict(os.environ,
                              GENE_USER_PACKAGES=str(base / "empty-packages"),
                              GENE_ARTIFACT_STORE=str(base / "empty-artifacts"),
                              GENE_C_COMPILER=str(base / "missing-compiler"))
            launch_env.pop("SDKROOT", None)
            launched = invoke([str(prefix / "bin/tls_installed")], launch_env)
            self.assertEqual(launched.returncode, 0,
                             launched.stdout + launched.stderr)
            self.assertEqual(json.loads(launched.stdout), {"abi": 1})
            server = subprocess.Popen([str(prefix / "bin/tls_https")],
                                      cwd=ROOT, env=launch_env,
                                      stdout=subprocess.PIPE,
                                      stderr=subprocess.PIPE, text=True,
                                      start_new_session=True)
            try:
                client = ssl.create_default_context(cafile=str(next_certificate))
                response = b""
                plaintext_rejected = False
                ready_deadline = time.monotonic() + 30
                while time.monotonic() < ready_deadline:
                    if server.poll() is not None:
                        break
                    try:
                        with socket.create_connection(("127.0.0.1", port),
                                                      timeout=0.5) as plaintext:
                            plaintext.sendall(
                                b"GET / HTTP/1.1\r\nhost: localhost\r\n\r\n")
                            try:
                                rejected = plaintext.recv(8192)
                            except (ConnectionResetError, BrokenPipeError,
                                    TimeoutError):
                                rejected = b""
                            self.assertNotIn(b"HTTP/1.1", rejected)
                            plaintext_rejected = True
                            break
                    except (ConnectionRefusedError, TimeoutError):
                        time.sleep(0.1)
                self.assertTrue(plaintext_rejected,
                                "HTTPS server never accepted a plaintext probe")
                wrong_ca = ssl.create_default_context(cafile=str(certificate))
                with self.assertRaises(ssl.SSLError):
                    with socket.create_connection(("127.0.0.1", port),
                                                  timeout=2) as raw:
                        wrong_ca.wrap_socket(raw, server_hostname="localhost")
                for _ in range(100):
                    if server.poll() is not None:
                        break
                    try:
                        with socket.create_connection(("127.0.0.1", port),
                                                      timeout=10) as raw:
                            with client.wrap_socket(raw,
                                                    server_hostname="localhost") as tls:
                                tls.sendall(
                                    b"POST / HTTP/1.1\r\nhost: localhost\r\n"
                                    b"content-length: 32768\r\n\r\n" +
                                    b"x" * 32768)
                                try:
                                    while True:
                                        chunk = tls.recv(8192)
                                        if not chunk:
                                            break
                                        response += chunk
                                except (ConnectionResetError, TimeoutError) as error:
                                    os.killpg(server.pid, signal.SIGKILL)
                                    output, errors = server.communicate(timeout=5)
                                    self.fail(f"TLS streamed upload failed: {error}; "
                                              f"response={response!r}; "
                                              f"exit={server.returncode}; "
                                              f"stdout={output}; stderr={errors}")
                        break
                    except (ConnectionRefusedError, TimeoutError):
                        time.sleep(0.05)
                output, errors = server.communicate(timeout=20)
                self.assertEqual(server.returncode, 0, output + errors)
                self.assertIn('"failed":true', output)
                self.assertIn(b"HTTP/1.1 200 OK", response)
                self.assertTrue(response.endswith(b"32768"), response)
            finally:
                try:
                    os.killpg(server.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                server.communicate(timeout=5)


if __name__ == "__main__":
    unittest.main()
