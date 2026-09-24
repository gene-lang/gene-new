#include "codec.h"

#include <limits.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

#define GENE_ARCHIVE_STEP_LIMIT (64u * 1024u)

struct GeneArchiveStream {
  z_stream z;
  int mode;
  int finished;
  int member_boundary;
  size_t pending_length;
  size_t pending_position;
  int pending_action;
  uint8_t pending_input[GENE_ARCHIVE_STEP_LIMIT];
  char error[128];
};

static atomic_uint_fast64_t live_streams;

int gene_archive_codec_abi(void) { return GENE_ARCHIVE_CODEC_ABI; }

uint64_t gene_archive_live_streams(void) {
  return atomic_load(&live_streams);
}

static int is_encoder(int mode) {
  return mode == GENE_ARCHIVE_GZIP_ENCODE ||
         mode == GENE_ARCHIVE_RAW_ENCODE;
}

GeneArchiveStream *gene_archive_stream_open(int mode) {
  if (mode < GENE_ARCHIVE_GZIP_DECODE || mode > GENE_ARCHIVE_RAW_ENCODE)
    return NULL;
  GeneArchiveStream *stream = calloc(1, sizeof(*stream));
  if (!stream) return NULL;
  stream->mode = mode;
  int window_bits = mode <= GENE_ARCHIVE_GZIP_ENCODE
                    ? MAX_WBITS + 16 : -MAX_WBITS;
  int status = is_encoder(mode)
    ? deflateInit2(&stream->z, Z_DEFAULT_COMPRESSION, Z_DEFLATED,
                   window_bits, MAX_MEM_LEVEL, Z_DEFAULT_STRATEGY)
    : inflateInit2(&stream->z, window_bits);
  if (status != Z_OK) {
    free(stream);
    return NULL;
  }
  atomic_fetch_add(&live_streams, 1);
  return stream;
}

int gene_archive_stream_step(GeneArchiveStream *stream, const uint8_t *input,
                             size_t input_length, uint8_t *output,
                             size_t output_capacity, int action,
                             size_t *consumed, size_t *produced) {
  if (!stream || !output || !consumed || !produced ||
      (input_length > 0 && !input) || input_length > GENE_ARCHIVE_STEP_LIMIT ||
      output_capacity == 0 || output_capacity > GENE_ARCHIVE_STEP_LIMIT ||
      action < GENE_ARCHIVE_CONTINUE || action > GENE_ARCHIVE_FINISH)
    return -1;
  *consumed = 0;
  *produced = 0;
  if (stream->finished) {
    if (input_length > 0) return -1;
    return GENE_ARCHIVE_STREAM_END;
  }
  if (!is_encoder(stream->mode) && action != GENE_ARCHIVE_CONTINUE)
    return -1;
  stream->z.next_in = (Bytef *)input;
  stream->z.avail_in = (uInt)input_length;
  stream->z.next_out = output;
  stream->z.avail_out = (uInt)output_capacity;
  int flush = action == GENE_ARCHIVE_FINISH ? Z_FINISH :
              action == GENE_ARCHIVE_FLUSH ? Z_SYNC_FLUSH : Z_NO_FLUSH;
  int status = is_encoder(stream->mode)
    ? deflate(&stream->z, flush) : inflate(&stream->z, Z_NO_FLUSH);
  *consumed = input_length - stream->z.avail_in;
  *produced = output_capacity - stream->z.avail_out;
  if (status == Z_STREAM_END) {
    stream->finished = 1;
    return GENE_ARCHIVE_STREAM_END;
  }
  if (status == Z_OK) return 0;
  if (status == Z_BUF_ERROR && (*consumed || *produced)) return 0;
  if (status == Z_BUF_ERROR) return GENE_ARCHIVE_NEEDS_INPUT;
  const char *detail = stream->z.msg ? stream->z.msg : zError(status);
  snprintf(stream->error, sizeof(stream->error), "zlib %d: %s", status, detail);
  return -2;
}

const char *gene_archive_stream_error(const GeneArchiveStream *stream) {
  if (!stream) return "invalid archive codec stream";
  return stream->error;
}

int gene_archive_stream_close(GeneArchiveStream *stream) {
  if (!stream) return -1;
  int status = is_encoder(stream->mode)
    ? deflateEnd(&stream->z) : inflateEnd(&stream->z);
  atomic_fetch_sub(&live_streams, 1);
  free(stream);
  return status == Z_OK ? 0 : -2;
}

void gene_archive_stream_release(void *stream) {
  if (stream) (void)gene_archive_stream_close(stream);
}

int gene_archive_stream_feed(GeneArchiveStream *stream, const uint8_t *input,
                             size_t input_length) {
  if (!stream || stream->finished ||
      (input_length > 0 && !input) || input_length > GENE_ARCHIVE_STEP_LIMIT ||
      stream->pending_position < stream->pending_length ||
      stream->pending_action != GENE_ARCHIVE_CONTINUE)
    return -1;
  if (input_length > 0) memcpy(stream->pending_input, input, input_length);
  stream->pending_length = input_length;
  stream->pending_position = 0;
  return (int)input_length;
}

int gene_archive_stream_action(GeneArchiveStream *stream, size_t action) {
  if (!stream || stream->finished ||
      stream->pending_position < stream->pending_length ||
      stream->pending_action != GENE_ARCHIVE_CONTINUE)
    return -1;
  if (stream->mode == GENE_ARCHIVE_GZIP_DECODE &&
      action == GENE_ARCHIVE_FINISH) {
    if (!stream->member_boundary) {
      snprintf(stream->error, sizeof(stream->error),
               "truncated gzip stream");
      return -2;
    }
    stream->finished = 1;
    return 0;
  }
  if (!is_encoder(stream->mode) ||
      (action != GENE_ARCHIVE_FLUSH && action != GENE_ARCHIVE_FINISH))
    return -1;
  stream->pending_action = (int)action;
  return 0;
}

int gene_archive_stream_pull(GeneArchiveStream *stream, uint8_t *output,
                             size_t output_capacity) {
  if (!stream || !output || output_capacity == 0 ||
      output_capacity > GENE_ARCHIVE_STEP_LIMIT) return -2;
  if (stream->finished) return -1;
  for (int iteration = 0; iteration < 4096; ++iteration) {
    size_t consumed = 0, produced = 0;
    const uint8_t *input = stream->pending_position < stream->pending_length
      ? stream->pending_input + stream->pending_position : NULL;
    size_t input_length = stream->pending_length - stream->pending_position;
    if (input_length == 0 && stream->pending_action == GENE_ARCHIVE_CONTINUE)
      return 0;
    if (stream->mode == GENE_ARCHIVE_GZIP_DECODE && input_length > 0)
      stream->member_boundary = 0;
    int status = gene_archive_stream_step(stream, input, input_length,
                                           output, output_capacity,
                                           stream->pending_action,
                                           &consumed, &produced);
    stream->pending_position += consumed;
    if (status < 0) return -2;
    if (status == GENE_ARCHIVE_STREAM_END) {
      if (stream->mode == GENE_ARCHIVE_GZIP_DECODE) {
        if (inflateReset2(&stream->z, MAX_WBITS + 16) != Z_OK) {
          snprintf(stream->error, sizeof(stream->error),
                   "cannot reset gzip decoder between members");
          return -2;
        }
        stream->finished = 0;
        stream->member_boundary = 1;
        if (produced > 0) return (int)produced;
        if (stream->pending_position < stream->pending_length) continue;
        return 0;
      }
      if (stream->pending_position < stream->pending_length) {
        snprintf(stream->error, sizeof(stream->error),
                 "trailing data after compressed stream");
        return -2;
      }
      return produced > 0 ? (int)produced : -1;
    }
    if (stream->pending_action == GENE_ARCHIVE_FLUSH &&
        stream->pending_position == stream->pending_length &&
        stream->z.avail_out > 0)
      stream->pending_action = GENE_ARCHIVE_CONTINUE;
    if (produced > 0) return (int)produced;
    if (stream->pending_position < stream->pending_length) {
      if (consumed == 0) break;
      continue;
    }
    return 0;
  }
  snprintf(stream->error, sizeof(stream->error),
           "compressed stream made no progress within work limit");
  return -2;
}

uint32_t gene_archive_crc32(uint32_t seed, const uint8_t *data, size_t length) {
  if (length > 0 && !data) return seed;
  uLong value = (uLong)seed;
  while (length > 0) {
    uInt n = length > UINT_MAX ? UINT_MAX : (uInt)length;
    value = crc32(value, data, n);
    data += n;
    length -= n;
  }
  return (uint32_t)value;
}
