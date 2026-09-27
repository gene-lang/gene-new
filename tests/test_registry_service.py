#!/usr/bin/env python3
"""Persistent registry admission, restart, and existing HTTPS CLI integration."""
from __future__ import annotations

import base64
import hashlib
import http.client
import os
import pathlib
import platform
import re
import select
import shutil
import socket
import ssl
import subprocess
import tempfile
import time
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
TOKEN = "owner-token-0123456789"


class RegistryServiceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not all(shutil.which(x) for x in ("nim", "openssl", "pkg-config")):
            raise unittest.SkipTest("Nim, OpenSSL, or pkg-config unavailable")
        library = subprocess.check_output(
            ["pkg-config", "--variable=libdir", "openssl"], text=True).strip()
        cls.crypto = pathlib.Path(library) / (
            "libcrypto.3.dylib" if platform.system() == "Darwin" else "libcrypto.so.3")
        if not cls.crypto.is_file():
            raise unittest.SkipTest("OpenSSL 3 adapter unavailable")
        cls.build_temp = tempfile.TemporaryDirectory(prefix="gene-registry-build-")
        cls.binaries = pathlib.Path(cls.build_temp.name)
        for name, source in (
            ("server", "src/gene_registry.nim"),
            ("fixture", "tests/fixtures/registry_release_fixture.nim"),
            ("verifier", "tests/fixtures/registry_release_probe.nim"),
            ("gene", "src/gene.nim"),
        ):
            result = subprocess.run(
                ["nim", "c", "--path:src", "--hints:off", *(
                    ["-d:geneRegistryFaultInjection"] if name == "server" else []), *(
                    ["-d:useMalloc", "--passC:-fsanitize=address", "--passL:-fsanitize=address"]
                    if name == "server" and os.environ.get("GENE_REGISTRY_ASAN") == "1" else []),
                 f"--nimcache:{cls.binaries / ('cache-' + name)}",
                 f"-o:{cls.binaries / name}", source], cwd=ROOT,
                capture_output=True, text=True, timeout=180)
            if result.returncode:
                raise RuntimeError(result.stdout + result.stderr)

    @classmethod
    def tearDownClass(cls):
        cls.build_temp.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="gene-registry-service-")
        self.base = pathlib.Path(self.temp.name)
        self.package = self.base / "package"
        (self.package / "src").mkdir(parents=True)
        (self.package / "package.gene").write_text('''
{^format 1 ^name "acme/release" ^version "1.2.3"
 ^library {^entry "src/index.gene"}
 ^files {^include ["package.gene" "src/**"]}}
''')
        (self.package / "src/index.gene").write_text("(let value 42)\n")
        self.release = self.base / "release"
        self.generate(self.release)
        self.digest = (self.release / "digest.txt").read_text()
        self.registry_key = bytes.fromhex((self.release / "registry-key.hex").read_text())
        self.owner_key = bytes.fromhex((self.release / "owner-key.hex").read_text())
        self.token = self.base / "owner.token"
        self.token.write_text(TOKEN + "\n")
        os.chmod(self.token, 0o600)
        self.config = self.base / "service.gene"
        self.config.write_text(
            "{^registry_service_format 1 "
            f'^root "{self.base / "store"}" ^port 0 '
            f'^registry_key "{base64.b64encode(self.registry_key).decode()}" '
            f'^crypto "{self.crypto}" ^request_timeout_ms 1000 '
            "^max_object_bytes 1048576 ^stage_ttl_seconds 60 "
            '^publishers [{^owner "acme" '
            f'^public_keys ["{base64.b64encode(self.owner_key).decode()}"] '
            f'^token_file "{self.token}"}}] '
            '^delegations [{'
            f'^record_file "{self.release / "owner-record.gene"}" '
            f'^signature_file "{self.release / "owner-record.sig"}"}}]}}')
        self.server = None
        self.start()

    def tearDown(self):
        self.stop()
        self.temp.cleanup()

    def generate(self, directory):
        result = subprocess.run(
            [str(self.binaries / "fixture"), str(self.package),
             str(self.crypto), str(directory)], cwd=ROOT, capture_output=True,
            text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)

    def start(self, failpoint=""):
        self.log = open(self.base / "server.log", "a+")
        self.server = subprocess.Popen(
            [str(self.binaries / "server"), "--config", str(self.config)],
            cwd=ROOT, stdout=subprocess.PIPE, stderr=self.log, text=True,
            env=dict(os.environ, GENE_REGISTRY_FAILPOINT=failpoint))
        ready, _, _ = select.select([self.server.stdout], [], [], 10)
        line = self.server.stdout.readline() if ready else ""
        match = re.fullmatch(r"registry listening 127\.0\.0\.1:(\d+)\n", line)
        if not match:
            self.stop()
            self.fail((self.base / "server.log").read_text() + line)
        self.port = int(match.group(1))

    def stop(self, crash=False):
        if self.server is not None:
            was_running = self.server.poll() is None
            if was_running:
                if crash: self.server.kill()
                else: self.server.terminate()
            status = self.server.wait(timeout=5)
            self.server.stdout.close()
            self.server = None
            self.log.close()
            if was_running and not crash:
                self.assertEqual(status, 0, (self.base / "server.log").read_text())

    def request(self, method, path, body=None, token=TOKEN):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        try:
            headers = {"Authorization": "Bearer " + token} if token else {}
            connection.request(method, path, body=body, headers=headers)
            response = connection.getresponse()
            return response.status, response.read()
        finally:
            connection.close()

    def stage(self, release=None, objects=True, version="1.2.3"):
        release = release or self.release
        digest = (release / "digest.txt").read_text()
        prefix = "/v1/staging/acme/release/" + version
        if objects:
            for row in (release / "objects.tsv").read_text().splitlines():
                address, relative = row.split("\t")
                result = self.request("PUT", prefix + "/objects/" + address[7:],
                                      (self.package / relative).read_bytes())
                self.assertIn(result[0], (200, 201), result)
        for kind, filename in (("index", "index.gene"),
                               ("signature", "owner-signature.gene")):
            result = self.request("PUT", prefix + "/" + kind + "/" + digest[7:],
                                  (release / filename).read_bytes())
            self.assertIn(result[0], (200, 201), result)
        return digest

    def commit(self, digest=None, version="1.2.3"):
        digest = digest or self.digest
        return self.request("POST", "/v1/publish/acme/release/" + version,
            f'{{^publish_format 1 ^index_digest "{digest}"}}'.encode())

    def test_complete_publication_restart_yank_and_idempotence(self):
        self.assertEqual(self.request("GET", "/v1/packages/acme/release/versions/0")[0], 200)
        self.stage()
        self.assertEqual(self.request("GET", "/v1/releases/" + self.digest[7:] + "/index")[0], 404)
        self.assertEqual(self.commit()[0], 201)
        self.assertEqual(self.commit()[0], 200)
        self.assertEqual(list((self.base / "store/staging").iterdir()), [])
        self.stop(crash=True)  # unclean process exit after durable commit
        self.start()
        self.assertEqual(self.request("GET", "/health"), (200, b"ok\n"))
        index = self.request("GET", "/v1/releases/" + self.digest[7:] + "/index")
        self.assertEqual(index[0], 200)
        self.assertIn(b'^name "acme/release"', index[1])
        listing = self.request("GET", "/v1/packages/acme/release/versions/0")
        self.assertIn(self.digest.encode(), listing[1])
        self.assertIn(b"^page_count 1", listing[1])
        self.assertEqual(self.request("POST", "/v1/yank/acme/release/1.2.3",
                                      b"{^yank_format 1 ^yanked true}")[0], 200)
        self.assertEqual(self.commit()[0], 200)
        self.assertIn(b"^^yanked", self.request("GET", "/v1/packages/acme/release/versions/0")[1])
        for row in (self.release / "objects.tsv").read_text().splitlines():
            digest, path = row.split("\t")
            self.assertEqual(self.request("GET", "/v1/objects/" + digest[7:]),
                              (200, (self.package / path).read_bytes()))

    def test_missing_objects_bad_signature_conflict_and_retry(self):
        self.stage(objects=False)
        self.assertEqual(self.commit()[0], 400)
        self.assertNotIn(self.digest.encode(), self.request("GET", "/v1/packages/acme/release/versions/0")[1])
        self.stop(crash=True)
        self.start()  # staged data survives a crash and supports retry
        self.stage()
        self.assertEqual(self.commit()[0], 201)
        (self.package / "src/index.gene").write_text("(let value 43)\n")
        changed = self.base / "changed"
        self.generate(changed)
        digest = self.stage(changed)
        self.assertNotEqual(digest, self.digest)
        self.assertEqual(self.commit(digest)[0], 409)
        self.assertIn(self.digest.encode(), self.request("GET", "/v1/packages/acme/release/versions/0")[1])
        self.assertEqual(self.request("PUT", "/v1/staging/acme/release/1.2.3/objects/" + "0"*64,
                                      b"wrong digest")[0], 400)
        self.assertEqual(self.request("PUT", "/v1/staging/acme/release/1.2.3/signature/" + digest[7:],
                                      b"{}")[0], 400)
        forged = re.sub(rb'\^signature "[^"]+"',
            b'^signature "' + base64.b64encode(bytes(64)) + b'"',
            (changed / "owner-signature.gene").read_bytes())
        self.assertEqual(self.request("PUT", "/v1/staging/acme/release/1.2.3/signature/" + digest[7:],
                                      forged)[0], 400)

    def test_owner_authentication_bounds_and_single_writer(self):
        path = "/v1/staging/acme/release/1.2.3/objects/" + "0"*64
        self.assertEqual(self.request("PUT", path, b"", token="wrong-token")[0], 403)
        self.assertEqual(self.request("PUT", path.replace("/acme/", "/other/"), b"")[0], 403)
        self.assertEqual(self.request("GET", "/v1/objects/../registry-key")[0], 400)
        self.assertEqual(self.request("GET", "/v1/objects/%2e%2e")[0], 400)
        duplicate = subprocess.run([str(self.binaries / "server"), "--config", str(self.config)],
            capture_output=True, text=True, timeout=5)
        self.assertEqual(duplicate.returncode, 2)
        for framing in ("Content-Length: 1048577\r\n",
                        "Transfer-Encoding: chunked\r\n",
                        "Content-Length: 0\r\nContent-Length: 0\r\n"):
            with socket.create_connection(("127.0.0.1", self.port), timeout=5) as connection:
                connection.sendall((f"PUT {path} HTTP/1.1\r\nHost: local\r\n"
                    f"Authorization: Bearer {TOKEN}\r\n" + framing + "\r\n").encode())
                status = connection.recv(4096)
                self.assertRegex(status, rb"HTTP/1\.1 (400|413) ")
        with socket.create_connection(("127.0.0.1", self.port), timeout=5) as connection:
            connection.sendall((f"PUT {path} HTTP/1.1\r\nHost: local\r\n"
                f"Authorization: Bearer {TOKEN}\r\nContent-Length: 20\r\n\r\nshort").encode())
            connection.shutdown(socket.SHUT_WR)
            self.assertIn(b" 400 ", connection.recv(4096))
        self.assertEqual(list((self.base / "store/tmp").iterdir()), [])
        self.assertEqual(self.request("GET", "/health")[0], 200)

    def test_staging_limits_expiry_and_unsafe_storage(self):
        self.stop()
        self.config.write_text(self.config.read_text().replace("^port 0", "^port 0 ^max_stages 1"))
        self.start()
        digest = hashlib.sha256(b"x").hexdigest()
        path = "/v1/staging/acme/release/1.2.3/objects/" + digest
        self.assertEqual(self.request("PUT", path, b"x")[0], 201)
        self.assertEqual(self.request("PUT", path.replace("1.2.3", "1.2.4"), b"x")[0], 429)
        stage = next((self.base / "store/staging").iterdir())
        os.utime(stage / "touched", (time.time()-120, time.time()-120))
        self.assertEqual(self.request("PUT", path.replace("1.2.3", "1.2.4"), b"x")[0], 201)
        self.stop()
        (self.base / "store/objects/unsafe").symlink_to(self.token)
        bad = subprocess.run([str(self.binaries / "server"), "--config", str(self.config)],
            capture_output=True, text=True, timeout=5)
        self.assertEqual(bad.returncode, 2)
        self.assertIn("symlink", bad.stderr)

    def test_offline_key_provisioning_and_delegation(self):
        self.stop()
        registry, owner, delegation = (self.base / name for name in
                                       ("registry-keys", "owner-keys", "delegation"))
        def provision(*args):
            result = subprocess.run([str(self.binaries / "server"), *args],
                capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)
        for directory in (registry, owner):
            provision("keygen", "--crypto", str(self.crypto), "--out", str(directory))
            self.assertEqual((directory / "private.seed").stat().st_mode & 0o777, 0o600)
            self.assertEqual(len((directory / "private.seed").read_bytes()), 32)
        provision("delegate", "--crypto", str(self.crypto), "--registry-key",
            str(registry / "private.seed"), "--owner", "acme", "--owner-key",
            str(owner / "public.key"), "--out", str(delegation))
        config = self.config.read_text().replace(str(self.base / "store"), str(self.base / "new-store"))
        config = config.replace(base64.b64encode(self.registry_key).decode(),
                                (registry / "public-key.base64").read_text().strip())
        config = config.replace(base64.b64encode(self.owner_key).decode(),
                                (owner / "public-key.base64").read_text().strip())
        config = config.replace(str(self.release / "owner-record.gene"), str(delegation / "owner-record.gene"))
        config = config.replace(str(self.release / "owner-record.sig"), str(delegation / "owner-record.sig"))
        self.config.write_text(config)
        self.start()
        record = (delegation / "owner-record.gene").read_bytes()
        key_id = re.search(rb'\^key_id "sha256:([0-9a-f]{64})"', record).group(1).decode()
        prefix = "/v1/owners/acme/keys/" + key_id
        self.assertEqual(self.request("GET", prefix + "/record"), (200, record))
        self.assertEqual(self.request("GET", prefix + "/signature"),
            (200, (delegation / "owner-record.sig").read_bytes()))

    def test_storage_budget_and_request_deadline_recover_admission(self):
        self.stop()
        self.config.write_text(self.config.read_text().replace("^port 0", "^port 0 ^max_storage_bytes 1"))
        self.start()
        path = "/v1/staging/acme/release/1.2.3/objects/" + "0"*64
        self.assertEqual(self.request("PUT", path, b"")[0], 507)
        self.assertEqual(self.request("GET", "/health")[0], 200)

        self.stop()
        self.config.write_text(self.config.read_text().replace("^max_storage_bytes 1", "^max_storage_bytes 1048576"))
        self.start()
        with socket.create_connection(("127.0.0.1", self.port), timeout=5) as connection:
            connection.sendall((f"PUT {path} HTTP/1.1\r\nHost: local\r\n"
                f"Authorization: Bearer {TOKEN}\r\nContent-Length: 20\r\n\r\n").encode())
            self.assertIn(b" 408 ", connection.recv(4096))
        self.assertEqual(list((self.base / "store/tmp").iterdir()), [])
        self.assertEqual(self.request("GET", "/health")[0], 200)

    def test_crashes_during_commit_never_select_a_partial_release(self):
        for number, checkpoint in enumerate(("objects_durable", "release_durable", "version_selected"), 10):
            version = f"1.2.{number}"
            manifest = self.package / "package.gene"
            manifest.write_text(re.sub(r'\^version "[^"]+"', f'^version "{version}"', manifest.read_text()))
            release = self.base / f"release-{number}"
            self.generate(release)
            digest = self.stage(release, version=version)
            self.stop()
            self.start(failpoint=checkpoint)
            with self.assertRaises((http.client.RemoteDisconnected, ConnectionResetError)):
                self.commit(digest, version=version)
            self.assertEqual(self.server.wait(timeout=5), 73)
            self.stop()
            self.start()
            listing = self.request("GET", "/v1/packages/acme/release/versions/0")[1]
            if checkpoint == "version_selected": self.assertIn(digest.encode(), listing)
            else: self.assertNotIn(digest.encode(), listing)
            self.assertIn(self.commit(digest, version=version)[0], (200, 201))
            self.assertEqual(list((self.base / "store/tmp").iterdir()), [])

    def test_existing_cli_publishes_resolves_and_installs_through_tls(self):
        if not shutil.which("caddy") or not shutil.which("curl"):
            self.skipTest("Caddy and curl are needed for the TLS deployment probe")
        cert, key = self.base / "tls.crt", self.base / "tls.key"
        made = subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
            "-days", "1", "-keyout", str(key), "-out", str(cert), "-subj", "/CN=127.0.0.1",
            "-addext", "subjectAltName=IP:127.0.0.1"], capture_output=True, text=True, timeout=20)
        self.assertEqual(made.returncode, 0, made.stderr)
        with socket.socket() as reserved:
            reserved.bind(("127.0.0.1", 0))
            tls_port = reserved.getsockname()[1]
        proxy_config = self.base / "Caddyfile"
        proxy_config.write_text("{\n admin off\n auto_https off\n}\n" +
            f"https://127.0.0.1:{tls_port} {{\n tls {cert} {key}\n"
            f" reverse_proxy 127.0.0.1:{self.port}\n}}\n")
        proxy_log = open(self.base / "proxy.log", "w+")
        proxy = subprocess.Popen([shutil.which("caddy"), "run", "--config", str(proxy_config),
                                  "--adapter", "caddyfile"], stdout=proxy_log, stderr=proxy_log)
        try:
            context = ssl.create_default_context(cafile=str(cert))
            for _ in range(100):
                try:
                    connection = http.client.HTTPSConnection("127.0.0.1", tls_port, context=context, timeout=1)
                    connection.request("GET", "/health")
                    self.assertEqual(connection.getresponse().status, 200)
                    connection.close()
                    break
                except OSError:
                    time.sleep(.05)
            else: self.fail("TLS proxy failed to start")
            client_config = self.base / "registries.gene"
            client_config.write_text('{^registry_config_format 1 ^default "test" ^registries [{^name "test" ' +
                f'^url "https://127.0.0.1:{tls_port}" '
                f'^registry_key "{base64.b64encode(self.registry_key).decode()}" '
                f'^crypto "{self.crypto}" ^curl "{shutil.which("curl")}" ^ca_file "{cert}" '
                f'^cache_root "{self.base / "cache"}" ^publish_token_file "{self.token}"}}]}}')
            seed = self.base / "owner.seed"
            seed.write_bytes(bytes.fromhex("4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb"))
            env = dict(os.environ, GENE_USER_PACKAGES=str(self.base / "packages"),
                       GENE_ARTIFACT_STORE=str(self.base / "artifacts"))
            def command(*args):
                result = subprocess.run([str(self.binaries / "gene"), *args], cwd=ROOT,
                    env=env, capture_output=True, text=True, timeout=90)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                return result
            for _ in range(2):
                command("pkg", "publish", "--package-root", str(self.package),
                        "--registry-config", str(client_config), "--signing-key", str(seed))
            self.assertEqual(list((self.base / "store/staging").iterdir()), [])
            app = self.base / "app"
            (app / "src").mkdir(parents=True)
            (app / "package.gene").write_text('''
{^format 1 ^name "acme/app" ^version "1.0.0"
 ^applications [(application "app" ^entry "src/main.gene")]
 ^dependencies {^release (dep "acme/release" "1.2.3")}}
''')
            (app / "src/main.gene").write_text('(import [value] ^from "." ^pkg "release")\n(fn main [args] : Int ($println value) 0)\n')
            for action in ("resolve", "sync"):
                command("pkg", action, "--package-root", str(app), "--registry-config", str(client_config))
            prefix = self.base / "installed"
            command("install", "app", "--prefix", str(prefix), "--package-root", str(app),
                    "--registry-config", str(client_config))
            shutil.move(app, self.base / "hidden-app")
            shutil.move(self.package, self.base / "hidden-source")
            self.stop()
            launched = subprocess.run([str(prefix / "bin/app")], cwd=self.base,
                env=dict(env, GENE_USER_PACKAGES=str(self.base / "empty-packages"),
                         GENE_ARTIFACT_STORE=str(self.base / "empty-artifacts"),
                         GENE_C_COMPILER=str(self.base / "no-compiler")),
                capture_output=True, text=True, timeout=30)
            self.assertEqual(launched.returncode, 0, launched.stderr)
            self.assertEqual(launched.stdout.strip(), "42")
        finally:
            proxy.kill()
            proxy.wait(timeout=5)
            proxy_log.close()


if __name__ == "__main__":
    unittest.main()
