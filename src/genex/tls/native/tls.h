#ifndef GENE_TLS_NATIVE_H
#define GENE_TLS_NATIVE_H

#include <stddef.h>
#include <stdint.h>

#define GENE_TLS_ABI 1
#define GENE_TLS_READY 1
#define GENE_TLS_WANT_READ 0
#define GENE_TLS_WANT_WRITE 2
#define GENE_TLS_EOF 3
#define GENE_TLS_ERROR -1

typedef struct GeneTlsServer GeneTlsServer;
typedef struct GeneTlsConnection GeneTlsConnection;
typedef struct GeneTlsReloadJob GeneTlsReloadJob;

int gene_tls_abi(void);
GeneTlsServer *gene_tls_server_open(const char *cert_file,
                                    const char *key_file,
                                    const char *client_ca_file,
                                    int require_client_cert);
int gene_tls_server_reload(GeneTlsServer *server, const char *cert_file,
                            const char *key_file, const char *client_ca_file,
                            int require_client_cert);
void gene_tls_server_close(GeneTlsServer *server);
GeneTlsReloadJob *gene_tls_reload_start(GeneTlsServer *server,
                                        const char *cert_file,
                                        const char *key_file,
                                        const char *client_ca_file,
                                        int require_client_cert);
int gene_tls_reload_poll(const GeneTlsReloadJob *job);
void gene_tls_reload_cancel(GeneTlsReloadJob *job);
const char *gene_tls_reload_error(const GeneTlsReloadJob *job);
void gene_tls_reload_release(GeneTlsReloadJob *job);
GeneTlsConnection *gene_tls_connection_open(GeneTlsServer *server, int fd);
int gene_tls_connection_handshake(GeneTlsConnection *connection);
int gene_tls_connection_read(GeneTlsConnection *connection, uint8_t *output,
                              size_t capacity, size_t *produced);
int gene_tls_connection_pending(const GeneTlsConnection *connection);
int gene_tls_connection_has_pending(const GeneTlsConnection *connection);
int gene_tls_connection_write(GeneTlsConnection *connection,
                               const uint8_t *input, size_t length,
                               size_t *consumed);
void gene_tls_connection_close(GeneTlsConnection *connection);
const char *gene_tls_last_error(void);
uint64_t gene_tls_live_contexts(void);
uint64_t gene_tls_live_connections(void);

#endif
