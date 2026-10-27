// Independent wire peer, not the implementation's frame parser. Node's TLS
// server verifies the native client without trusting its own transport code.
import net from "node:net";
import tls from "node:tls";
import { createHash } from "node:crypto";
import { spawn, execFileSync } from "node:child_process";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import assert from "node:assert/strict";

const root = fileURLToPath(new URL("../../../../", import.meta.url));
const gene = process.env.GENE_EXE ?? join(root, "bin/gene");
const library = join(root, `src/genex/websocket/build/libgene_websocket.${process.platform === "darwin" ? "dylib" : "so"}`);
const temporary = await mkdtemp(join(tmpdir(), "gene-websocket-"));
const key = join(temporary, "key.pem"), certificate = join(temporary, "cert.pem");
const peers = new Set();
const paths = new Map();
let failure, sawText = false, sawPong = false, sawClose = false;

function frame(opcode, bytes = Buffer.alloc(0), final = true) {
  const at = bytes.length < 126 ? 2 : bytes.length <= 65535 ? 4 : 10;
  const header = Buffer.alloc(at);
  header[0] = (final ? 128 : 0) | opcode;
  header[1] = at === 2 ? bytes.length : at === 4 ? 126 : 127;
  if (at === 4) header.writeUInt16BE(bytes.length, 2);
  if (at === 10) header.writeBigUInt64BE(BigInt(bytes.length), 2);
  return Buffer.concat([header, bytes]);
}

function accept(socket) {
  peers.add(socket);
  socket.on("close", () => peers.delete(socket));
  socket.on("error", error => {
    if (!["ECONNRESET", "EPIPE", "ERR_SSL_SSLV3_ALERT_BAD_CERTIFICATE", "ERR_SSL_TLSV1_ALERT_UNKNOWN_CA"].includes(error.code)) failure ??= error;
  });
  let buffer = Buffer.alloc(0), upgraded = false, path;
  socket.on("data", chunk => {
    try {
      buffer = Buffer.concat([buffer, chunk]);
      if (!upgraded) {
        const end = buffer.indexOf("\r\n\r\n");
        if (end < 0) return;
        const header = buffer.subarray(0, end).toString();
        path = header.split(" ")[1];
        paths.set(path, (paths.get(path) ?? 0) + 1);
        if (path === "/stall") return;
        if (path === "/reject") { socket.end("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"); return; }
        if (path === "/redirect") { socket.end("HTTP/1.1 302 Found\r\nLocation: /text\r\nContent-Length: 0\r\n\r\n"); return; }
        const clientKey = header.match(/^Sec-WebSocket-Key: (.+)$/mi)?.[1].trim();
        assert(clientKey);
        const digest = createHash("sha1").update(clientKey + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest("base64");
        socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${path === "/bad-accept" ? "wrong" : digest}\r\n\r\n`);
        buffer = buffer.subarray(end + 4);
        upgraded = true;
        if (path === "/text") {
          const hello = Buffer.from("hello 雪 👋");
          socket.write(frame(1, hello.subarray(0, 8), false)); // split UTF-8 inside 雪
          socket.write(frame(9, Buffer.from("control")));
          socket.write(frame(0, hello.subarray(8)));
          socket.write(frame(1));
          socket.pause();
          setTimeout(() => { if (!socket.destroyed) socket.resume(); }, 80);
        } else if (path === "/limit") socket.write(frame(1, Buffer.alloc(65, 120)));
        else if (path === "/tls") socket.write(frame(1, Buffer.from("verified TLS")));
        else if (path === "/close") setTimeout(() => {
          if (!socket.destroyed) socket.write(frame(8, Buffer.from([3, 232])));
        }, 20);
      }
      while (buffer.length >= 2) {
        assert(buffer[1] & 128, "client frame was not masked");
        let size = buffer[1] & 127, at = 2;
        if (size === 126) { if (buffer.length < 4) return; size = buffer.readUInt16BE(2); at = 4; }
        if (size === 127) { if (buffer.length < 10) return; size = Number(buffer.readBigUInt64BE(2)); at = 10; }
        assert(size <= 8 * 1024 * 1024);
        if (buffer.length < at + 4 + size) return;
        const opcode = buffer[0] & 15;
        const mask = buffer.subarray(at, at + 4);
        at += 4;
        const body = Buffer.from(buffer.subarray(at, at + size));
        for (let i = 0; i < body.length; i++) body[i] ^= mask[i % 4];
        buffer = buffer.subarray(at + size);
        if (opcode === 10) { assert.equal(body.toString(), "control"); sawPong = true; }
        else if (opcode === 1) {
          assert.equal(path, "/text");
          assert.equal(body.length, 2 * 1024 * 1024);
          assert(body.every(byte => byte === 120));
          sawText = true;
          socket.write(frame(1, body));
        } else if (opcode === 8) {
          sawClose = true;
          socket.end(frame(8, body));
        } else assert.fail(`Unexpected client opcode ${opcode}`);
      }
    } catch (error) { failure ??= error; socket.destroy(); }
  });
}

let plain, secure, child;
try {
  execFileSync("openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
    "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost", "-keyout", key, "-out", certificate], {stdio: "ignore"});
  plain = net.createServer(accept);
  secure = tls.createServer({key: await readFile(key), cert: await readFile(certificate)}, accept);
  secure.on("tlsClientError", () => {}); // client rejection is a required test case
  await new Promise(resolve => plain.listen(0, "127.0.0.1", resolve));
  await new Promise(resolve => secure.listen(0, "127.0.0.1", resolve));
  child = spawn(gene, ["run", join(root, "src/genex/websocket/tests/qualification.gene"), library,
    `ws://127.0.0.1:${plain.address().port}`, `wss://localhost:${secure.address().port}`, certificate],
    {cwd: root, stdio: ["ignore", "pipe", "pipe"]});
  let output = "";
  child.stdout.on("data", bytes => { output += bytes; process.stdout.write(bytes); });
  child.stderr.on("data", bytes => { output += bytes; process.stderr.write(bytes); });
  const deadline = setTimeout(() => child.kill("SIGKILL"), 60000);
  const code = await new Promise((resolve, reject) => { child.on("exit", resolve); child.on("error", reject); });
  clearTimeout(deadline);
  assert.equal(code, 0, output);
  if (failure) throw failure;
  assert(sawText && sawPong && sawClose, "peer did not observe text, PONG and close");
  assert.equal(paths.get("/text"), 1, "client followed a redirect");
  assert(paths.get("/stall") >= 2, "timeout and handshake cancellation were not exercised");
  console.log("PASS — independent WS/TLS peers verified frames, trust, limits and cancellation");
} finally {
  child?.kill("SIGKILL");
  for (const peer of peers) peer.destroy();
  if (plain?.listening) await new Promise(resolve => plain.close(resolve));
  if (secure?.listening) await new Promise(resolve => secure.close(resolve));
  await rm(temporary, {recursive: true, force: true});
}
