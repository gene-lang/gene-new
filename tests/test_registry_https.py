#!/usr/bin/env python3
"""Local TLS registry transport: bounded GET and no implicit redirects/proxy."""

from __future__ import annotations

import http.server
import hashlib
import base64
import os
import pathlib
import platform
import re
import shutil
import ssl
import subprocess
import tempfile
import threading
import time
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    routes: dict[str, bytes] = {}
    staged: dict[tuple[str, str, str], dict[tuple[str, str], bytes]] = {}
    published: dict[tuple[str, str, str], str] = {}
    publish_lock = threading.Lock()
    publish_token = "fixture-token"
    required_objects: set[str] = set()

    def log_message(self, *_args):
        pass

    def respond(self, status: int, body: bytes = b""):
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def upload_body(self):
        length = self.headers.get("Content-Length")
        if length is None or not length.isdigit() or int(length) > 1024 * 1024:
            return None
        return self.rfile.read(int(length))

    def do_PUT(self):
        if self.headers.get("Authorization") != "Bearer " + self.publish_token:
            self.respond(401)
            return
        parts = self.path.split("/")
        if len(parts) != 8 or parts[1:3] != ["v1", "staging"] or (
                parts[6] not in ("objects", "index", "signature")):
            self.respond(404)
            return
        body = self.upload_body()
        if body is None:
            self.respond(400)
            return
        if parts[6] == "objects" and hashlib.sha256(body).hexdigest() != parts[7]:
            self.respond(400)
            return
        owner_version = (parts[3], parts[4], parts[5])
        key = (parts[6], parts[7])
        with self.publish_lock:
            bucket = self.staged.setdefault(owner_version, {})
            previous = bucket.get(key)
            if previous is not None and previous != body:
                self.respond(409)
                return
            bucket[key] = body
        self.respond(200 if previous is not None else 201)

    def do_POST(self):
        if self.headers.get("Authorization") != "Bearer " + self.publish_token:
            self.respond(401)
            return
        parts = self.path.split("/")
        if len(parts) != 6 or parts[1:3] != ["v1", "publish"]:
            self.respond(404)
            return
        body = self.upload_body()
        match = (re.search(rb'\^index_digest "(sha256:[0-9a-f]{64})"', body)
                 if body is not None else None)
        if not match:
            self.respond(400)
            return
        digest = match.group(1).decode()
        owner_version = (parts[3], parts[4], parts[5])
        bucket = self.staged.get(owner_version, {})
        hex_digest = digest.removeprefix("sha256:")
        if ("index", hex_digest) not in bucket or (
                "signature", hex_digest) not in bucket:
            self.respond(400)
            return
        with self.publish_lock:
            previous = self.published.get(owner_version)
            if previous is not None and previous != digest:
                self.respond(409)
                return
            if previous is None and not all(
                    ("objects", object_digest) in bucket
                    for object_digest in self.required_objects):
                self.respond(400)
                return
            self.published[owner_version] = digest
            prefix = "/v1/releases/" + hex_digest
            self.routes[prefix + "/index"] = bucket[("index", hex_digest)]
            self.routes[prefix + "/signature"] = bucket[("signature", hex_digest)]
            for (kind, object_digest), payload in bucket.items():
                if kind == "objects":
                    self.routes["/v1/objects/" + object_digest] = payload
        self.respond(200 if previous is not None else 201)

    def do_GET(self):
        if self.path in self.routes:
            body = self.routes[self.path]
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif self.path == "/ok":
            body = b"release-index"
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif self.path == "/over":
            self.send_response(200)
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(b"x" * 4096)
            self.close_connection = True
        elif self.path == "/truncated":
            self.send_response(200)
            self.send_header("Content-Length", "20")
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(b"short")
            self.close_connection = True
        elif self.path == "/redirect":
            self.send_response(302)
            self.send_header("Location", "/ok")
            self.send_header("Content-Length", "0")
            self.end_headers()
        elif self.path == "/slow":
            time.sleep(2)
            self.send_response(200)
            self.send_header("Content-Length", "1")
            self.end_headers()
            try:
                self.wfile.write(b"x")
            except BrokenPipeError:
                pass
        else:
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()


class RegistryHttpsTests(unittest.TestCase):
    def test_bounded_verified_https(self):
        curl = shutil.which("curl")
        if not all((curl, shutil.which("nim"), shutil.which("openssl"))):
            self.skipTest("curl, Nim, or openssl is unavailable")
        with tempfile.TemporaryDirectory(prefix="gene-registry-https-") as tmp:
            base = pathlib.Path(tmp)
            cert, key = base / "server.crt", base / "server.key"
            created = subprocess.run(
                ["openssl", "req", "-x509", "-newkey", "rsa:2048",
                 "-nodes", "-days", "1", "-keyout", str(key),
                 "-out", str(cert), "-subj", "/CN=127.0.0.1",
                 "-addext", "subjectAltName=IP:127.0.0.1"],
                capture_output=True, text=True, check=False, timeout=20)
            self.assertEqual(created.returncode, 0, created.stderr)
            probe = base / "probe"
            built = subprocess.run(
                ["nim", "c", "--path:src", "--hints:off", f"-o:{probe}",
                 "tests/fixtures/registry_https_probe.nim"],
                cwd=ROOT, capture_output=True, text=True, check=False,
                timeout=120)
            self.assertEqual(built.returncode, 0, built.stderr)
            server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
            server.daemon_threads = True
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(str(cert), str(key))
            server.socket = context.wrap_socket(server.socket, server_side=True)
            Handler.routes = {}
            Handler.staged = {}
            Handler.published = {}
            Handler.required_objects = set()
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                url = f"https://127.0.0.1:{server.server_port}"

                def fetch(path: str, limit=64, ca=cert, timeout=3):
                    return subprocess.run(
                        [str(probe), url, curl, str(ca) if ca else "-",
                         path, str(limit), str(timeout)],
                        cwd=ROOT, capture_output=True, text=True,
                        check=False, timeout=15)

                good = fetch("/ok")
                self.assertEqual(good.returncode, 0, good.stderr)
                self.assertEqual(good.stdout, "release-index")
                for path in ("/over", "/truncated", "/redirect", "/missing"):
                    rejected = fetch(path)
                    self.assertEqual(rejected.returncode, 2,
                                     f"{path}: {rejected.stdout} {rejected.stderr}")
                self.assertEqual(fetch("/ok", ca=None).returncode, 2)
                self.assertEqual(fetch("/slow", timeout=1).returncode, 2)
                self.assertEqual(fetch("/../ok").returncode, 2)
                stage = base / "stage"
                stage.mkdir()
                payload = b"release-index"
                digest = "sha256:" + hashlib.sha256(payload).hexdigest()

                def object_fetch(path, expected_digest=digest,
                                 size=len(payload)):
                    return subprocess.run(
                        [str(probe), url, curl, str(cert), path, str(size),
                         "3", "object", expected_digest, str(stage)],
                        cwd=ROOT, capture_output=True, text=True,
                        check=False, timeout=15)

                object_result = object_fetch("/ok")
                self.assertEqual(object_result.returncode, 0,
                                 object_result.stderr)
                object_path = pathlib.Path(object_result.stdout)
                self.assertEqual(object_path.read_bytes(), payload)
                object_path.unlink()
                for path, expected_digest, size in (
                    ("/ok", "sha256:" + "0" * 64, len(payload)),
                    ("/ok", digest, len(payload) + 1),
                    ("/over", digest, 64),
                    ("/truncated", digest, 20),
                ):
                    rejected = object_fetch(path, expected_digest, size)
                    self.assertEqual(rejected.returncode, 2, rejected.stderr)
                    self.assertEqual(list(stage.iterdir()), [])

                pkg_config = subprocess.run(
                    ["pkg-config", "--variable=libdir", "openssl"],
                    capture_output=True, text=True, check=False)
                if pkg_config.returncode == 0:
                    library = pathlib.Path(pkg_config.stdout.strip()) / (
                        "libcrypto.3.dylib" if platform.system() == "Darwin"
                        else "libcrypto.so.3")
                    if library.is_file():
                        package = base / "package"
                        (package / "src").mkdir(parents=True)
                        (package / "package.gene").write_text('''
{^format 1 ^name "acme/release" ^version "1.2.3"
 ^library {^entry "src/index.gene"}
 ^files {^include ["package.gene" "src/**"]}}
''')
                        (package / "src/index.gene").write_text("(let value 42)\n")
                        fixture = base / "fixture"
                        verifier = base / "verifier"
                        for source, target in (
                            ("registry_release_fixture.nim", fixture),
                            ("registry_release_probe.nim", verifier),
                        ):
                            compiled = subprocess.run(
                                ["nim", "c", "--path:src", "--hints:off",
                                 f"-o:{target}",
                                 f"tests/fixtures/{source}"],
                                cwd=ROOT, capture_output=True, text=True,
                                check=False, timeout=120)
                            self.assertEqual(compiled.returncode, 0,
                                             compiled.stderr)
                        artifacts = base / "release"
                        generated = subprocess.run(
                            [str(fixture), str(package), str(library),
                             str(artifacts)], cwd=ROOT, capture_output=True,
                            text=True, check=False, timeout=15)
                        self.assertEqual(generated.returncode, 0,
                                         generated.stderr)
                        index_digest = (artifacts / "digest.txt").read_text()
                        registry_key = (artifacts / "registry-key.hex").read_text()
                        release_prefix = ("/v1/releases/" +
                                          index_digest.removeprefix("sha256:"))
                        key_id = (artifacts / "owner-key-id.txt").read_text()
                        listing_digest = (
                            artifacts / "listing-digest.txt").read_text()
                        single_listing_digest = (
                            artifacts / "single-listing-digest.txt").read_text()
                        yanked_listing_digest = (
                            artifacts / "yanked-listing-digest.txt").read_text()
                        owner_prefix = ("/v1/owners/acme/keys/" +
                                        key_id.removeprefix("sha256:"))
                        index_bytes = (artifacts / "index.gene").read_bytes()
                        registry_signature = (
                            artifacts / "registry-signature.gene").read_bytes()
                        owner_signature = (
                            artifacts / "owner-signature.gene").read_bytes()
                        delegation = (artifacts / "owner-record.sig").read_bytes()
                        Handler.routes = {
                            release_prefix + "/index": index_bytes,
                            release_prefix + "/signature": registry_signature,
                            owner_prefix + "/record": (
                                artifacts / "owner-record.gene").read_bytes(),
                            owner_prefix + "/signature": delegation,
                        }

                        def verify(key=registry_key, digest=index_digest):
                            return subprocess.run(
                                [str(verifier), url, curl, str(cert),
                                 str(library), key, digest], cwd=ROOT,
                                capture_output=True, text=True, check=False,
                                timeout=15)

                        admitted = verify()
                        self.assertEqual(admitted.returncode, 0,
                                         admitted.stderr)
                        self.assertTrue(admitted.stdout.startswith("registry:"))
                        self.assertEqual(verify(key="00" * 32).returncode, 2)
                        Handler.routes[release_prefix + "/index"] = (
                            index_bytes.replace(b'"1.2.3"', b'"1.2.4"'))
                        self.assertEqual(verify().returncode, 2)
                        Handler.routes[release_prefix + "/index"] = index_bytes
                        Handler.routes[release_prefix + "/signature"] = b"{}"
                        self.assertEqual(verify().returncode, 2)
                        Handler.routes[release_prefix + "/signature"] = owner_signature
                        admitted_owner = verify()
                        self.assertEqual(admitted_owner.returncode, 0,
                                         admitted_owner.stderr)
                        self.assertTrue(admitted_owner.stdout.startswith(
                            "owner:acme:"))
                        Handler.routes[owner_prefix + "/signature"] = b"\0" * 64
                        self.assertEqual(verify().returncode, 2)
                        versions_prefix = (
                            "/v1/packages/acme/release/versions/")

                        def page(number, page_count, entries,
                                 digest=listing_digest):
                            rows = " ".join(
                                "{^version \"%s\" ^index_digest \"%s\" "
                                "^yanked %s}" %
                                (version, index_digest,
                                 "true" if yanked else "false")
                                for version, yanked in entries)
                            return (
                                "{^metadata_format 1 ^name \"acme/release\" "
                                f"^page {number} ^page_count {page_count} "
                                f"^listing_digest \"{digest}\" "
                                f"^releases [{rows}]}}"
                            ).encode()

                        page_zero = page(0, 2, [("1.2.3", False),
                                                ("0.9.0", False)])
                        page_one = page(1, 2, [("2.0.0", True)])
                        Handler.routes[versions_prefix + "0"] = page_zero
                        Handler.routes[versions_prefix + "1"] = page_one
                        listed = verify(digest="versions")
                        self.assertEqual(listed.returncode, 0, listed.stderr)
                        self.assertEqual(listed.stdout.splitlines(),
                                         ["2.0.0:true", "1.2.3:false",
                                          "0.9.0:false"])
                        del Handler.routes[versions_prefix + "1"]
                        self.assertEqual(verify(digest="versions").returncode, 2)
                        Handler.routes[versions_prefix + "1"] = page(
                            1, 2, [("1.2.3", False)])
                        self.assertEqual(verify(digest="versions").returncode, 2)
                        Handler.routes[versions_prefix + "1"] = page(
                            1, 3, [("2.0.0", True)])
                        self.assertEqual(verify(digest="versions").returncode, 2)
                        Handler.routes[versions_prefix + "1"] = page(1, 2, [])
                        self.assertEqual(verify(digest="versions").returncode, 2)
                        Handler.routes[release_prefix + "/signature"] = (
                            registry_signature)
                        object_routes: list[str] = []
                        for row in (artifacts / "objects.tsv").read_text().splitlines():
                            object_digest, relative = row.split("\t", 1)
                            object_route = ("/v1/objects/" +
                                            object_digest.removeprefix("sha256:"))
                            Handler.routes[object_route] = (
                                package / relative).read_bytes()
                            object_routes.append(object_route)
                        trees = base / "trees"
                        trees.mkdir()

                        def tree_fetch():
                            return subprocess.run(
                                [str(verifier), url, curl, str(cert),
                                 str(library), registry_key, index_digest,
                                 "tree", str(trees)], cwd=ROOT,
                                capture_output=True, text=True, check=False,
                                timeout=15)

                        tree_result = tree_fetch()
                        self.assertEqual(tree_result.returncode, 0,
                                         tree_result.stderr)
                        tree_path = pathlib.Path(tree_result.stdout)
                        self.assertEqual((tree_path / "package.gene").read_bytes(),
                                         (package / "package.gene").read_bytes())
                        self.assertEqual((tree_path / "src/index.gene").read_bytes(),
                                         (package / "src/index.gene").read_bytes())
                        shutil.rmtree(tree_path)
                        Handler.routes[object_routes[-1]] = b"corrupt"
                        rejected_tree = tree_fetch()
                        self.assertEqual(rejected_tree.returncode, 2,
                                         rejected_tree.stderr)
                        self.assertEqual(list(trees.iterdir()), [])

                        hosted_probe = base / "hosted-probe"
                        hosted_built = subprocess.run(
                            ["nim", "c", "--path:src", "--hints:off",
                             f"-o:{hosted_probe}",
                             "tests/fixtures/hosted_registry_probe.nim"],
                            cwd=ROOT, capture_output=True, text=True,
                            check=False, timeout=120)
                        self.assertEqual(hosted_built.returncode, 0,
                                         hosted_built.stderr)
                        app = base / "app"
                        (app / "src").mkdir(parents=True)
                        (app / "package.gene").write_text('''
{^format 1 ^name "acme/app" ^version "0.1.0"
 ^applications [(application "app" ^entry "src/main.gene")]
 ^dependencies {^release (dep "acme/release" "1.2.3"
                           ^registry "test")}}
''')
                        (app / "src/main.gene").write_text(
                            "(fn main [args] 0)\n")
                        cache, store = base / "cache", base / "store"
                        cache.mkdir()
                        Handler.routes[object_routes[-1]] = (
                            package / "src/index.gene").read_bytes()
                        Handler.routes[versions_prefix + "0"] = page(
                            0, 1, [("1.2.3", False)], single_listing_digest)
                        Handler.routes.pop(versions_prefix + "1", None)

                        def resolve_and_sync(mode="online"):
                            return subprocess.run(
                                [str(hosted_probe), mode, str(app), str(cache),
                                 str(store), url, curl, str(cert), str(library),
                                 registry_key], cwd=ROOT, capture_output=True,
                                text=True, check=False, timeout=30)

                        Handler.routes[release_prefix + "/signature"] = b"{}"
                        self.assertEqual(resolve_and_sync().returncode, 2)
                        Handler.routes[release_prefix + "/signature"] = (
                            registry_signature)
                        online = resolve_and_sync()
                        self.assertEqual(online.returncode, 0, online.stderr)
                        self.assertEqual(online.stdout, "(let value 42)\n")
                        provenance = (
                            cache / "test/provenance" /
                            (index_digest.removeprefix("sha256:") + ".gene"))
                        self.assertIn("registry:", provenance.read_text())
                        self.assertIn(index_digest, provenance.read_text())
                        saved_routes = Handler.routes.copy()
                        Handler.routes = {}
                        offline = resolve_and_sync("offline")
                        self.assertEqual(offline.returncode, 0,
                                         offline.stderr)
                        self.assertEqual(offline.stdout, online.stdout)
                        Handler.routes = saved_routes
                        Handler.routes[versions_prefix + "0"] = page(
                            0, 1, [("1.2.3", True)], yanked_listing_digest)
                        preserved = resolve_and_sync()
                        self.assertEqual(preserved.returncode, 0,
                                         preserved.stderr)
                        fresh = base / "fresh-app"
                        (fresh / "src").mkdir(parents=True)
                        (fresh / "package.gene").write_text(
                            (app / "package.gene").read_text().replace(
                                '"acme/app"', '"acme/fresh_app"'))
                        shutil.copy2(app / "src/main.gene",
                                     fresh / "src/main.gene")
                        rejected_yanked = subprocess.run(
                            [str(hosted_probe), "online", str(fresh), str(cache),
                             str(store), url, curl, str(cert), str(library),
                             registry_key], cwd=ROOT, capture_output=True,
                            text=True, check=False, timeout=30)
                        self.assertEqual(rejected_yanked.returncode, 2)

                        Handler.routes[versions_prefix + "0"] = page(
                            0, 1, [("1.2.3", False)], single_listing_digest)
                        cli_app = base / "cli-app"
                        (cli_app / "src").mkdir(parents=True)
                        (cli_app / "package.gene").write_text(
                            (app / "package.gene").read_text().replace(
                                '"acme/app"', '"acme/cli_app"'))
                        shutil.copy2(app / "src/main.gene",
                                     cli_app / "src/main.gene")
                        config = base / "registries.gene"
                        config.write_text(
                            "{^registry_config_format 1 ^default \"test\" "
                            "^registries [{^name \"test\" "
                            f"^url \"{url}\" "
                            f"^registry_key \"{base64.b64encode(bytes.fromhex(registry_key)).decode()}\" "
                            f"^curl \"{curl}\" ^crypto \"{library}\" "
                            f"^ca_file \"{cert}\" "
                            f"^cache_root \"{base / 'cli-cache'}\"}}]}}")
                        gene = base / "gene"
                        compiled_gene = subprocess.run(
                            ["nim", "c", "--path:src", "--hints:off",
                             f"-o:{gene}", "src/gene.nim"], cwd=ROOT,
                            capture_output=True, text=True, check=False,
                            timeout=120)
                        self.assertEqual(compiled_gene.returncode, 0,
                                         compiled_gene.stderr)
                        cli_env = dict(os.environ,
                                       GENE_USER_PACKAGES=str(base / "cli-store"))

                        def pkg(command, configured=True, offline=False,
                                config_path=config):
                            args = [str(gene), "pkg", command,
                                    "--package-root", str(cli_app)]
                            if configured:
                                args += ["--registry-config", str(config_path)]
                            if offline:
                                args += ["--offline", "--locked"]
                            return subprocess.run(
                                args, cwd=ROOT, env=cli_env,
                                capture_output=True, text=True,
                                check=False, timeout=30)

                        self.assertNotEqual(pkg("resolve", configured=False).returncode,
                                            0)
                        invalid_config = base / "invalid-registries.gene"
                        invalid_config.write_text(config.read_text().replace(
                            "^registry_config_format 1",
                            "^registry_config_format 1 ^^unexpected"))
                        self.assertNotEqual(pkg("resolve", config_path=invalid_config).returncode,
                                            0)
                        traversal_config = base / "traversal-registries.gene"
                        traversal_config.write_text(config.read_text().replace(
                            '^name "test"', '^name "../escape"'))
                        self.assertNotEqual(pkg("resolve", config_path=traversal_config).returncode,
                                            0)
                        self.assertFalse((base / "escape").exists())
                        resolved_cli = pkg("resolve")
                        self.assertEqual(resolved_cli.returncode, 0,
                                         resolved_cli.stderr)
                        synced_cli = pkg("sync")
                        self.assertEqual(synced_cli.returncode, 0,
                                         synced_cli.stderr)
                        Handler.routes = {}
                        offline_cli = pkg("sync", offline=True)
                        self.assertEqual(offline_cli.returncode, 0,
                                         offline_cli.stderr)
                        built_app = subprocess.run(
                            [str(gene), "build", "app", "--package-root",
                             str(cli_app), "--locked", "--offline",
                             "--registry-config", str(config)], cwd=ROOT,
                            env=cli_env, capture_output=True, text=True,
                            check=False, timeout=120)
                        self.assertEqual(built_app.returncode, 0,
                                         built_app.stderr)
                        prefix = base / "installed"
                        installed_app = subprocess.run(
                            [str(gene), "install", "app", "--prefix",
                             str(prefix), "--package-root", str(cli_app),
                             "--registry-config", str(config)], cwd=ROOT,
                            env=cli_env, capture_output=True, text=True,
                            check=False, timeout=120)
                        self.assertEqual(installed_app.returncode, 0,
                                         installed_app.stderr)
                        launched_app = subprocess.run(
                            [str(prefix / "bin/app")], cwd=base,
                            env=dict(os.environ,
                                GENE_USER_PACKAGES=str(base / "empty-store"),
                                GENE_ARTIFACT_STORE=str(base / "empty-artifacts"),
                                GENE_C_COMPILER=str(base / "missing-compiler")),
                            capture_output=True, text=True, check=False,
                            timeout=30)
                        self.assertEqual(launched_app.returncode, 0,
                                         launched_app.stderr)
                        bad_config = base / "wrong-key.gene"
                        bad_config.write_text(config.read_text().replace(
                            base64.b64encode(bytes.fromhex(registry_key)).decode(),
                            base64.b64encode(b"\0" * 32).decode()))
                        self.assertNotEqual(pkg("sync", offline=True,
                                                config_path=bad_config).returncode,
                                            0)
                        verification = (
                            base / "cli-cache/test/verification" /
                            index_digest.removeprefix("sha256:"))
                        cached_signature = verification / "signature.gene"
                        original_signature = cached_signature.read_bytes()
                        os.chmod(cached_signature, 0o600)
                        cached_signature.write_bytes(b"{}")
                        self.assertNotEqual(pkg("sync", offline=True).returncode,
                                            0)
                        cached_signature.write_bytes(original_signature)
                        self.assertEqual(pkg("sync", offline=True).returncode,
                                         0)
                        mapping = (
                            base / "cli-cache/test/by-version/acme/release/"
                            "1.2.3.digest")
                        original_mapping = mapping.read_bytes()
                        mapping.write_bytes(b"bad\n")
                        malformed_digest = pkg("sync", offline=True)
                        self.assertNotEqual(malformed_digest.returncode, 0)
                        self.assertIn("digest", malformed_digest.stderr)
                        mapping.write_bytes(original_mapping)
                        os.chmod(verification, 0o700)
                        cached_signature.unlink()
                        cached_signature.symlink_to(cert)
                        self.assertNotEqual(pkg("sync", offline=True).returncode,
                                            0)
                        cached_signature.unlink()
                        cached_signature.write_bytes(original_signature)
                        self.assertEqual(pkg("sync", offline=True).returncode,
                                         0)
                        vendored = subprocess.run(
                            [str(gene), "pkg", "vendor", "--package-root",
                             str(cli_app), "--registry-config", str(config),
                             "--offline", "--locked"], cwd=ROOT, env=cli_env,
                            capture_output=True, text=True, check=False,
                            timeout=30)
                        self.assertEqual(vendored.returncode, 0,
                                         vendored.stderr)
                        tree_digest = (artifacts / "tree-digest.txt").read_text()
                        vendor_signature = (
                            cli_app / "vendor/packages/.signatures/test" /
                            tree_digest.removeprefix("sha256:"))
                        self.assertTrue((vendor_signature / "signature.gene").is_file())
                        shutil.move(str(base / "cli-cache"),
                                    str(base / "hidden-cli-cache"))
                        shutil.move(str(base / "cli-store"),
                                    str(base / "hidden-cli-store"))
                        self.assertEqual(pkg("sync", offline=True).returncode,
                                         0)
                        self.assertNotEqual(pkg("sync", offline=True,
                                                config_path=bad_config).returncode,
                                            0)
                        vendor_signature_file = vendor_signature / "signature.gene"
                        original_vendor_signature = vendor_signature_file.read_bytes()
                        os.chmod(vendor_signature, 0o700)
                        os.chmod(vendor_signature_file, 0o600)
                        vendor_signature_file.write_bytes(b"{}")
                        self.assertNotEqual(pkg("sync", offline=True).returncode,
                                            0)
                        vendor_signature_file.write_bytes(original_vendor_signature)
                        self.assertEqual(pkg("sync", offline=True).returncode,
                                         0)

                        token_file = base / "publish.token"
                        token_file.write_text("fixture-token\n")
                        owner_seed_file = base / "owner.seed"
                        owner_seed_file.write_bytes(bytes.fromhex(
                            "4ccd089b28ff96da9db6c346ec114e0f"
                            "5b8a319f35aba624da8cf6ed4fb8a6fb"))
                        owner_key = bytes.fromhex(
                            (artifacts / "owner-key.hex").read_text())
                        publish_config = base / "publish-registries.gene"
                        Handler.required_objects = {
                            row.split("\t", 1)[0].removeprefix("sha256:")
                            for row in (artifacts / "objects.tsv").read_text().splitlines()
                        }
                        publish_config.write_text(
                            "{^registry_config_format 1 ^default \"test\" "
                            "^registries [{^name \"test\" "
                            f"^url \"{url}\" "
                            f"^registry_key \"{base64.b64encode(bytes.fromhex(registry_key)).decode()}\" "
                            f"^curl \"{curl}\" ^crypto \"{library}\" "
                            f"^ca_file \"{cert}\" "
                            f"^cache_root \"{base / 'publish-cache'}\" "
                            f"^publish_token_file \"{token_file}\" "
                            "^pinned_owner_keys {"
                            f"^acme \"{base64.b64encode(owner_key).decode()}\""
                            "}}]}")

                        def publish(config_path=publish_config,
                                    seed=owner_seed_file):
                            return subprocess.run(
                                [str(gene), "pkg", "publish",
                                 "--package-root", str(package),
                                 "--registry-config", str(config_path),
                                 "--signing-key", str(seed)],
                                cwd=ROOT, env=dict(cli_env,
                                    GENE_C_COMPILER=str(base / "no-compiler")),
                                capture_output=True, text=True,
                                check=False, timeout=30)

                        first_publish = publish()
                        self.assertEqual(first_publish.returncode, 0,
                                         first_publish.stderr)
                        self.assertIn(index_digest, first_publish.stdout)
                        self.assertEqual(
                            Handler.published[("acme", "release", "1.2.3")],
                            index_digest)
                        repeated_publish = publish()
                        self.assertEqual(repeated_publish.returncode, 0,
                                         repeated_publish.stderr)
                        Handler.routes[owner_prefix + "/record"] = (
                            artifacts / "owner-record.gene").read_bytes()
                        Handler.routes[owner_prefix + "/signature"] = delegation
                        delegated_config = base / "delegated-publish.gene"
                        delegated_config.write_text(re.sub(
                            r' \^pinned_owner_keys \{\^acme "[^"]+"\}', "",
                            publish_config.read_text()))
                        self.assertEqual(publish(delegated_config).returncode, 0)
                        Handler.routes[owner_prefix + "/signature"] = b"\0" * 64
                        self.assertNotEqual(publish(delegated_config).returncode,
                                            0)
                        Handler.routes[owner_prefix + "/signature"] = delegation
                        (package / "src/index.gene").write_text(
                            "(let value 43)\n")
                        conflict = publish()
                        self.assertNotEqual(conflict.returncode, 0)
                        self.assertIn("PACKAGE_VERSION_CONFLICT",
                                      conflict.stderr)
                        self.assertEqual(
                            Handler.published[("acme", "release", "1.2.3")],
                            index_digest)
                        wrong_token = base / "wrong.token"
                        wrong_token.write_text("wrong-token\n")
                        bad_auth = base / "bad-auth.gene"
                        bad_auth.write_text(publish_config.read_text().replace(
                            str(token_file), str(wrong_token)))
                        self.assertNotEqual(publish(bad_auth).returncode, 0)
            finally:
                server.shutdown()
                server.server_close()
                thread.join(timeout=5)


if __name__ == "__main__":
    unittest.main()
