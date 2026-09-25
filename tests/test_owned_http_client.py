#!/usr/bin/env python3
"""Loopback contract for the reusable net/http_client Client."""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import shutil
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = pathlib.Path(__file__).resolve().parents[1]
ATOMIC_ARC = False
ASAN = False


class Peer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self) -> None:
        super().__init__(("127.0.0.1", 0), Handler)
        self.accepts = 0
        self.accept_lock = threading.Lock()
        self.active = 0
        self.max_active = 0
        self.active_lock = threading.Lock()
        self.redirect_to = ""

    def get_request(self):
        result = super().get_request()
        with self.accept_lock:
            self.accepts += 1
        return result

    def handle_error(self, request, client_address) -> None:
        if isinstance(sys.exc_info()[1], (BrokenPipeError,
                                            ConnectionResetError,
                                            ssl.SSLError)):
            return
        super().handle_error(request, client_address)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self) -> None:
        with self.server.active_lock:
            self.server.active += 1
            self.server.max_active = max(self.server.max_active,
                                         self.server.active)
        try:
            redirects = {
                "/r-relative": (302, "/one"),
                "/r-loop": (301, "/r-loop"),
                "/r-cross": (302, self.server.redirect_to + "/echo-headers"),
                "/r-same": (303, "/echo-headers"),
                "/r-invalid": (302, "ftp://example.invalid/file"),
                "/r-stream": (302, "/stream"),
            }
            if self.path in redirects:
                status, location = redirects[self.path]
                self.send_response(status)
                self.send_header("Location", location)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            if self.path == "/r-missing":
                self.send_response(302)
                self.send_header("Content-Length", "4")
                self.end_headers()
                self.wfile.write(b"stay")
                return
            if self.path == "/echo-headers":
                body = json.dumps({
                    "authorization": self.headers.get("Authorization", ""),
                    "cookie": self.headers.get("Cookie", ""),
                    "x_custom": self.headers.get("X-Custom", ""),
                    "host": self.headers.get("Host", ""),
                }).encode()
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            if self.path == "/slow":
                time.sleep(2)
            elif self.path == "/delay":
                time.sleep(0.4)
            elif self.path == "/r-delay":
                time.sleep(0.4)
                self.send_response(302)
                self.send_header("Location", "/delay")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            elif self.path == "/stream":
                self.send_response(200)
                self.send_header("Content-Length", "6")
                self.end_headers()
                self.wfile.write(b"abc")
                self.wfile.flush()
                time.sleep(0.4)
                try:
                    self.wfile.write(b"def")
                except (BrokenPipeError, ConnectionResetError):
                    pass
                return
            elif self.path == "/stallbody":
                self.send_response(200)
                self.send_header("Content-Length", "4")
                self.end_headers()
                time.sleep(2)
                try:
                    self.wfile.write(b"late")
                except (BrokenPipeError, ConnectionResetError):
                    pass
                return
            elif self.path == "/large":
                body = b"x" * (2 * 1024 * 1024 + 17)
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                try:
                    self.wfile.write(body)
                except (BrokenPipeError, ConnectionResetError):
                    pass
                return
            body = b"short" if self.path == "/short" else self.path.encode("ascii")
            self.send_response(201 if self.path == "/one" else 200)
            if self.path == "/one":
                self.send_header("X-Tag", "first")
                self.send_header("X-Tag", "second")
            self.send_header("Content-Length",
                             "10" if self.path == "/short" else str(len(body)))
            self.end_headers()
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass
            if self.path == "/short":
                self.close_connection = True
        finally:
            with self.server.active_lock:
                self.server.active -= 1

    def do_POST(self) -> None:
        if self.headers.get("Transfer-Encoding", "").lower() == "chunked":
            parts = []
            while True:
                line = self.rfile.readline()
                if not line:
                    self.close_connection = True
                    return
                size = int(line.split(b";", 1)[0], 16)
                if size == 0:
                    self.rfile.readline()
                    break
                parts.append(self.rfile.read(size))
                self.rfile.read(2)
            body = b"".join(parts)
        else:
            body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        if self.path == "/r-post":
            self.send_response(307)
            self.send_header("Location", "/echo-headers")
            self.send_header("Content-Length", "4")
            self.end_headers()
            self.wfile.write(b"stay")
            return
        self.send_response(202)
        self.send_header("Content-Length", str(len(body)))
        if self.path == "/upload-unknown":
            self.send_header("X-Transfer-Encoding",
                             self.headers.get("Transfer-Encoding", ""))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args) -> None:
        pass


class OwnedHttpClientTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.temp = tempfile.TemporaryDirectory(prefix="gene-owned-client-")
        cls.gene = pathlib.Path(cls.temp.name) / "gene"
        command = ["nim", "c", "--path:src", "--hints:off",
                   f"--nimcache:{cls.temp.name}/nimcache",
                   f"-o:{cls.gene}", "src/gene.nim"]
        if ATOMIC_ARC:
            command[2:2] = ["--mm:atomicArc", "--threads:on"]
        if ASAN:
            command[2:2] = ["-d:useMalloc", "--passC:-fsanitize=address",
                            "--passL:-fsanitize=address"]
        built = subprocess.run(command, cwd=ROOT, capture_output=True,
                               text=True, timeout=180)
        if built.returncode:
            raise RuntimeError(built.stdout + built.stderr)

    @classmethod
    def tearDownClass(cls) -> None:
        cls.temp.cleanup()

    def setUp(self) -> None:
        self.peer = Peer()
        self.thread = threading.Thread(target=self.peer.serve_forever,
                                       daemon=True)
        self.thread.start()
        self.base = f"http://127.0.0.1:{self.peer.server_port}"

    def tearDown(self) -> None:
        self.peer.shutdown()
        self.peer.server_close()
        self.thread.join(timeout=3)

    def run_gene(self, statements: str, timeout: float = 10,
                 extra_env: dict[str, str] | None = None) -> tuple[dict, float]:
        script = pathlib.Path(self.temp.name) / "case.gene"
        script.write_text(f"(fn main [args] : Int\n{statements}\n  0)\n")
        started = time.monotonic()
        result = subprocess.run([str(self.gene), "run", str(script)],
                                cwd=ROOT, capture_output=True, text=True,
                                timeout=timeout,
                                env={**os.environ, **(extra_env or {})})
        elapsed = time.monotonic() - started
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(result.stdout.strip().splitlines()), 1,
                         result.stdout)
        return json.loads(result.stdout.strip()), elapsed

    def test_reuse_and_ordered_duplicate_headers(self) -> None:
        data, _ = self.run_gene(f"""
  (let IoResource $io/IoResource)
  (let client (await ($net/http_client/open)))
  (let first (await (client .request ^url "{self.base}/one")))
  (let second (await (client .request ^url "{self.base}/two")))
  (client .IoResource:close)
  (await (client .IoResource:wait_closed))
  ($println ($json/stringify
    {{^first_status first/status ^first_body ($binary/to_str first/body)
      ^second_body ($binary/to_str second/body) ^headers first/headers}}))
""")
        self.assertEqual((data["first_status"], data["first_body"],
                          data["second_body"]), (201, "/one", "/two"))
        self.assertEqual([pair for pair in data["headers"]
                          if pair[0].lower() == "x-tag"],
                         [["X-Tag", "first"], ["X-Tag", "second"]])
        self.assertEqual(self.peer.accepts, 1)

    def test_two_clients_share_the_application_transport(self) -> None:
        data, _ = self.run_gene(f"""
  (let IoResource $io/IoResource)
  (let one (await ($net/http_client/open)))
  (let two (await ($net/http_client/open)))
  (let first (await (one .request ^url "{self.base}/one")))
  (let second (await (two .request ^url "{self.base}/two")))
  (one .IoResource:close)
  (await (one .IoResource:wait_closed))
  (two .IoResource:close)
  (await (two .IoResource:wait_closed))
  ($println ($json/stringify
    {{^first ($binary/to_str first/body)
      ^second ($binary/to_str second/body)}}))
""")
        self.assertEqual(data, {"first": "/one", "second": "/two"})
        self.assertEqual(self.peer.accepts, 1)

    def test_zero_idle_age_forbids_connection_reuse(self) -> None:
        data, _ = self.run_gene(f"""
  (let IoResource $io/IoResource)
  (let client (await ($net/http_client/open ^max_idle_ms 0)))
  (let first (await (client .request ^url "{self.base}/one")))
  (let second (await (client .request ^url "{self.base}/two")))
  (client .IoResource:close)
  (await (client .IoResource:wait_closed))
  ($println ($json/stringify
    {{^first ($binary/to_str first/body)
      ^second ($binary/to_str second/body)}}))
""")
        self.assertEqual(data, {"first": "/one", "second": "/two"})
        self.assertEqual(self.peer.accepts, 2)

    def test_proxy_policy_ignores_environment_by_default(self) -> None:
        data, _ = self.run_gene(f"""
  (let IoResource $io/IoResource)
  (let client (await ($net/http_client/open)))
  (let response (await (client .request ^url "{self.base}/direct")))
  (client .IoResource:close)
  (await (client .IoResource:wait_closed))
  ($println ($json/stringify
    {{^body ($binary/to_str response/body)}}))
""", extra_env={"http_proxy": "http://127.0.0.1:1", "no_proxy": ""})
        self.assertEqual(data, {"body": "/direct"})

    def test_environment_proxy_is_captured_at_open(self) -> None:
        target = "http://example.invalid/proxy"
        data, _ = self.run_gene(f"""
  (let IoResource $io/IoResource)
  (let client (await ($net/http_client/open ^proxy "environment")))
  (let response (await (client .request ^url "{target}")))
  (client .IoResource:close)
  (await (client .IoResource:wait_closed))
  ($println ($json/stringify
    {{^body ($binary/to_str response/body)}}))
""", extra_env={"http_proxy": self.base, "no_proxy": ""})
        self.assertEqual(data, {"body": target})

    def test_binary_upload_and_response(self) -> None:
        data, _ = self.run_gene(f"""
  (let IoResource $io/IoResource)
  (let client (await ($net/http_client/open)))
  (let response (await (client .request ^url "{self.base}/upload"
    ^method "POST" ^body ($binary/from_list [97 0 98])
    ^content_length 3)))
  (client .IoResource:close)
  (await (client .IoResource:wait_closed))
  ($println ($json/stringify
    {{^status response/status ^body ($binary/to_list response/body)}}))
""")
        self.assertEqual(data, {"status": 202, "body": [97, 0, 98]})

    def test_async_reader_upload_known_length_and_caller_ownership(self) -> None:
        data, _ = self.run_gene(f"""
  (let IoResource $io/IoResource)
  (let AsyncReader $io/AsyncReader)
  (let AsyncWriter $io/AsyncWriter)
  (let endpoints ($io/pipe))
  (let reader endpoints/0)
  (let writer endpoints/1)
  (await (writer .AsyncWriter:write ($binary/from_list [97 0 98])))
  (writer .IoResource:close)
  (await (writer .IoResource:wait_closed))
  (let client (await ($net/http_client/open)))
  (let response (await (client .request ^url "{self.base}/upload"
    ^method "POST" ^body reader ^content_length 3)))
  (let eof (await (reader .AsyncReader:read 1)))
  (reader .IoResource:close)
  (await (reader .IoResource:wait_closed))
  (client .IoResource:close)
  (await (client .IoResource:wait_closed))
  (let stats ($runtime/gc_stats))
  ($println ($json/stringify
    {{^status response/status ^body ($binary/to_list response/body)
      ^eof ($nil? eof) ^bytes stats/io_retained_bytes
      ^leases stats/io_cleanup_leases}}))
""")
        self.assertEqual(data, {"status": 202, "body": [97, 0, 98],
                                "eof": True, "bytes": 0, "leases": 0})

    def test_async_reader_upload_unknown_length_uses_chunked(self) -> None:
        data, _ = self.run_gene(f"""
  (let IoResource $io/IoResource)
  (let AsyncWriter $io/AsyncWriter)
  (let endpoints ($io/pipe))
  (let reader endpoints/0)
  (let writer endpoints/1)
  (await (writer .AsyncWriter:write ($binary/from_str "chunked-data")))
  (writer .IoResource:close)
  (await (writer .IoResource:wait_closed))
  (let client (await ($net/http_client/open)))
  (let response (await (client .request
    ^url "{self.base}/upload-unknown" ^method "POST" ^body reader)))
  (reader .IoResource:close)
  (await (reader .IoResource:wait_closed))
  (client .IoResource:close)
  (await (client .IoResource:wait_closed))
  ($println ($json/stringify
    {{^status response/status ^body ($binary/to_str response/body)
      ^headers response/headers}}))
""")
        self.assertEqual(data["status"], 202)
        self.assertEqual(data["body"], "chunked-data")
        self.assertIn(["X-Transfer-Encoding", "chunked"], data["headers"])

    def test_async_reader_upload_rejects_short_and_long_content_length(self) -> None:
        data, _ = self.run_gene(f"""
  (let IoResource $io/IoResource)
  (let AsyncWriter $io/AsyncWriter)
  (let HttpClientError $net/http_client/HttpClientError)
  (let client (await ($net/http_client/open)))
  (let short_pair ($io/pipe))
  (await (short_pair/1 .AsyncWriter:write ($binary/from_str "ab")))
  (short_pair/1 .IoResource:close)
  (await (short_pair/1 .IoResource:wait_closed))
  (let short (try (await (client .request ^url "{self.base}/upload"
    ^method "POST" ^body short_pair/0 ^content_length 3))
    false catch HttpClientError true))
  (short_pair/0 .IoResource:close)
  (await (short_pair/0 .IoResource:wait_closed))
  (let long_pair ($io/pipe))
  (await (long_pair/1 .AsyncWriter:write ($binary/from_str "abcd")))
  (long_pair/1 .IoResource:close)
  (await (long_pair/1 .IoResource:wait_closed))
  (let long (try (await (client .request ^url "{self.base}/upload"
    ^method "POST" ^body long_pair/0 ^content_length 3))
    false catch HttpClientError true))
  (long_pair/0 .IoResource:close)
  (await (long_pair/0 .IoResource:wait_closed))
  (client .IoResource:close)
  (await (client .IoResource:wait_closed))
  ($println ($json/stringify {{^short short ^long long}}))
""", timeout=12)
        self.assertEqual(data, {"short": True, "long": True})

    def test_async_reader_upload_borrow_retires_after_cancel(self) -> None:
        data, _ = self.run_gene(f"""
  (let IoResource $io/IoResource)
  (let IoBusy $io/IoBusy)
  (let endpoints ($io/pipe))
  (let reader endpoints/0)
  (let writer endpoints/1)
  (let client (await ($net/http_client/open)))
  (let first (client .request ^url "{self.base}/upload"
    ^method "POST" ^body reader))
  ($sleep 50)
  (let busy (try (client .request ^url "{self.base}/upload"
    ^method "POST" ^body reader) false catch IoBusy true))
  (first .cancel)
  (first .join)
  (var spins 0)
  (var pending 1)
  (while (< spins 100)
    (if (== pending 0) (then (break)))
    ($sleep 10)
    (let sample ($runtime/gc_stats))
    (set pending sample/http_client_pending_requests)
    (set spins (+ spins 1)))
  (writer .IoResource:close)
  (await (writer .IoResource:wait_closed))
  (let second (await (client .request ^url "{self.base}/upload"
    ^method "POST" ^body reader)))
  (reader .IoResource:close)
  (await (reader .IoResource:wait_closed))
  (client .IoResource:close)
  (await (client .IoResource:wait_closed))
  (let stats ($runtime/gc_stats))
  ($println ($json/stringify
    {{^busy busy ^status second/status ^size ($binary/size second/body)
      ^pending stats/http_client_pending_requests
      ^leases stats/io_cleanup_leases}}))
""", timeout=12)
        self.assertEqual(data, {"busy": True, "status": 202, "size": 0,
                                "pending": 0, "leases": 0})

    def test_async_reader_upload_excludes_direct_caller_reads(self) -> None:
        data, _ = self.run_gene(f"""
  (let AsyncReader $io/AsyncReader)
  (let AsyncWriter $io/AsyncWriter)
  (let IoResource $io/IoResource)
  (let IoBusy $io/IoBusy)
  (let endpoints ($io/pipe))
  (let reader endpoints/0)
  (let writer endpoints/1)
  (let client (await ($net/http_client/open)))
  (let upload (client .request ^url "{self.base}/upload"
    ^method "POST" ^body reader))
  # Before the upload issues any read of its own: only the borrow refuses it.
  (let direct_busy (try (reader .AsyncReader:read 16) false
                     catch IoBusy true))
  (await (writer .AsyncWriter:write ($binary/from_str "body")))
  (writer .IoResource:close)
  (await (writer .IoResource:wait_closed))
  (let response (await upload))
  (let after (await (reader .AsyncReader:read 16)))
  (reader .IoResource:close)
  (await (reader .IoResource:wait_closed))
  (client .IoResource:close)
  (await (client .IoResource:wait_closed))
  (let stats ($runtime/gc_stats))
  ($println ($json/stringify
    {{^busy direct_busy ^status response/status
      ^size ($binary/size response/body) ^after_eof ($nil? after)
      ^pending stats/http_client_pending_requests
      ^leases stats/io_cleanup_leases}}))
""", timeout=12)
        self.assertEqual(data, {"busy": True, "status": 202, "size": 4,
                                "after_eof": True, "pending": 0,
                                "leases": 0})

    def test_response_body_upload_excludes_direct_caller_reads(self) -> None:
        # A Client response body has no I/O lifecycle; its record holds the
        # upload's borrow instead.
        data, _ = self.run_gene(f"""
  (let AsyncReader $io/AsyncReader)
  (let IoResource $io/IoResource)
  (let IoBusy $io/IoBusy)
  (let client (await ($net/http_client/open)))
  (let source (await (client .stream ^url "{self.base}/stream")))
  (let upload (client .request ^url "{self.base}/upload"
    ^method "POST" ^body source/body))
  # Before the upload issues any read of its own: only the borrow refuses it.
  (let direct_busy (try (source/body .AsyncReader:read 16) false
                     catch IoBusy true))
  (let response (await upload))
  (let after (await (source/body .AsyncReader:read 16)))
  (source/body .IoResource:close)
  (await (source/body .IoResource:wait_closed))
  (client .IoResource:close)
  (await (client .IoResource:wait_closed))
  (let stats ($runtime/gc_stats))
  ($println ($json/stringify
    {{^busy direct_busy ^status response/status
      ^body ($binary/to_str response/body) ^after_eof ($nil? after)
      ^pending stats/http_client_pending_requests
      ^leases stats/io_cleanup_leases}}))
""", timeout=12)
        self.assertEqual(data, {"busy": True, "status": 202, "body": "abcdef",
                                "after_eof": True, "pending": 0,
                                "leases": 0})

    def test_large_async_upload_does_not_block_fast_request(self) -> None:
        path = pathlib.Path(self.temp.name) / "upload-large.bin"
        path.write_bytes(b"q" * (2 * 1024 * 1024 + 17))
        data, _ = self.run_gene(f"""
  (let IoResource $io/IoResource)
  (let AsyncReader $io/AsyncReader)
  (let client (await ($net/http_client/open)))
  (let reader (await ($io/open_read "{path}")))
  (let uploading (client .request ^url "{self.base}/upload"
    ^method "POST" ^body reader ^content_length 2097169))
  (let fast (await (client .request ^url "{self.base}/fast")))
  (let response (await uploading))
  (reader .IoResource:close)
  (await (reader .IoResource:wait_closed))
  (client .IoResource:close)
  (await (client .IoResource:wait_closed))
  ($println ($json/stringify
    {{^fast ($binary/to_str fast/body)
      ^upload_size ($binary/size response/body)}}))
""", timeout=15)
        self.assertEqual(data, {"fast": "/fast",
                                "upload_size": 2 * 1024 * 1024 + 17})

    def test_async_upload_and_streamed_response_share_client(self) -> None:
        data, _ = self.run_gene(f"""
  (let IoResource $io/IoResource)
  (let AsyncReader $io/AsyncReader)
  (let AsyncWriter $io/AsyncWriter)
  (let endpoints ($io/pipe))
  (let reader endpoints/0)
  (let writer endpoints/1)
  (await (writer .AsyncWriter:write ($binary/from_str "duplex")))
  (writer .IoResource:close)
  (await (writer .IoResource:wait_closed))
  (let client (await ($net/http_client/open)))
  (let response (await (client .stream ^url "{self.base}/upload"
    ^method "POST" ^body reader)))
  (let body (await (response/body .AsyncReader:read 16)))
  (let eof (await (response/body .AsyncReader:read 1)))
  (reader .IoResource:close)
  (await (reader .IoResource:wait_closed))
  (client .IoResource:close)
  (await (client .IoResource:wait_closed))
  ($println ($json/stringify
    {{^status response/status ^body ($binary/to_str body)
      ^eof ($nil? eof)}}))
""")
        self.assertEqual(data, {"status": 202, "body": "duplex",
                                "eof": True})

    def test_async_upload_byte_cap_and_client_close(self) -> None:
        data, _ = self.run_gene(f"""
  (let IoResource $io/IoResource)
  (let AsyncWriter $io/AsyncWriter)
  (let HttpClientError $net/http_client/HttpClientError)
  (let limited (await ($net/http_client/open
    ^max_stream_body_bytes 3)))
  (let pair ($io/pipe))
  (await (pair/1 .AsyncWriter:write ($binary/from_str "four")))
  (pair/1 .IoResource:close)
  (await (pair/1 .IoResource:wait_closed))
  (let capped (try (await (limited .request ^url "{self.base}/upload"
    ^method "POST" ^body pair/0)) false catch HttpClientError true))
  (pair/0 .IoResource:close)
  (await (pair/0 .IoResource:wait_closed))
  (limited .IoResource:close)
  (await (limited .IoResource:wait_closed))
  (let idle_pair ($io/pipe))
  (let client (await ($net/http_client/open)))
  (let waiting (client .request ^url "{self.base}/upload"
    ^method "POST" ^body idle_pair/0))
  ($sleep 50)
  (client .IoResource:close)
  (let cancelled (match (waiting .join)
    (when TaskOutcome/cancelled true)))
  (await (client .IoResource:wait_closed))
  (idle_pair/0 .IoResource:close)
  (idle_pair/1 .IoResource:close)
  (await (idle_pair/0 .IoResource:wait_closed))
  (await (idle_pair/1 .IoResource:wait_closed))
  (let stats ($runtime/gc_stats))
  ($println ($json/stringify
    {{^capped capped ^cancelled cancelled
      ^pending stats/http_client_pending_requests
      ^bytes stats/io_retained_bytes ^leases stats/io_cleanup_leases}}))
""", timeout=12)
        self.assertEqual(data, {"capped": True, "cancelled": True,
                                "pending": 0, "bytes": 0, "leases": 0})

    def test_short_response_and_byte_limit_fail_instead_of_truncating(self) -> None:
        data, _ = self.run_gene(f"""
  (let IoResource $io/IoResource)
  (let HttpClientError $net/http_client/HttpClientError)
  (let client (await ($net/http_client/open)))
  (let partial (try (await (client .request ^url "{self.base}/short"))
    false catch HttpClientError true))
  (let limited (try (await (client .request ^url "{self.base}/long"
    ^max_bytes 4)) false catch HttpClientError true))
  (client .IoResource:close)
  (await (client .IoResource:wait_closed))
  ($println ($json/stringify
    {{^partial partial ^limited limited}}))
""")
        self.assertEqual(data, {"partial": True, "limited": True})

    def test_stream_headers_precede_body_and_reader_reaches_eof(self) -> None:
        data, _ = self.run_gene(f"""
  (let IoResource $io/IoResource)
  (let AsyncReader $io/AsyncReader)
  (let client (await ($net/http_client/open)))
  (let response (await (client .stream ^url "{self.base}/stream")))
  (let first (await (response/body .AsyncReader:read 3)))
  (let second (await (response/body .AsyncReader:read 3)))
  (let eof (await (response/body .AsyncReader:read 1)))
  (await (response/body .IoResource:wait_closed))
  (client .IoResource:close)
  (await (client .IoResource:wait_closed))
  (let stats ($runtime/gc_stats))
  ($println ($json/stringify
    {{^status response/status ^first ($binary/to_str first)
      ^second ($binary/to_str second) ^eof (== eof nil)
      ^bytes stats/io_retained_bytes ^leases stats/io_cleanup_leases}}))
""")
        self.assertEqual(data, {"status": 200, "first": "abc",
                                "second": "def", "eof": True,
                                "bytes": 0, "leases": 0})

    def test_stream_headers_settle_while_body_is_stalled(self) -> None:
        data, elapsed = self.run_gene(f"""
  (let IoResource $io/IoResource)
  (let client (await ($net/http_client/open)))
  (let response (await (client .stream ^url "{self.base}/stallbody")))
  (response/body .IoResource:close)
  (await (response/body .IoResource:wait_closed))
  (client .IoResource:close)
  (await (client .IoResource:wait_closed))
  ($println ($json/stringify {{^status response/status}}))
""")
        self.assertEqual(data, {"status": 200})
        self.assertLess(elapsed, 1.5)

    def test_stream_short_body_fails_late(self) -> None:
        data, _ = self.run_gene(f"""
  (let IoResource $io/IoResource)
  (let AsyncReader $io/AsyncReader)
  (let HttpClientError $net/http_client/HttpClientError)
  (let client (await ($net/http_client/open)))
  (let response (await (client .stream ^url "{self.base}/short")))
  (let first (await (response/body .AsyncReader:read 16)))
  (let failed (try (await (response/body .AsyncReader:read 1))
    false catch HttpClientError true))
  (await (response/body .IoResource:wait_closed))
  (client .IoResource:close)
  (await (client .IoResource:wait_closed))
  ($println ($json/stringify
    {{^first ($binary/to_str first) ^failed failed}}))
""")
        self.assertEqual(data, {"first": "short", "failed": True})

    def test_paused_stream_allows_another_request_and_resumes(self) -> None:
        data, _ = self.run_gene(f"""
  (let IoResource $io/IoResource)
  (let AsyncReader $io/AsyncReader)
  (let client (await ($net/http_client/open)))
  (let response (await (client .stream ^url "{self.base}/large"
    ^max_bytes 3145728)))
  ($sleep 100)
  (let fast (await (client .request ^url "{self.base}/fast")))
  (var total 0)
  (while true
    (let part (await (response/body .AsyncReader:read 65536)))
    (if ($nil? part) (then (break)))
    (set total (+ total ($binary/size part))))
  (await (response/body .IoResource:wait_closed))
  (client .IoResource:close)
  (await (client .IoResource:wait_closed))
  ($println ($json/stringify
    {{^total total ^fast ($binary/to_str fast/body)}}))
""", timeout=15)
        self.assertEqual(data, {"total": 2 * 1024 * 1024 + 17,
                                "fast": "/fast"})

    def test_stream_byte_limit_is_a_late_reader_error(self) -> None:
        data, _ = self.run_gene(f"""
  (let IoResource $io/IoResource)
  (let AsyncReader $io/AsyncReader)
  (let HttpClientError $net/http_client/HttpClientError)
  (let client (await ($net/http_client/open)))
  (let response (await (client .stream ^url "{self.base}/one"
    ^max_bytes 2)))
  (let failed (try (await (response/body .AsyncReader:read 10))
    false catch HttpClientError true))
  (await (response/body .IoResource:wait_closed))
  (client .IoResource:close)
  (await (client .IoResource:wait_closed))
  ($println ($json/stringify {{^failed failed}}))
""")
        self.assertEqual(data, {"failed": True})

    def test_client_close_cancels_an_active_body_read(self) -> None:
        data, elapsed = self.run_gene(f"""
  (let IoResource $io/IoResource)
  (let AsyncReader $io/AsyncReader)
  (let client (await ($net/http_client/open)))
  (let response (await (client .stream ^url "{self.base}/stallbody")))
  (let reading (response/body .AsyncReader:read 4))
  (client .IoResource:close)
  (let cancelled (match (reading .join)
    (when TaskOutcome/cancelled true)))
  (await (response/body .IoResource:wait_closed))
  (await (client .IoResource:wait_closed))
  (let stats ($runtime/gc_stats))
  ($println ($json/stringify
    {{^cancelled cancelled ^bytes stats/io_retained_bytes
      ^leases stats/io_cleanup_leases
      ^pending stats/http_client_pending_requests}}))
""")
        self.assertEqual(data, {"cancelled": True, "bytes": 0,
                                "leases": 0, "pending": 0})
        self.assertLess(elapsed, 1.5)

    def test_redirect_relative_stream_and_exhausted_limit(self) -> None:
        data, _ = self.run_gene(f"""
  (let IoResource $io/IoResource)
  (let AsyncReader $io/AsyncReader)
  (let client (await ($net/http_client/open ^redirects 1)))
  (let followed (await (client .request ^url "{self.base}/r-relative")))
  (let looped (await (client .request ^url "{self.base}/r-loop")))
  (let streamed (await (client .stream ^url "{self.base}/r-stream")))
  (let first (await (streamed/body .AsyncReader:read 3)))
  (let second (await (streamed/body .AsyncReader:read 3)))
  (let eof (await (streamed/body .AsyncReader:read 1)))
  (client .IoResource:close)
  (await (client .IoResource:wait_closed))
  ($println ($json/stringify
    {{^followed_status followed/status
      ^followed_body ($binary/to_str followed/body)
      ^effective followed/effective_url ^loop_status looped/status
      ^stream_status streamed/status ^stream_first ($binary/to_str first)
      ^stream_second ($binary/to_str second) ^eof ($nil? eof)}}))
""")
        self.assertEqual(data, {"followed_status": 201,
                                "followed_body": "/one",
                                "effective": self.base + "/one",
                                "loop_status": 301,
                                "stream_status": 200,
                                "stream_first": "abc",
                                "stream_second": "def", "eof": True})

    def test_cross_origin_redirect_strips_credentials(self) -> None:
        other = Peer()
        thread = threading.Thread(target=other.serve_forever, daemon=True)
        thread.start()
        try:
            self.peer.redirect_to = f"http://127.0.0.1:{other.server_port}"
            data, _ = self.run_gene(f"""
  (let IoResource $io/IoResource)
  (let client (await ($net/http_client/open ^redirects 2)))
  (let response (await (client .request ^url "{self.base}/r-cross"
    ^headers [["Authorization" "secret"] ["Cookie" "session=secret"]
      ["X-Custom" "safe"]])))
  (client .IoResource:close)
  (await (client .IoResource:wait_closed))
  ($println ($json/stringify
    {{^status response/status ^effective response/effective_url
      ^body ($binary/to_str response/body)}}))
""")
            self.assertEqual(data["status"], 200)
            self.assertEqual(data["effective"],
                             self.peer.redirect_to + "/echo-headers")
            self.assertEqual(json.loads(data["body"]),
                             {"authorization": "", "cookie": "",
                              "x_custom": "safe",
                              "host": f"127.0.0.1:{other.server_port}"})
        finally:
            other.shutdown()
            other.server_close()
            thread.join(timeout=3)

    def test_redirect_invalid_target_fails_and_post_is_not_replayed(self) -> None:
        data, _ = self.run_gene(f"""
  (let IoResource $io/IoResource)
  (let HttpClientError $net/http_client/HttpClientError)
  (let client (await ($net/http_client/open ^redirects 2)))
  (let invalid (try (await (client .request ^url "{self.base}/r-invalid"))
    false catch HttpClientError true))
  (let missing (await (client .request ^url "{self.base}/r-missing")))
  (let posted (await (client .request ^url "{self.base}/r-post"
    ^method "POST" ^body "data")))
  (client .IoResource:close)
  (await (client .IoResource:wait_closed))
  ($println ($json/stringify
    {{^invalid invalid ^missing_status missing/status
      ^missing_body ($binary/to_str missing/body)
      ^post_status posted/status ^post_body ($binary/to_str posted/body)}}))
""")
        self.assertEqual(data, {"invalid": True, "missing_status": 302,
                                "missing_body": "stay", "post_status": 307,
                                "post_body": "stay"})

    def test_same_origin_redirect_preserves_credentials_and_rebuilds_host(self) -> None:
        data, _ = self.run_gene(f"""
  (let IoResource $io/IoResource)
  (let client (await ($net/http_client/open ^redirects 1)))
  (let response (await (client .request ^url "{self.base}/r-same"
    ^headers [["Authorization" "local-secret"] ["Cookie" "local=1"]
      ["X-Custom" "safe"] ["Host" "override.invalid"]])))
  (client .IoResource:close)
  (await (client .IoResource:wait_closed))
  ($println ($binary/to_str response/body))
""")
        self.assertEqual(data, {"authorization": "local-secret",
                                "cookie": "local=1", "x_custom": "safe",
                                "host": f"127.0.0.1:{self.peer.server_port}"})

    def test_redirect_hops_share_one_deadline(self) -> None:
        data, _ = self.run_gene(f"""
  (let IoResource $io/IoResource)
  (let HttpClientError $net/http_client/HttpClientError)
  (let client (await ($net/http_client/open ^redirects 1
    ^timeout_ms 500)))
  (let expired (try (await (client .request ^url "{self.base}/r-delay"))
    false catch HttpClientError true))
  (client .IoResource:close)
  (await (client .IoResource:wait_closed))
  ($println ($json/stringify {{^expired expired}}))
""")
        self.assertEqual(data, {"expired": True})

    def test_invalid_framing_and_header_injection_fail_before_network(self) -> None:
        data, _ = self.run_gene(f"""
  (let IoResource $io/IoResource)
  (let HttpClientError $net/http_client/HttpClientError)
  (let client (await ($net/http_client/open)))
  (let injected (try (client .request ^url "{self.base}/bad"
    ^headers {{^x_test "a\\nb"}}) false catch HttpClientError true))
  (let mismatched (try (client .request ^url "{self.base}/bad"
    ^method "POST" ^body "abc" ^content_length 4)
    false catch HttpClientError true))
  (client .IoResource:close)
  (await (client .IoResource:wait_closed))
  ($println ($json/stringify
    {{^injected injected ^mismatched mismatched}}))
""")
        self.assertEqual(data, {"injected": True, "mismatched": True})
        self.assertEqual(self.peer.accepts, 0)

    def test_cancel_and_close_retire_native_work(self) -> None:
        data, elapsed = self.run_gene(f"""
  (let IoResource $io/IoResource)
  (let client (await ($net/http_client/open)))
  (let request (client .request ^url "{self.base}/slow"))
  ($sleep 50)
  (request .cancel)
  (let cancelled (match (request .join)
    (when TaskOutcome/cancelled true)))
  (client .IoResource:close)
  (await (client .IoResource:wait_closed))
  (await (client .IoResource:wait_closed))
  (let stats ($runtime/gc_stats))
  ($println ($json/stringify
    {{^cancelled cancelled ^bytes stats/io_retained_bytes
      ^leases stats/io_cleanup_leases
      ^clients stats/http_client_open_resources
      ^pending stats/http_client_pending_requests}}))
""")
        self.assertEqual(data, {"cancelled": True, "bytes": 0,
                                "leases": 0, "clients": 0, "pending": 0})
        self.assertLess(elapsed, 1.5)

    def test_application_byte_budget_rejects_third_snapshot(self) -> None:
        data, _ = self.run_gene(f"""
  (let IoResource $io/IoResource)
  (let IoBackpressure $io/IoBackpressure)
  (let client (await ($net/http_client/open
    ^max_buffered_body_bytes 33554432)))
  (let first (client .request ^url "{self.base}/slow"
    ^max_bytes 33554432))
  (let second (client .request ^url "{self.base}/slow"
    ^max_bytes 33554432))
  (let blocked (try (client .request ^url "{self.base}/slow"
    ^max_bytes 33554432) false catch IoBackpressure true))
  (client .IoResource:close)
  (first .join)
  (second .join)
  (await (client .IoResource:wait_closed))
  (let stats ($runtime/gc_stats))
  ($println ($json/stringify
    {{^blocked blocked ^bytes stats/io_retained_bytes
      ^leases stats/io_cleanup_leases
      ^clients stats/http_client_open_resources
      ^pending stats/http_client_pending_requests}}))
""")
        self.assertEqual(data, {"blocked": True, "bytes": 0, "leases": 0,
                                "clients": 0, "pending": 0})

    def test_per_origin_cap_and_queue_deadline(self) -> None:
        data, _ = self.run_gene(f"""
  (let IoResource $io/IoResource)
  (let HttpClientError $net/http_client/HttpClientError)
  (let client (await ($net/http_client/open
    ^max_connections 2 ^max_connections_per_origin 1
    ^timeout_ms 1000)))
  (let first (client .request ^url "{self.base}/delay"))
  (let second (client .request ^url "{self.base}/fast"
    ^timeout_ms 150))
  (let complete (await first))
  (let expired (try (await second) false catch HttpClientError true))
  (client .IoResource:close)
  (await (client .IoResource:wait_closed))
  ($println ($json/stringify
    {{^first ($binary/to_str complete/body) ^expired expired}}))
""")
        self.assertEqual(data, {"first": "/delay", "expired": True})
        self.assertEqual(self.peer.max_active, 1)

    def test_smaller_client_cap_survives_shared_service_growth(self) -> None:
        data, _ = self.run_gene(f"""
  (let IoResource $io/IoResource)
  (let narrow (await ($net/http_client/open
    ^max_connections 1 ^max_connections_per_origin 1)))
  (let wide (await ($net/http_client/open
    ^max_connections 2 ^max_connections_per_origin 2)))
  (let first (narrow .request ^url "{self.base}/delay"))
  (let second (narrow .request ^url "{self.base}/delay"))
  (let a (await first))
  (let b (await second))
  (narrow .IoResource:close)
  (await (narrow .IoResource:wait_closed))
  (wide .IoResource:close)
  (await (wide .IoResource:wait_closed))
  ($println ($json/stringify
    {{^a ($binary/to_str a/body) ^b ($binary/to_str b/body)}}))
""")
        self.assertEqual(data, {"a": "/delay", "b": "/delay"})
        self.assertEqual(self.peer.max_active, 1)

    def test_pending_request_cap_rejects_before_snapshot(self) -> None:
        data, _ = self.run_gene(f"""
  (let IoResource $io/IoResource)
  (let HttpClientError $net/http_client/HttpClientError)
  (let client (await ($net/http_client/open ^max_pending_requests 1)))
  (let first (client .request ^url "{self.base}/slow"))
  (let blocked (try (client .request ^url "{self.base}/fast")
    false catch HttpClientError true))
  (client .IoResource:close)
  (first .join)
  (await (client .IoResource:wait_closed))
  (let stats ($runtime/gc_stats))
  ($println ($json/stringify
    {{^blocked blocked ^pending stats/http_client_pending_requests
      ^bytes stats/io_retained_bytes}}))
""")
        self.assertEqual(data, {"blocked": True, "pending": 0, "bytes": 0})

    def test_missing_ca_file_fails_open_task(self) -> None:
        data, _ = self.run_gene("""
  (let HttpClientError $net/http_client/HttpClientError)
  (let failed (try (await ($net/http_client/open
    ^ca_file "/definitely/missing-ca.pem"))
    false catch HttpClientError true))
  ($println ($json/stringify {^failed failed}))
""")
        self.assertEqual(data, {"failed": True})

    def test_tls_rejects_untrusted_peer_and_accepts_pinned_ca(self) -> None:
        if shutil.which("openssl") is None:
            self.skipTest("openssl is unavailable")
        cert = pathlib.Path(self.temp.name) / "peer-cert.pem"
        key = pathlib.Path(self.temp.name) / "peer-key.pem"
        generated = subprocess.run(
            ["openssl", "req", "-x509", "-newkey", "rsa:2048",
             "-nodes", "-days", "1", "-keyout", str(key), "-out",
             str(cert), "-subj", "/CN=localhost", "-addext",
             "subjectAltName=DNS:localhost,IP:127.0.0.1"],
            cwd=ROOT, capture_output=True, text=True, timeout=20)
        self.assertEqual(generated.returncode, 0, generated.stderr)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(cert, key)
        self.peer.shutdown()
        self.peer.server_close()
        self.thread.join(timeout=3)
        self.peer = Peer()
        self.peer.socket = context.wrap_socket(self.peer.socket,
                                               server_side=True)
        self.thread = threading.Thread(target=self.peer.serve_forever,
                                       daemon=True)
        self.thread.start()
        url = f"https://localhost:{self.peer.server_port}/one"
        plain = Peer()
        plain_thread = threading.Thread(target=plain.serve_forever,
                                        daemon=True)
        plain_thread.start()
        self.peer.redirect_to = f"http://127.0.0.1:{plain.server_port}"
        try:
            data, _ = self.run_gene(f"""
  (let IoResource $io/IoResource)
  (let HttpClientError $net/http_client/HttpClientError)
  (let untrusted (await ($net/http_client/open)))
  (let rejected (try (await (untrusted .request ^url "{url}"))
    false catch HttpClientError true))
  (untrusted .IoResource:close)
  (await (untrusted .IoResource:wait_closed))
  (let trusted (await ($net/http_client/open ^ca_file "{cert}"
    ^redirects 1)))
  (let response (await (trusted .request ^url "{url}")))
  (let downgraded (try (await (trusted .request
    ^url "https://localhost:{self.peer.server_port}/r-cross"))
    false catch HttpClientError true))
  (trusted .IoResource:close)
  (await (trusted .IoResource:wait_closed))
  ($println ($json/stringify
    {{^rejected rejected ^downgraded downgraded ^status response/status
      ^body ($binary/to_str response/body)}}))
""")
            self.assertEqual(data, {"rejected": True,
                                    "downgraded": True, "status": 201,
                                    "body": "/one"})
            self.assertEqual(plain.accepts, 0)
        finally:
            plain.shutdown()
            plain.server_close()
            plain_thread.join(timeout=3)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--atomic-arc", action="store_true")
    parser.add_argument("--asan", action="store_true")
    args, rest = parser.parse_known_args()
    ATOMIC_ARC = args.atomic_arc
    ASAN = args.asan
    unittest.main(argv=[__file__, *rest])
