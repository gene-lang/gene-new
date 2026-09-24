#define _POSIX_C_SOURCE 200809L
#include "tls.h"

#include <limits.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <openssl/err.h>
#include <openssl/ssl.h>

typedef struct GeneTlsContext {
  SSL_CTX *ssl;
  atomic_uint refs;
} GeneTlsContext;

struct GeneTlsServer {
  pthread_mutex_t lock;
  GeneTlsContext *active;
  int closed;
  atomic_uint refs;
};

struct GeneTlsConnection {
  SSL *ssl;
  GeneTlsContext *context;
};

static atomic_uint_fast64_t live_contexts;
static atomic_uint_fast64_t live_connections;
static atomic_uint active_reload_jobs;
static _Thread_local char last_error[256];

int gene_tls_abi(void) { return GENE_TLS_ABI; }

uint64_t gene_tls_live_contexts(void) {
  return atomic_load(&live_contexts);
}

uint64_t gene_tls_live_connections(void) {
  return atomic_load(&live_connections);
}

const char *gene_tls_last_error(void) { return last_error; }

static void tls_error(const char *where) {
  unsigned long code = ERR_get_error();
  if (code) {
    char detail[160];
    ERR_error_string_n(code, detail, sizeof(detail));
    snprintf(last_error, sizeof(last_error), "%s: %s", where, detail);
  } else {
    snprintf(last_error, sizeof(last_error), "%s", where);
  }
}

static int valid_path(const char *path) {
  return path && *path && strlen(path) <= 4096;
}

static void context_release(GeneTlsContext *context) {
  if (!context) return;
  if (atomic_fetch_sub(&context->refs, 1) == 1) {
    SSL_CTX_free(context->ssl);
    atomic_fetch_sub(&live_contexts, 1);
    free(context);
  }
}

static void server_release(GeneTlsServer *server) {
  if (atomic_fetch_sub(&server->refs, 1) == 1) {
    pthread_mutex_destroy(&server->lock);
    free(server);
  }
}

static GeneTlsContext *context_build(const char *cert_file,
                                      const char *key_file,
                                      const char *client_ca_file,
                                      int require_client_cert) {
  if (!valid_path(cert_file) || !valid_path(key_file) ||
      (require_client_cert != 0 && require_client_cert != 1) ||
      (require_client_cert && !valid_path(client_ca_file)) ||
      (client_ca_file && strlen(client_ca_file) > 4096)) {
    snprintf(last_error, sizeof(last_error), "invalid TLS material paths or client policy");
    return NULL;
  }
  ERR_clear_error();
  SSL_CTX *ssl = SSL_CTX_new(TLS_server_method());
  if (!ssl) { tls_error("cannot create TLS context"); return NULL; }
  if (SSL_CTX_set_min_proto_version(ssl, TLS1_2_VERSION) != 1 ||
      SSL_CTX_use_certificate_chain_file(ssl, cert_file) != 1 ||
      SSL_CTX_use_PrivateKey_file(ssl, key_file, SSL_FILETYPE_PEM) != 1 ||
      SSL_CTX_check_private_key(ssl) != 1) {
    tls_error("TLS certificate and key validation failed");
    SSL_CTX_free(ssl);
    return NULL;
  }
  SSL_CTX_set_options(ssl, SSL_OP_NO_RENEGOTIATION);
  SSL_CTX_set_mode(ssl, SSL_MODE_ENABLE_PARTIAL_WRITE |
                       SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER);
  if (client_ca_file && *client_ca_file) {
    if (SSL_CTX_load_verify_locations(ssl, client_ca_file, NULL) != 1) {
      tls_error("cannot load TLS client CA");
      SSL_CTX_free(ssl);
      return NULL;
    }
  }
  if (require_client_cert) {
    SSL_CTX_set_verify(ssl, SSL_VERIFY_PEER |
                           SSL_VERIFY_FAIL_IF_NO_PEER_CERT, NULL);
  } else {
    SSL_CTX_set_verify(ssl, SSL_VERIFY_NONE, NULL);
  }
  GeneTlsContext *context = calloc(1, sizeof(*context));
  if (!context) {
    snprintf(last_error, sizeof(last_error), "cannot allocate TLS context owner");
    SSL_CTX_free(ssl);
    return NULL;
  }
  context->ssl = ssl;
  atomic_init(&context->refs, 1);
  atomic_fetch_add(&live_contexts, 1);
  return context;
}

GeneTlsServer *gene_tls_server_open(const char *cert_file,
                                    const char *key_file,
                                    const char *client_ca_file,
                                    int require_client_cert) {
  last_error[0] = 0;
  GeneTlsContext *context = context_build(cert_file, key_file,
                                           client_ca_file, require_client_cert);
  if (!context) return NULL;
  GeneTlsServer *server = calloc(1, sizeof(*server));
  if (!server || pthread_mutex_init(&server->lock, NULL) != 0) {
    free(server);
    context_release(context);
    snprintf(last_error, sizeof(last_error), "cannot allocate TLS server owner");
    return NULL;
  }
  server->active = context;
  atomic_init(&server->refs, 1);
  return server;
}

static int reload_impl(GeneTlsServer *server, const char *cert_file,
                        const char *key_file, const char *client_ca_file,
                        int require_client_cert, const atomic_int *cancel) {
  last_error[0] = 0;
  if (!server) return GENE_TLS_ERROR;
  GeneTlsContext *fresh = context_build(cert_file, key_file,
                                         client_ca_file, require_client_cert);
  if (!fresh) return GENE_TLS_ERROR;
#ifdef GENE_TLS_TEST_PAUSE_BEFORE_RELOAD
  struct timespec pause = {0, 100000000};
  nanosleep(&pause, NULL);
#endif
  pthread_mutex_lock(&server->lock);
  if (server->closed || (cancel && atomic_load(cancel))) {
    pthread_mutex_unlock(&server->lock);
    context_release(fresh);
    snprintf(last_error, sizeof(last_error), "%s",
             server->closed ? "TLS server is closed" : "TLS reload cancelled");
    return GENE_TLS_ERROR;
  }
  GeneTlsContext *old = server->active;
  server->active = fresh;
  pthread_mutex_unlock(&server->lock);
  context_release(old);
  return 0;
}

int gene_tls_server_reload(GeneTlsServer *server, const char *cert_file,
                            const char *key_file, const char *client_ca_file,
                            int require_client_cert) {
  return reload_impl(server, cert_file, key_file, client_ca_file,
                     require_client_cert, NULL);
}

void gene_tls_server_close(GeneTlsServer *server) {
  if (!server) return;
  pthread_mutex_lock(&server->lock);
  if (server->closed) {
    pthread_mutex_unlock(&server->lock);
    return;
  }
  server->closed = 1;
  GeneTlsContext *old = server->active;
  server->active = NULL;
  pthread_mutex_unlock(&server->lock);
  context_release(old);
  server_release(server);
}

struct GeneTlsReloadJob {
  pthread_t thread;
  GeneTlsServer *server;
  char *cert_file, *key_file, *client_ca_file;
  int require_client_cert;
  atomic_int done, cancel;
  int result;
  char error[256];
};

static void *reload_worker(void *raw) {
  GeneTlsReloadJob *job = raw;
  job->result = reload_impl(job->server, job->cert_file, job->key_file,
                             job->client_ca_file, job->require_client_cert,
                             &job->cancel);
  snprintf(job->error, sizeof(job->error), "%s", last_error);
  atomic_store_explicit(&job->done, 1, memory_order_release);
  return NULL;
}

GeneTlsReloadJob *gene_tls_reload_start(GeneTlsServer *server,
                                        const char *cert_file,
                                        const char *key_file,
                                        const char *client_ca_file,
                                        int require_client_cert) {
  if (!server || !valid_path(cert_file) || !valid_path(key_file) ||
      (client_ca_file && strlen(client_ca_file) > 4096)) return NULL;
  unsigned int count = atomic_load(&active_reload_jobs);
  while (count < 16u) {
    if (atomic_compare_exchange_weak(&active_reload_jobs, &count, count + 1))
      break;
  }
  if (count >= 16u) return NULL;
  pthread_mutex_lock(&server->lock);
  if (server->closed) {
    pthread_mutex_unlock(&server->lock);
    atomic_fetch_sub(&active_reload_jobs, 1);
    return NULL;
  }
  atomic_fetch_add(&server->refs, 1);
  pthread_mutex_unlock(&server->lock);
  GeneTlsReloadJob *job = calloc(1, sizeof(*job));
  if (!job) { server_release(server); atomic_fetch_sub(&active_reload_jobs, 1); return NULL; }
  job->server = server;
  job->cert_file = strdup(cert_file);
  job->key_file = strdup(key_file);
  job->client_ca_file = client_ca_file ? strdup(client_ca_file) : NULL;
  job->require_client_cert = require_client_cert;
  if (!job->cert_file || !job->key_file ||
      (client_ca_file && !job->client_ca_file) ||
      pthread_create(&job->thread, NULL, reload_worker, job) != 0) {
    free(job->cert_file); free(job->key_file); free(job->client_ca_file);
    free(job);
    server_release(server);
    atomic_fetch_sub(&active_reload_jobs, 1);
    return NULL;
  }
  return job;
}

int gene_tls_reload_poll(const GeneTlsReloadJob *job) {
  if (!job) return GENE_TLS_ERROR;
  if (!atomic_load_explicit(&job->done, memory_order_acquire)) return 0;
  if (job->result == 0) return 1;
  return atomic_load(&job->cancel) ? -2 : GENE_TLS_ERROR;
}

void gene_tls_reload_cancel(GeneTlsReloadJob *job) {
  if (job) atomic_store(&job->cancel, 1);
}

const char *gene_tls_reload_error(const GeneTlsReloadJob *job) {
  return job ? job->error : "invalid TLS reload job";
}

void gene_tls_reload_release(GeneTlsReloadJob *job) {
  if (!job) return;
  atomic_store(&job->cancel, 1);
  pthread_join(job->thread, NULL);
  server_release(job->server);
  free(job->cert_file); free(job->key_file); free(job->client_ca_file);
  free(job);
  atomic_fetch_sub(&active_reload_jobs, 1);
}

GeneTlsConnection *gene_tls_connection_open(GeneTlsServer *server, int fd) {
  last_error[0] = 0;
  if (!server || fd < 0) return NULL;
  pthread_mutex_lock(&server->lock);
  GeneTlsContext *context = server->closed ? NULL : server->active;
  if (context) atomic_fetch_add(&context->refs, 1);
  pthread_mutex_unlock(&server->lock);
  if (!context) return NULL;
  ERR_clear_error();
  SSL *ssl = SSL_new(context->ssl);
  if (!ssl || SSL_set_fd(ssl, fd) != 1) {
    tls_error("cannot create TLS connection");
    if (ssl) SSL_free(ssl);
    context_release(context);
    return NULL;
  }
  SSL_set_accept_state(ssl);
  SSL_set_mode(ssl, SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER);
  GeneTlsConnection *connection = calloc(1, sizeof(*connection));
  if (!connection) {
    snprintf(last_error, sizeof(last_error), "cannot allocate TLS connection owner");
    SSL_free(ssl);
    context_release(context);
    return NULL;
  }
  connection->ssl = ssl;
  connection->context = context;
  atomic_fetch_add(&live_connections, 1);
  return connection;
}

int gene_tls_connection_handshake(GeneTlsConnection *connection) {
  if (!connection) return GENE_TLS_ERROR;
  ERR_clear_error();
  int result = SSL_accept(connection->ssl);
  if (result == 1) return GENE_TLS_READY;
  int reason = SSL_get_error(connection->ssl, result);
  if (reason == SSL_ERROR_WANT_READ) return GENE_TLS_WANT_READ;
  if (reason == SSL_ERROR_WANT_WRITE) return GENE_TLS_WANT_WRITE;
  tls_error("TLS handshake failed");
  return GENE_TLS_ERROR;
}

int gene_tls_connection_read(GeneTlsConnection *connection, uint8_t *output,
                              size_t capacity, size_t *produced) {
  if (!connection || !output || !produced || capacity == 0 ||
      capacity > 65536) return GENE_TLS_ERROR;
  *produced = 0;
  ERR_clear_error();
  size_t length = 0;
  int result = SSL_read_ex(connection->ssl, output, capacity, &length);
  if (result == 1) { *produced = length; return GENE_TLS_READY; }
  int reason = SSL_get_error(connection->ssl, result);
  if (reason == SSL_ERROR_ZERO_RETURN) return GENE_TLS_EOF;
  if (reason == SSL_ERROR_WANT_READ) return GENE_TLS_WANT_READ;
  if (reason == SSL_ERROR_WANT_WRITE) return GENE_TLS_WANT_WRITE;
  tls_error("TLS read failed");
  return GENE_TLS_ERROR;
}

int gene_tls_connection_pending(const GeneTlsConnection *connection) {
  return connection ? SSL_pending(connection->ssl) : 0;
}

int gene_tls_connection_has_pending(const GeneTlsConnection *connection) {
  return connection ? SSL_has_pending(connection->ssl) : 0;
}

int gene_tls_connection_write(GeneTlsConnection *connection,
                               const uint8_t *input, size_t length,
                               size_t *consumed) {
  if (!connection || !input || !consumed || length == 0 ||
      length > 65536) return GENE_TLS_ERROR;
  *consumed = 0;
  ERR_clear_error();
  size_t count = 0;
  int result = SSL_write_ex(connection->ssl, input, length, &count);
  if (result == 1) { *consumed = count; return GENE_TLS_READY; }
  int reason = SSL_get_error(connection->ssl, result);
  if (reason == SSL_ERROR_WANT_READ) return GENE_TLS_WANT_READ;
  if (reason == SSL_ERROR_WANT_WRITE) return GENE_TLS_WANT_WRITE;
  tls_error("TLS write failed");
  return GENE_TLS_ERROR;
}

void gene_tls_connection_close(GeneTlsConnection *connection) {
  if (!connection) return;
  SSL_free(connection->ssl);
  context_release(connection->context);
  atomic_fetch_sub(&live_connections, 1);
  free(connection);
}
