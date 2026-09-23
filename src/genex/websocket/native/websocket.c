/* libcurl owns HTTP upgrade, masking, TLS verification and control frames.
 * This adapter supplies bounded message reassembly and an outbound queue so
 * the Gene frame loop never waits for socket writability. */
#include <curl/curl.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_MESSAGE (16u * 1024u * 1024u)
#define MAX_QUEUED (8u * 1024u * 1024u)
#define MAX_QUEUE_COUNT 256

typedef struct Message {
  struct Message *next;
  size_t size, offset;
  unsigned char data[];
} Message;
typedef struct GXSocket {
  CURL *curl;
  pthread_t owner;
  char error[CURL_ERROR_SIZE];
  unsigned char *incoming;
  size_t size, capacity;
  int ready, kind, in_message, closed;
  Message *head, *tail;
  size_t queued_bytes, queue_count;
} GXSocket;

static _Thread_local char open_error[CURL_ERROR_SIZE];
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

void gx_ws_free(GXSocket *s) {
  if (!s) return;
  if (s->curl) {
    if (!s->closed && !s->head) {
      const unsigned char normal[] = {3, 232}; /* close code 1000 */
      size_t sent;
      (void)curl_ws_send(s->curl, normal, sizeof normal, &sent, 0, CURLWS_CLOSE);
    }
    curl_easy_cleanup(s->curl);
  }
  while (s->head) { Message *next = s->head->next; free(s->head); s->head = next; }
  free(s->incoming); free(s);
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

static GXSocket *open_socket(const char *url, const char *protocol, int timeout_ms) {
  open_error[0] = 0;
  if ((strncmp(url, "ws://", 5) && strncmp(url, "wss://", 6)) || timeout_ms < 1) {
    snprintf(open_error, sizeof open_error, "expected a ws:// or wss:// URL and a positive timeout");
    return NULL;
  }
  if (protocol && !valid_protocol(protocol)) {
    snprintf(open_error, sizeof open_error, "a subprotocol is 1-64 letters, digits, '.', '_' or '-'");
    return NULL;
  }
  struct curl_slist *headers = NULL;
  CURLcode rc = curl_global_init(CURL_GLOBAL_DEFAULT);
  if (rc != CURLE_OK) { snprintf(open_error, sizeof open_error, "%s", curl_easy_strerror(rc)); return NULL; }
  GXSocket *s = calloc(1, sizeof *s);
  if (!s) { curl_global_cleanup(); snprintf(open_error, sizeof open_error, "out of memory"); return NULL; }
  s->owner = pthread_self();
  s->curl = curl_easy_init();
  if (!s->curl) { fail(s, "curl initialization failed"); goto error; }
#define SET(option, value) do { rc = curl_easy_setopt(s->curl, option, value); if (rc != CURLE_OK) goto error; } while (0)
  SET(CURLOPT_ERRORBUFFER, s->error);
  SET(CURLOPT_URL, url);
  SET(CURLOPT_CONNECT_ONLY, 2L);
  SET(CURLOPT_CONNECTTIMEOUT_MS, (long)timeout_ms);
  SET(CURLOPT_TIMEOUT_MS, (long)timeout_ms);
  SET(CURLOPT_NOSIGNAL, 1L);
  if (protocol) {
    char line[128];
    snprintf(line, sizeof line, "Sec-WebSocket-Protocol: %s", protocol);
    struct curl_slist *more = curl_slist_append(headers, line);
    if (!more) { fail(s, "out of memory"); goto error; }
    headers = more;
    SET(CURLOPT_HTTPHEADER, headers);
  }
  rc = curl_easy_perform(s->curl);
  if (rc != CURLE_OK) goto error;
  if (protocol) {
    /* The server must select the offered protocol (RFC 6455 section 4.1): a
     * peer that ignored it does not speak this application's protocol. The
     * 101 upgrade is an informational response, so its headers are CURLH_1XX. */
    struct curl_header *selected = NULL;
    if (curl_easy_header(s->curl, "Sec-WebSocket-Protocol", 0,
                         CURLH_HEADER | CURLH_1XX, -1, &selected)
          != CURLHE_OK || !selected || strcmp(selected->value, protocol) != 0) {
      fail(s, "the server did not select the offered WebSocket subprotocol");
      rc = CURLE_OK;
      goto error;
    }
    /* libcurl keeps its own reference to the header list only for the
     * transfer that already finished. */
    SET(CURLOPT_HTTPHEADER, NULL);
    curl_slist_free_all(headers);
  }
  return s;
error:
  snprintf(open_error, sizeof open_error, "%s", s->error[0] ? s->error : curl_easy_strerror(rc));
  s->closed = 1; gx_ws_free(s); curl_slist_free_all(headers); return NULL;
#undef SET
}

GXSocket *gx_ws_connect(const char *url, int timeout_ms) {
  return open_socket(url, NULL, timeout_ms);
}

GXSocket *gx_ws_connect_protocol(const char *url, const char *protocol, int timeout_ms) {
  return open_socket(url, protocol, timeout_ms);
}

int gx_ws_send(GXSocket *s, void *data, size_t n) {
  if (owner(s) != 0) return -1;
  if (s->closed) return fail(s, "socket is closed");
  if (n > MAX_QUEUED || s->queued_bytes > MAX_QUEUED - n || s->queue_count >= MAX_QUEUE_COUNT)
    return fail(s, "WebSocket output queue is full");
  Message *m = malloc(sizeof *m + n);
  if (!m) return fail(s, "out of memory");
  m->next = NULL; m->size = n; m->offset = 0;
  if (n) memcpy(m->data, data, n);
  if (s->tail) s->tail->next = m; else s->head = m;
  s->tail = m; s->queued_bytes += n; s->queue_count++;
  return 0;
}

static int flush(GXSocket *s) {
  for (int work = 0; s->head && work < 64; work++) {
    Message *m = s->head;
    size_t sent = 0;
    CURLcode rc = curl_ws_send(s->curl, m->data + m->offset, m->size - m->offset,
                               &sent, 0, CURLWS_BINARY);
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

int gx_ws_poll(GXSocket *s) {
  if (owner(s) != 0 || s->closed) return -1;
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
    if (received > MAX_MESSAGE - s->size || left < 0 || (uint64_t)left > MAX_MESSAGE - s->size - received) {
      s->closed = 1; return fail(s, "WebSocket message exceeds 16 MiB");
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
