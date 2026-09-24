#ifndef GENE_ARCHIVE_CODEC_H
#define GENE_ARCHIVE_CODEC_H

#include <stddef.h>
#include <stdint.h>

#define GENE_ARCHIVE_CODEC_ABI 1
#define GENE_ARCHIVE_GZIP_DECODE 1
#define GENE_ARCHIVE_GZIP_ENCODE 2
#define GENE_ARCHIVE_RAW_DECODE 3
#define GENE_ARCHIVE_RAW_ENCODE 4
#define GENE_ARCHIVE_CONTINUE 0
#define GENE_ARCHIVE_FLUSH 1
#define GENE_ARCHIVE_FINISH 2
#define GENE_ARCHIVE_STREAM_END 1
#define GENE_ARCHIVE_NEEDS_INPUT 2

typedef struct GeneArchiveStream GeneArchiveStream;

int gene_archive_codec_abi(void);
uint64_t gene_archive_live_streams(void);
GeneArchiveStream *gene_archive_stream_open(int mode);
int gene_archive_stream_step(GeneArchiveStream *stream, const uint8_t *input,
                             size_t input_length, uint8_t *output,
                             size_t output_capacity, int action,
                             size_t *consumed, size_t *produced);
const char *gene_archive_stream_error(const GeneArchiveStream *stream);
int gene_archive_stream_close(GeneArchiveStream *stream);
void gene_archive_stream_release(void *stream);
int gene_archive_stream_feed(GeneArchiveStream *stream, const uint8_t *input,
                             size_t input_length);
int gene_archive_stream_action(GeneArchiveStream *stream, size_t action);
int gene_archive_stream_pull(GeneArchiveStream *stream, uint8_t *output,
                             size_t output_capacity);
uint32_t gene_archive_crc32(uint32_t seed, const uint8_t *data, size_t length);

#endif
