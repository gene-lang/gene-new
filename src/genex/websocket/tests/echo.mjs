// Independent RFC 6455 peer. Deliberately splits a message around a control
// frame and makes frames larger than the native receive scratch buffer.
import net from "node:net";
import { createHash } from "node:crypto";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import assert from "node:assert/strict";

const root = fileURLToPath(new URL("../../../../", import.meta.url));
const payload = Buffer.from(Array.from({ length: 40001 }, (_, i) => i & 255));
const ping = Buffer.from("between fragments");
let sawPong = false, sawBinary = false, peerError = null;
const peers = new Set();

function frame(opcode, bytes, final = true) {
  const header = Buffer.alloc(bytes.length < 126 ? 2 : 4);
  header[0] = (final ? 128 : 0) | opcode;
  header[1] = bytes.length < 126 ? bytes.length : 126;
  if (bytes.length >= 126) header.writeUInt16BE(bytes.length, 2);
  return Buffer.concat([header, bytes]);
}

const server = net.createServer(socket => {
  peers.add(socket);
  let buffer = Buffer.alloc(0), upgraded = false;
  socket.on("close", () => peers.delete(socket));
  socket.on("error", error => { if (error.code !== "ECONNRESET") peerError = error; });
  socket.on("data", chunk => {
    try {
      buffer = Buffer.concat([buffer, chunk]);
      if (!upgraded) {
        const end = buffer.indexOf("\r\n\r\n");
        if (end < 0) return;
        const header = buffer.subarray(0, end).toString();
        const key = header.match(/^Sec-WebSocket-Key: (.+)$/mi)?.[1].trim();
        assert(key, "client must send a WebSocket key");
        const accept = createHash("sha1").update(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest("base64");
        socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
        upgraded = true;
        buffer = buffer.subarray(end + 4);
        const first = frame(2, payload.subarray(0, 20000), false);
        socket.write(first.subarray(0, 3));
        setTimeout(() => {
          if (socket.destroyed) return;
          socket.write(first.subarray(3));
          socket.write(frame(9, ping));
          socket.write(frame(0, payload.subarray(20000)));
          socket.write(frame(2, Buffer.alloc(0)));
        }, 10);
      }
      while (buffer.length >= 2) {
        assert(buffer[1] & 128, "client frames must be masked");
        const opcode = buffer[0] & 15;
        let n = buffer[1] & 127, at = 2;
        if (n === 126) { if (buffer.length < 4) return; n = buffer.readUInt16BE(2); at = 4; }
        if (n === 127) { if (buffer.length < 10) return; n = Number(buffer.readBigUInt64BE(2)); at = 10; }
        assert(n <= 1024 * 1024, "unexpected frame size");
        if (buffer.length < at + 4 + n) return;
        const mask = buffer.subarray(at, at + 4); at += 4;
        const body = Buffer.from(buffer.subarray(at, at + n));
        for (let i = 0; i < n; i++) body[i] ^= mask[i % 4];
        buffer = buffer.subarray(at + n);
        if (opcode === 10) { assert.deepEqual(body, ping); sawPong = true; }
        else if (opcode === 2) {
          assert.deepEqual(body, payload); sawBinary = true;
          socket.write(frame(2, body));
        } else if (opcode === 8) socket.end(frame(8, body));
        else assert.fail(`unexpected client opcode ${opcode}`);
      }
    } catch (error) { peerError = error; socket.destroy(); }
  });
});

await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
const suffix = process.platform === "darwin" ? "dylib" : "so";
const gene = process.env.GENE_EXE ?? root + "bin/gene";
const library = root + `src/genex/websocket/build/libgene_websocket.${suffix}`;
const child = spawn(gene, ["run", root + "src/genex/websocket/tests/echo.gene", library,
  `ws://127.0.0.1:${server.address().port}/echo`], { cwd: root, stdio: ["ignore", "pipe", "pipe"] });
let output = "";
child.stdout.on("data", b => { output += b; });
child.stderr.on("data", b => { output += b; });
const deadline = setTimeout(() => child.kill("SIGKILL"), 20000);
try {
  const code = await new Promise((resolve, reject) => { child.on("exit", resolve); child.on("error", reject); });
  assert.equal(code, 0, output);
  if (peerError) throw peerError;
  assert(sawPong && sawBinary, "peer must observe the PONG and binary send");
  process.stdout.write(output);
  console.log("PASS — independent peer verified masking and PONG between fragments");
} finally {
  clearTimeout(deadline);
  child.kill("SIGKILL");
  for (const peer of peers) peer.destroy();
  await new Promise(resolve => server.close(resolve));
}
