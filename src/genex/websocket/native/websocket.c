/* libcurl owns HTTP upgrade, masking, TLS verification and control frames.
 * This adapter supplies bounded message reassembly and an outbound queue so
 * the Gene frame loop never waits for socket writability. */
#include <curl/curl.h>
#include <pthread.h>
#include <stdint.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#define MAX_MESSAGE (16u * 1024u * 1024u)
#define MAX_QUEUED (8u * 1024u * 1024u)
#define MAX_QUEUE_COUNT 256

typedef struct Message {
  struct Message *next;
  size_t size, offset;
  unsigned int kind;
  unsigned char data[];
} Message;
typedef struct GXSocket {
  CURL *curl;
  CURLM *multi;
  struct curl_slist *headers;
  pthread_t owner;
  char protocol[65];
  char key[25];
  char error[CURL_ERROR_SIZE];
  unsigned char *incoming;
  size_t size, capacity;
  int ready, kind, in_message, closed, connected, added;
  Message *head, *tail;
  size_t queued_bytes, queue_count;
  size_t max_message, max_queued;
} GXSocket;

static _Thread_local char open_error[CURL_ERROR_SIZE];
static _Atomic size_t open_sockets;
size_t gx_ws_open_count(void) { return atomic_load(&open_sockets); }
const char *gx_ws_last_error(void) { return open_error; }
const char *gx_ws_error(GXSocket *s) { return s->error; }
static int fail(GXSocket *s, const char *message) {
  snprintf(s->error, sizeof s->error, "%s", message); return -1;
}
static int owner(GXSocket *s) {
  return pthread_equal(pthread_self(), s->owner) ? 0 : fail(s, "socket belongs to another thread");
}
static int curl_fail(GXSocket *s, CURLcode code) {
  s->closed = 1;
  if (!s->error[0]) fail(s, curl_easy_strerror(code));
  return -1;
}

/* libcurl 8.19 accepts a 101 without checking its Sec-WebSocket-Accept hash.
 * Capture curl's random nonce without emitting its verbose diagnostics. Only
 * the public handshake nonce is retained; headers and TLS data are discarded. */
static int capture_key(CURL *curl, curl_infotype type, char *data, size_t size, void *context) {
  (void)curl;
  if (type != CURLINFO_HEADER_OUT) return 0;
  GXSocket *s = context;
  const char name[] = "Sec-WebSocket-Key:";
  size_t at = 0;
  while (at < size) {
    size_t end = at;
    while (end < size && data[end] != '\n') end++;
    if (end - at >= sizeof name - 1 && !strncasecmp(data + at, name, sizeof name - 1)) {
      size_t first = at + sizeof name - 1, last = end;
      while (first < last && (data[first] == ' ' || data[first] == '\t')) first++;
      while (last > first && (data[last - 1] == '\r' || data[last - 1] == ' ' || data[last - 1] == '\t')) last--;
      if (last - first == 24) { memcpy(s->key, data + first, 24); s->key[24] = 0; }
    }
    at = end + 1;
  }
  return 0;
}

static uint32_t rotate(uint32_t value, unsigned int n) { return (value << n) | (value >> (32 - n)); }

/* SHA-1 is mandated by RFC 6455 for this fixed 60-byte nonce/GUID input;
 * it is not used as a general security hash or exposed as a crypto API. */
static void expected_accept(const char key[25], char out[29]) {
  unsigned char padded[128] = {0}, digest[20];
  memcpy(padded, key, 24);
  memcpy(padded + 24, "258EAFA5-E914-47DA-95CA-C5AB0DC85B11", 36);
  padded[60] = 0x80; padded[126] = 1; padded[127] = 0xe0;
  uint32_t h[5] = {0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476, 0xc3d2e1f0};
  for (int block = 0; block < 2; block++) {
    uint32_t w[80];
    for (int i = 0; i < 16; i++) {
      const unsigned char *p = padded + block * 64 + i * 4;
      w[i] = ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
    }
    for (int i = 16; i < 80; i++) w[i] = rotate(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
    uint32_t a = h[0], b = h[1], c = h[2], d = h[3], e = h[4];
    for (int i = 0; i < 80; i++) {
      uint32_t f, k;
      if (i < 20) { f = (b & c) | (~b & d); k = 0x5a827999; }
      else if (i < 40) { f = b ^ c ^ d; k = 0x6ed9eba1; }
      else if (i < 60) { f = (b & c) | (b & d) | (c & d); k = 0x8f1bbcdc; }
      else { f = b ^ c ^ d; k = 0xca62c1d6; }
      uint32_t next = rotate(a, 5) + f + e + k + w[i];
      e = d; d = c; c = rotate(b, 30); b = a; a = next;
    }
    h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e;
  }
  for (int i = 0; i < 20; i++) digest[i] = (unsigned char)(h[i / 4] >> (24 - (i % 4) * 8));
  const char alphabet[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  size_t at = 0;
  for (int i = 0; i < 20; i += 3) {
    uint32_t value = (uint32_t)digest[i] << 16;
    if (i + 1 < 20) value |= (uint32_t)digest[i + 1] << 8;
    if (i + 2 < 20) value |= digest[i + 2];
    out[at++] = alphabet[value >> 18]; out[at++] = alphabet[(value >> 12) & 63];
    out[at++] = i + 1 < 20 ? alphabet[(value >> 6) & 63] : '=';
    out[at++] = i + 2 < 20 ? alphabet[value & 63] : '=';
  }
  out[at] = 0;
}

static int has_token(const char *value, const char *token) {
  const size_t n = strlen(token);
  while (*value) {
    while (*value == ',' || *value == ' ' || *value == '\t') value++;
    const char *end = strchr(value, ',');
    if (!end) end = value + strlen(value);
    const char *last = end;
    while (last > value && (last[-1] == ' ' || last[-1] == '\t')) last--;
    if ((size_t)(last - value) == n && !strncasecmp(value, token, n)) return 1;
    value = end;
  }
  return 0;
}

void gx_ws_free(GXSocket *s) {
  if (!s) return;
  if (s->curl) {
    if (s->connected && !s->closed && !s->head) {
      const unsigned char normal[] = {3, 232}; /* close code 1000 */
      size_t sent;
      (void)curl_ws_send(s->curl, normal, sizeof normal, &sent, 0, CURLWS_CLOSE);
    }
    if (s->multi && s->added) curl_multi_remove_handle(s->multi, s->curl);
    curl_easy_cleanup(s->curl);
  }
  if (s->multi) curl_multi_cleanup(s->multi);
  curl_slist_free_all(s->headers);
  while (s->head) { Message *next = s->head->next; free(s->head); s->head = next; }
  free(s->incoming); free(s);
  atomic_fetch_sub(&open_sockets, 1);
  curl_global_cleanup();
}

/* RFC 6455 subprotocol names are HTTP tokens. Accepting only this conservative
 * subset keeps a caller's value from ever injecting another request header. */
static int valid_protocol(const char *protocol) {
  size_t n = strlen(protocol);
  if (n == 0 || n > 64) return 0;
  for (size_t i = 0; i < n; i++) {
    char c = protocol[i];
    if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
          c == '.' || c == '_' || c == '-')) return 0;
  }
  return 1;
}

static GXSocket *prepare_socket(const char *url, const char *protocol,
                              const char *ca_file, int timeout_ms,
                              size_t max_message, size_t max_queued) {
  open_error[0] = 0;
  if ((strncmp(url, "ws://", 5) && strncmp(url, "wss://", 6)) || timeout_ms < 1 ||
      max_message < 1 || max_message > MAX_MESSAGE ||
      max_queued < 1 || max_queued > MAX_QUEUED) {
    snprintf(open_error, sizeof open_error, "expected a ws:// or wss:// URL and a positive timeout");
    return NULL;
  }
  if (protocol && !valid_protocol(protocol)) {
    snprintf(open_error, sizeof open_error, "a subprotocol is 1-64 letters, digits, '.', '_' or '-'");
    return NULL;
  }
  CURLcode rc = curl_global_init(CURL_GLOBAL_DEFAULT);
  if (rc != CURLE_OK) { snprintf(open_error, sizeof open_error, "%s", curl_easy_strerror(rc)); return NULL; }
  GXSocket *s = calloc(1, sizeof *s);
  if (!s) { curl_global_cleanup(); snprintf(open_error, sizeof open_error, "out of memory"); return NULL; }
  atomic_fetch_add(&open_sockets, 1);
  s->owner = pthread_self();
  s->max_message = max_message; s->max_queued = max_queued;
  s->curl = curl_easy_init();
  if (!s->curl) { fail(s, "curl initialization failed"); goto error; }
#define SET(option, value) do { rc = curl_easy_setopt(s->curl, option, value); if (rc != CURLE_OK) goto error; } while (0)
  SET(CURLOPT_ERRORBUFFER, s->error);
  SET(CURLOPT_URL, url);
  SET(CURLOPT_CONNECT_ONLY, 2L);
  SET(CURLOPT_CONNECTTIMEOUT_MS, (long)timeout_ms);
  SET(CURLOPT_TIMEOUT_MS, (long)timeout_ms);
  SET(CURLOPT_NOSIGNAL, 1L);
  SET(CURLOPT_HTTP_VERSION, (long)CURL_HTTP_VERSION_1_1);
  SET(CURLOPT_VERBOSE, 1L);
  SET(CURLOPT_DEBUGFUNCTION, capture_key);
  SET(CURLOPT_DEBUGDATA, s);
  SET(CURLOPT_PROXY, "");
  SET(CURLOPT_SSL_VERIFYPEER, 1L);
  SET(CURLOPT_SSL_VERIFYHOST, 2L);
  if (ca_file && *ca_file) SET(CURLOPT_CAINFO, ca_file);
  if (protocol) {
    snprintf(s->protocol, sizeof s->protocol, "%s", protocol);
    char line[128];
    snprintf(line, sizeof line, "Sec-WebSocket-Protocol: %s", protocol);
    struct curl_slist *more = curl_slist_append(s->headers, line);
    if (!more) { fail(s, "out of memory"); goto error; }
    s->headers = more;
    SET(CURLOPT_HTTPHEADER, s->headers);
  }
  return s;
error:
  snprintf(open_error, sizeof open_error, "%s", s->error[0] ? s->error : curl_easy_strerror(rc));
  s->closed = 1; gx_ws_free(s); return NULL;
#undef SET
}

static int finish_connect(GXSocket *s) {
  long status = 0;
  struct curl_header *header = NULL;
  const unsigned int origins = CURLH_HEADER | CURLH_1XX;
  char expected[29];
  expected_accept(s->key, expected);
  curl_easy_getinfo(s->curl, CURLINFO_RESPONSE_CODE, &status);
  if (status != 101 || strlen(s->key) != 24 ||
      curl_easy_header(s->curl, "Sec-WebSocket-Accept", 0, origins, -1, &header) != CURLHE_OK ||
      !header || header->amount != 1 || strcmp(header->value, expected)) {
    s->closed = 1; return fail(s, "invalid WebSocket accept response");
  }
  if (curl_easy_header(s->curl, "Upgrade", 0, origins, -1, &header) != CURLHE_OK ||
      !header || strcasecmp(header->value, "websocket")) {
    s->closed = 1; return fail(s, "missing WebSocket upgrade header");
  }
  if (curl_easy_header(s->curl, "Connection", 0, origins, -1, &header) != CURLHE_OK ||
      !header || !has_token(header->value, "upgrade")) {
    s->closed = 1; return fail(s, "missing WebSocket connection upgrade token");
  }
  if (curl_easy_header(s->curl, "Sec-WebSocket-Extensions", 0, origins, -1, &header) == CURLHE_OK) {
    s->closed = 1; return fail(s, "unsolicited WebSocket extension");
  }
  if (!s->protocol[0] &&
      curl_easy_header(s->curl, "Sec-WebSocket-Protocol", 0, origins, -1, &header) == CURLHE_OK) {
    s->closed = 1; return fail(s, "unsolicited WebSocket subprotocol");
  }
  if (s->protocol[0]) {
    /* The server must select the offered protocol (RFC 6455 section 4.1): a
     * peer that ignored it does not speak this application's protocol. The
     * 101 upgrade is an informational response, so its headers are CURLH_1XX. */
    struct curl_header *selected = NULL;
    if (curl_easy_header(s->curl, "Sec-WebSocket-Protocol", 0,
                         CURLH_HEADER | CURLH_1XX, -1, &selected)
          != CURLHE_OK || !selected || strcmp(selected->value, s->protocol) != 0) {
      s->closed = 1;
      return fail(s, "the server did not select the offered WebSocket subprotocol");
    }
    /* libcurl keeps its own reference to the header list only for the
     * transfer that already finished. */
    curl_easy_setopt(s->curl, CURLOPT_HTTPHEADER, NULL);
    curl_slist_free_all(s->headers); s->headers = NULL;
  }
  s->connected = 1;
  return 0;
}

static GXSocket *open_socket(const char *url, const char *protocol, int timeout_ms) {
  GXSocket *s = prepare_socket(url, protocol, NULL, timeout_ms, MAX_MESSAGE, MAX_QUEUED);
  if (!s) return NULL;
  CURLcode rc = curl_easy_perform(s->curl);
  if (rc != CURLE_OK) curl_fail(s, rc);
  if (rc != CURLE_OK || finish_connect(s) != 0) {
    snprintf(open_error, sizeof open_error, "%s", s->error);
    s->closed = 1; gx_ws_free(s); return NULL;
  }
  return s;
}

/* The multi handle stays attached for the whole CONNECT_ONLY connection.
 * Removing it after the handshake would invalidate curl_ws_send/recv. */
GXSocket *gx_ws_begin(const char *url, const char *protocol, const char *ca_file,
                      int timeout_ms, size_t max_message, size_t max_queued) {
  GXSocket *s = prepare_socket(url, protocol && *protocol ? protocol : NULL,
                              ca_file, timeout_ms, max_message, max_queued);
  if (!s) return NULL;
  s->multi = curl_multi_init();
  CURLMcode rc = s->multi ? curl_multi_add_handle(s->multi, s->curl) : CURLM_OUT_OF_MEMORY;
  if (rc != CURLM_OK) {
    snprintf(open_error, sizeof open_error, "%s", curl_multi_strerror(rc));
    s->closed = 1; gx_ws_free(s); return NULL;
  }
  s->added = 1;
  return s;
}

static int progress_connect(GXSocket *s) {
  int running = 0;
  CURLMcode rc = curl_multi_perform(s->multi, &running);
  if (rc != CURLM_OK) { s->closed = 1; return fail(s, curl_multi_strerror(rc)); }
  int left = 0;
  CURLMsg *message;
  while ((message = curl_multi_info_read(s->multi, &left))) {
    if (message->msg != CURLMSG_DONE || message->easy_handle != s->curl) continue;
    if (message->data.result != CURLE_OK) return curl_fail(s, message->data.result);
    return finish_connect(s);
  }
  return 0;
}

int gx_ws_connected(GXSocket *s) {
  if (owner(s) != 0 || s->closed) return -1;
  return s->connected;
}

GXSocket *gx_ws_connect(const char *url, int timeout_ms) {
  return open_socket(url, NULL, timeout_ms);
}

GXSocket *gx_ws_connect_protocol(const char *url, const char *protocol, int timeout_ms) {
  return open_socket(url, protocol, timeout_ms);
}

static int queue_send(GXSocket *s, void *data, size_t n, unsigned int kind) {
  if (owner(s) != 0) return -1;
  if (s->closed) return fail(s, "socket is closed");
  if (!s->connected) return fail(s, "socket is still connecting");
  if (n > s->max_queued || s->queued_bytes > s->max_queued - n || s->queue_count >= MAX_QUEUE_COUNT)
    return fail(s, "WebSocket output queue is full");
  Message *m = malloc(sizeof *m + n);
  if (!m) return fail(s, "out of memory");
  m->next = NULL; m->size = n; m->offset = 0; m->kind = kind;
  if (n) memcpy(m->data, data, n);
  if (s->tail) s->tail->next = m; else s->head = m;
  s->tail = m; s->queued_bytes += n; s->queue_count++;
  return 0;
}

int gx_ws_send(GXSocket *s, void *data, size_t n) { return queue_send(s, data, n, CURLWS_BINARY); }
int gx_ws_send_text(GXSocket *s, void *data, size_t n) { return queue_send(s, data, n, CURLWS_TEXT); }

static int flush(GXSocket *s) {
  for (int work = 0; s->head && work < 64; work++) {
    Message *m = s->head;
    size_t sent = 0;
    CURLcode rc = curl_ws_send(s->curl, m->data + m->offset, m->size - m->offset,
                               &sent, 0, m->kind);
    if (rc != CURLE_OK && rc != CURLE_AGAIN) return curl_fail(s, rc);
    m->offset += sent;
    const int completed = m->offset == m->size;
    if (completed) {
      s->head = m->next; if (!s->head) s->tail = NULL;
      s->queued_bytes -= m->size; s->queue_count--; free(m);
    }
    if (rc == CURLE_AGAIN || (!sent && !completed)) break;
  }
  return 0;
}

int gx_ws_flush(GXSocket *s) {
  if (owner(s) != 0 || s->closed) return -1;
  if (!s->connected) return fail(s, "socket is still connecting");
  if (flush(s) != 0) return -1;
  return s->head ? 0 : 1;
}

int gx_ws_poll(GXSocket *s) {
  if (owner(s) != 0 || s->closed) return -1;
  if (!s->connected) {
    if (progress_connect(s) != 0) return -1;
    if (!s->connected) return 0;
  }
  if (flush(s) != 0) return -1;
  if (s->ready) return 1;
  for (int work = 0; work < 64; work++) {
    unsigned char chunk[16384];
    size_t received = 0;
    const struct curl_ws_frame *meta = NULL;
    CURLcode rc = curl_ws_recv(s->curl, chunk, sizeof chunk, &received, &meta);
    if (rc == CURLE_AGAIN) return 0;
    if (rc != CURLE_OK) return curl_fail(s, rc);
    if (!meta) { s->closed = 1; return fail(s, "missing WebSocket frame metadata"); }
    const int flags = meta->flags;
    const curl_off_t left = meta->bytesleft;
    if (flags & CURLWS_CLOSE) {
      size_t sent;
      (void)curl_ws_send(s->curl, chunk, received, &sent, 0, CURLWS_CLOSE);
      s->closed = 1; return fail(s, "peer closed the WebSocket");
    }
    /* libcurl automatically answers PING. Control frames do not belong to a
     * fragmented data message and must leave its accumulated bytes intact. */
    if (flags & (CURLWS_PING | CURLWS_PONG)) continue;
    int kind = flags & (CURLWS_TEXT | CURLWS_BINARY);
    if (!kind && s->in_message) kind = s->kind;
    if (!kind || (s->in_message && s->kind != kind)) {
      s->closed = 1; return fail(s, "invalid fragmented WebSocket message");
    }
    s->kind = kind; s->in_message = 1;
    if (received > s->max_message - s->size || left < 0 || (uint64_t)left > s->max_message - s->size - received) {
      s->closed = 1; return fail(s, "WebSocket message exceeds configured limit");
    }
    if (s->size + received > s->capacity) {
      size_t capacity = s->capacity ? s->capacity : 16384;
      while (capacity < s->size + received) capacity *= 2;
      unsigned char *p = realloc(s->incoming, capacity);
      if (!p) { s->closed = 1; return fail(s, "out of memory"); }
      s->incoming = p; s->capacity = capacity;
    }
    if (received) memcpy(s->incoming + s->size, chunk, received);
    s->size += received;
    if (left == 0 && !(flags & CURLWS_CONT)) { s->ready = 1; return 1; }
  }
  return 0;
}
size_t gx_ws_size(GXSocket *s) { return s->ready ? s->size : 0; }
int gx_ws_kind(GXSocket *s) { return s->kind; }
int gx_ws_read(GXSocket *s, void *out, size_t n) {
  if (owner(s) != 0) return -1;
  if (!s->ready || n != s->size) return fail(s, "read needs exactly the ready message's size");
  if (n) memcpy(out, s->incoming, n);
  s->size = 0; s->ready = 0; s->in_message = 0;
  return 0;
}
