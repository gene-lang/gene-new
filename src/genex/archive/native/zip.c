#if defined(__APPLE__)
#define _DARWIN_C_SOURCE
#else
#define _GNU_SOURCE
#endif
#define _POSIX_C_SOURCE 200809L
#include "zip.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdint.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#if defined(__linux__)
#include <sys/syscall.h>
#ifndef RENAME_NOREPLACE
#define RENAME_NOREPLACE 1u
#endif
#endif
#include <sys/types.h>
#include <time.h>
#include <unistd.h>
#include <utf8proc.h>
#include <zlib.h>

#define ZIP_MAX_ENTRIES 10000u
#define ZIP_MAX_ENTRY_BYTES (128u * 1024u * 1024u)
#define ZIP_MAX_TOTAL_BYTES (1024ull * 1024ull * 1024ull)
#define ZIP_MAX_CENTRAL_BYTES (64u * 1024u * 1024u)
#define ZIP_MAX_NAME_BYTES 4096u
#define ZIP_MAX_ARCHIVE_BYTES (2ull * 1024ull * 1024ull * 1024ull)
#define ZIP_MAX_PREFIXES 100000u
#define ZIP_MAX_PREFIX_BYTES (64u * 1024u * 1024u)

typedef struct ZipEntry {
  char *name;
  char *key;
  uint64_t start, data_start, end;
  uint32_t crc, compressed, uncompressed;
  uint16_t flags, method;
  int directory;
} ZipEntry;

typedef struct ZipPrefix {
  char *normalized;
  const char *raw;
  size_t raw_length;
} ZipPrefix;

static _Thread_local char last_error[256];

const char *gene_archive_zip_last_error(void) { return last_error; }

static int fail(const char *reason) {
  snprintf(last_error, sizeof(last_error), "%s", reason);
  return -1;
}

static uint16_t le16(const uint8_t *p) {
  return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
}

static uint32_t le32(const uint8_t *p) {
  return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
         ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static int read_at(int fd, uint64_t offset, void *out, size_t length) {
  uint8_t *next = out;
  while (length > 0) {
    ssize_t n = pread(fd, next, length, (off_t)offset);
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) return -1;
    next += n;
    offset += (uint64_t)n;
    length -= (size_t)n;
  }
  return 0;
}

static int utf8_valid(const uint8_t *name, size_t length) {
  for (size_t i = 0; i < length;) {
    uint32_t cp;
    uint8_t a = name[i];
    size_t width;
    if (a < 0x80) { cp = a; width = 1; }
    else if (a >= 0xc2 && a <= 0xdf) { cp = a & 0x1f; width = 2; }
    else if (a >= 0xe0 && a <= 0xef) { cp = a & 0x0f; width = 3; }
    else if (a >= 0xf0 && a <= 0xf4) { cp = a & 0x07; width = 4; }
    else return 0;
    if (i + width > length) return 0;
    for (size_t j = 1; j < width; ++j) {
      if ((name[i + j] & 0xc0) != 0x80) return 0;
      cp = (cp << 6) | (name[i + j] & 0x3f);
    }
    if ((width == 2 && cp < 0x80) ||
        (width == 3 && cp < 0x800) ||
        (width == 4 && cp < 0x10000) || cp > 0x10ffff ||
        (cp >= 0xd800 && cp <= 0xdfff) || cp < 0x20 || cp == 0x7f)
      return 0;
    i += width;
  }
  return 1;
}

static int safe_name(const uint8_t *name, size_t length) {
  if (length == 0 || length > ZIP_MAX_NAME_BYTES || name[0] == '/' ||
      !utf8_valid(name, length)) return 0;
  size_t segment = 0;
  for (size_t i = 0; i <= length; ++i) {
    if (i < length && (name[i] == '\\' || name[i] == ':' || name[i] == 0))
      return 0;
    if (i == length || name[i] == '/') {
      size_t n = i - segment;
      if (n == 0 && i != length) return 0;
      if (n == 1 && name[segment] == '.') return 0;
      if (n == 2 && name[segment] == '.' && name[segment + 1] == '.')
        return 0;
      segment = i + 1;
    }
  }
  return 1;
}

static int extra_supported(const uint8_t *extra, size_t length) {
  for (size_t pos = 0; pos < length;) {
    if (length - pos < 4) return 0;
    uint16_t id = le16(extra + pos);
    uint16_t size = le16(extra + pos + 2);
    pos += 4;
    if (id == 1 || size > length - pos) return 0; /* ZIP64 or truncated */
    pos += size;
  }
  return 1;
}

static int compare_keys(const void *a, const void *b) {
  const ZipEntry *left = a, *right = b;
  return strcmp(left->key, right->key);
}

static int compare_regions(const void *a, const void *b) {
  const ZipEntry *left = a, *right = b;
  return (left->start > right->start) - (left->start < right->start);
}

static int compare_prefixes(const void *a, const void *b) {
  const ZipPrefix *left = a, *right = b;
  return strcmp(left->normalized, right->normalized);
}

static void free_entries(ZipEntry *entries, uint16_t count) {
  if (!entries) return;
  for (uint32_t i = 0; i < count; ++i) {
    free(entries[i].name);
    free(entries[i].key);
  }
  free(entries);
}

static int parse_zip(const char *archive_path, ZipEntry **out_entries,
                     uint16_t *out_count, int *out_fd) {
  last_error[0] = 0;
  if (!archive_path || !*archive_path) return fail("archive path is empty");
  int fd = open(archive_path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
  if (fd < 0) return fail("cannot open regular archive without following links");
  uint8_t *tail = NULL, *central = NULL;
  ZipEntry *entries = NULL;
  ZipPrefix *prefixes = NULL;
  size_t prefix_count = 0, prefix_bytes = 0;
  uint16_t count = 0;
  int result = -1;
  struct stat st;
  if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_size < 22 ||
      (uint64_t)st.st_size > ZIP_MAX_ARCHIVE_BYTES) {
    fail("archive size or file type is unsupported");
    goto cleanup;
  }
  uint64_t file_size = (uint64_t)st.st_size;
  size_t tail_size = file_size < 65557 ? (size_t)file_size : 65557;
  tail = malloc(tail_size);
  if (!tail || read_at(fd, file_size - tail_size, tail, tail_size)) {
    fail("cannot read archive end record");
    goto cleanup;
  }
  ssize_t eocd = -1;
  for (ssize_t pos = (ssize_t)tail_size - 22; pos >= 0; --pos) {
    if (le32(tail + pos) == 0x06054b50 &&
        (size_t)pos + 22 + le16(tail + pos + 20) == tail_size) {
      eocd = pos;
      break;
    }
  }
  if (eocd < 0) { fail("ZIP end record is missing"); goto cleanup; }
  const uint8_t *end = tail + eocd;
  count = le16(end + 10);
  uint32_t central_size = le32(end + 12);
  uint32_t central_offset = le32(end + 16);
  if (le16(end + 4) != 0 || le16(end + 6) != 0 ||
      le16(end + 8) != count || count == 0xffff ||
      count > ZIP_MAX_ENTRIES || central_size == 0xffffffff ||
      central_offset == 0xffffffff ||
      central_size > ZIP_MAX_CENTRAL_BYTES ||
      (uint64_t)central_offset + central_size !=
        file_size - tail_size + (uint64_t)eocd) {
    fail("multi-disk, ZIP64, oversized, or misplaced central directory");
    goto cleanup;
  }
  central = malloc(central_size ? central_size : 1);
  entries = calloc(count ? count : 1, sizeof(*entries));
  prefixes = calloc(ZIP_MAX_PREFIXES, sizeof(*prefixes));
  if (!central || !entries || !prefixes ||
      read_at(fd, central_offset, central, central_size)) {
    fail("cannot read central directory");
    goto cleanup;
  }
  size_t pos = 0;
  uint64_t total_uncompressed = 0;
  for (uint32_t i = 0; i < count; ++i) {
    if (central_size - pos < 46 || le32(central + pos) != 0x02014b50) {
      fail("invalid central directory entry");
      goto cleanup;
    }
    const uint8_t *h = central + pos;
    uint16_t flags = le16(h + 8), method = le16(h + 10);
    uint32_t compressed = le32(h + 20), uncompressed = le32(h + 24);
    uint16_t name_len = le16(h + 28), extra_len = le16(h + 30);
    uint16_t comment_len = le16(h + 32);
    uint32_t local_offset = le32(h + 42);
    size_t entry_size = 46u + name_len + extra_len + comment_len;
    if (entry_size > central_size - pos || le16(h + 6) > 20 ||
        (flags & ~0x080eu) != 0 || (method != 0 && method != 8) ||
        compressed == 0xffffffff || uncompressed == 0xffffffff ||
        local_offset == 0xffffffff || le16(h + 34) != 0 ||
        uncompressed > ZIP_MAX_ENTRY_BYTES ||
        compressed > ZIP_MAX_ENTRY_BYTES + 65536u ||
        local_offset >= central_offset) {
      fail("ZIP entry uses an unsupported feature or exceeds a size cap");
      goto cleanup;
    }
    total_uncompressed += uncompressed;
    if (total_uncompressed > ZIP_MAX_TOTAL_BYTES) {
      fail("ZIP total uncompressed size exceeds cap");
      goto cleanup;
    }
    const uint8_t *name = h + 46;
    if (!safe_name(name, name_len) ||
        !extra_supported(name + name_len, extra_len)) {
      fail("unsafe ZIP path or unsupported extra field");
      goto cleanup;
    }
    int directory = name[name_len - 1] == '/';
    uint8_t host = h[5];
    uint32_t attributes = le32(h + 38);
    if (host == 3 || host == 19) {
      uint32_t kind = (attributes >> 16) & 0170000u;
      if (kind != 0 && kind != 0100000u && kind != 0040000u) {
        fail("ZIP entry is a link, device, or special file");
        goto cleanup;
      }
      if (kind != 0 && (kind == 0040000u) != directory) {
        fail("ZIP directory type disagrees with path");
        goto cleanup;
      }
    }
    if ((attributes & 0x10u) && !directory) {
      fail("ZIP directory attribute disagrees with path");
      goto cleanup;
    }
    if (directory && (compressed != 0 || uncompressed != 0 || method != 0)) {
      fail("ZIP directory contains file data");
      goto cleanup;
    }
    if (!directory && method == 0 && compressed != uncompressed) {
      fail("stored ZIP entry has inconsistent sizes");
      goto cleanup;
    }
    ZipEntry *item = &entries[i];
    item->name = malloc((size_t)name_len + 1);
    if (!item->name) {
      fail("ZIP metadata allocation failed");
      goto cleanup;
    }
    memcpy(item->name, name, name_len);
    item->name[name_len] = 0;
    size_t key_len = name_len - (directory ? 1u : 0u);
    utf8proc_uint8_t *normalized = NULL;
    utf8proc_ssize_t normalized_length = utf8proc_map(name,
      (utf8proc_ssize_t)key_len, &normalized,
      (utf8proc_option_t)(UTF8PROC_STABLE | UTF8PROC_COMPOSE |
                          UTF8PROC_CASEFOLD));
    if (normalized_length < 0 || normalized_length > 16384 || !normalized) {
      free(normalized);
      fail("ZIP path cannot be Unicode-normalized within bound");
      goto cleanup;
    }
    item->key = (char *)normalized;
    for (size_t j = 0; j < name_len; ++j) {
      if (name[j] != '/') continue;
      if (prefix_count >= ZIP_MAX_PREFIXES) {
        fail("ZIP directory prefix count exceeds cap");
        goto cleanup;
      }
      utf8proc_uint8_t *prefix = NULL;
      utf8proc_ssize_t prefix_length = utf8proc_map(name,
        (utf8proc_ssize_t)j, &prefix,
        (utf8proc_option_t)(UTF8PROC_STABLE | UTF8PROC_COMPOSE |
                            UTF8PROC_CASEFOLD));
      if (prefix_length < 0 || !prefix ||
          (size_t)prefix_length > ZIP_MAX_PREFIX_BYTES - prefix_bytes) {
        free(prefix);
        fail("ZIP directory prefix metadata exceeds cap");
        goto cleanup;
      }
      prefix_bytes += (size_t)prefix_length;
      prefixes[prefix_count].normalized = (char *)prefix;
      prefixes[prefix_count].raw = item->name;
      prefixes[prefix_count].raw_length = j;
      ++prefix_count;
    }
    item->crc = le32(h + 16);
    item->compressed = compressed;
    item->uncompressed = uncompressed;
    item->flags = flags;
    item->method = method;
    item->start = local_offset;
    item->directory = directory;

    uint8_t local[30];
    if (read_at(fd, local_offset, local, sizeof(local)) ||
        le32(local) != 0x04034b50 || le16(local + 4) > 20 ||
        le16(local + 6) != flags ||
        le16(local + 8) != method || le16(local + 26) != name_len) {
      fail("local ZIP header disagrees with central directory");
      goto cleanup;
    }
    uint16_t local_extra = le16(local + 28);
    uint64_t data_start = (uint64_t)local_offset + 30 + name_len + local_extra;
    uint64_t data_end = data_start + compressed;
    if (data_end > central_offset) {
      fail("ZIP entry data overlaps central directory");
      goto cleanup;
    }
    uint8_t local_name[ZIP_MAX_NAME_BYTES];
    if (read_at(fd, (uint64_t)local_offset + 30, local_name, name_len) ||
        memcmp(local_name, name, name_len) != 0) {
      fail("local ZIP path disagrees with central directory");
      goto cleanup;
    }
    if (local_extra > 0) {
      uint8_t *extra_data = malloc(local_extra);
      if (!extra_data ||
          read_at(fd, (uint64_t)local_offset + 30 + name_len,
                  extra_data, local_extra) ||
          !extra_supported(extra_data, local_extra)) {
        free(extra_data);
        fail("unsupported or malformed local ZIP extra field");
        goto cleanup;
      }
      free(extra_data);
    }
    if (!(flags & 8)) {
      if (le32(local + 14) != item->crc ||
          le32(local + 18) != compressed ||
          le32(local + 22) != uncompressed) {
        fail("local ZIP checksum or sizes disagree");
        goto cleanup;
      }
    } else {
      if ((le32(local + 14) != 0 && le32(local + 14) != item->crc) ||
          (le32(local + 18) != 0 && le32(local + 18) != compressed) ||
          (le32(local + 22) != 0 && le32(local + 22) != uncompressed)) {
        fail("local ZIP descriptor placeholders disagree");
        goto cleanup;
      }
      uint8_t descriptor[16];
      if (data_end + 12 > central_offset ||
          read_at(fd, data_end, descriptor, 12)) {
        fail("ZIP data descriptor is truncated");
        goto cleanup;
      }
      size_t descriptor_size = 12;
      if (le32(descriptor) == item->crc &&
          le32(descriptor + 4) == compressed &&
          le32(descriptor + 8) == uncompressed) {
        descriptor_size = 12;
      } else if (le32(descriptor) == 0x08074b50) {
        descriptor_size = 16;
        if (data_end + 16 > central_offset ||
            read_at(fd, data_end, descriptor, 16)) {
          fail("ZIP data descriptor is truncated");
          goto cleanup;
        }
      } else {
        fail("ZIP data descriptor disagrees with central directory");
        goto cleanup;
      }
      const uint8_t *values = descriptor + (descriptor_size == 16 ? 4 : 0);
      if (le32(values) != item->crc ||
          le32(values + 4) != compressed ||
          le32(values + 8) != uncompressed) {
        fail("ZIP data descriptor disagrees with central directory");
        goto cleanup;
      }
      data_end += descriptor_size;
    }
    item->end = data_end;
    item->data_start = data_start;
    pos += entry_size;
  }
  if (pos != central_size) {
    fail("unexpected central directory records");
    goto cleanup;
  }
  qsort(prefixes, prefix_count, sizeof(*prefixes), compare_prefixes);
  for (size_t i = 1; i < prefix_count; ++i) {
    if (strcmp(prefixes[i - 1].normalized,
               prefixes[i].normalized) == 0 &&
        (prefixes[i - 1].raw_length != prefixes[i].raw_length ||
         memcmp(prefixes[i - 1].raw, prefixes[i].raw,
                prefixes[i].raw_length) != 0)) {
      fail("duplicate normalized ZIP directory component");
      goto cleanup;
    }
  }
  qsort(entries, count, sizeof(*entries), compare_keys);
  for (uint32_t i = 1; i < count; ++i) {
    if (strcmp(entries[i - 1].key, entries[i].key) == 0) {
      fail("duplicate normalized ZIP path");
      goto cleanup;
    }
  }
  qsort(entries, count, sizeof(*entries), compare_regions);
  for (uint32_t i = 0; i < count; ++i) {
    if ((i == 0 && entries[i].start != 0) ||
        (i > 0 && entries[i].start < entries[i - 1].end) ||
        entries[i].end > central_offset) {
      fail("ZIP local records overlap or contain an archive prefix");
      goto cleanup;
    }
  }
  result = count;
  *out_entries = entries;
  *out_count = count;
  *out_fd = fd;
  entries = NULL;
  fd = -1;
cleanup:
  if (prefixes) {
    for (size_t i = 0; i < prefix_count; ++i)
      free(prefixes[i].normalized);
  }
  free(prefixes);
  free_entries(entries, count);
  free(central);
  free(tail);
  if (fd >= 0) close(fd);
  return result;
}

int gene_archive_zip_validate(const char *archive_path) {
  ZipEntry *entries = NULL;
  uint16_t count = 0;
  int fd = -1;
  int result = parse_zip(archive_path, &entries, &count, &fd);
  free_entries(entries, count);
  if (fd >= 0) close(fd);
  return result;
}

static int write_all(int fd, const uint8_t *data, size_t length) {
  while (length > 0) {
    ssize_t n = write(fd, data, length);
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) return -1;
    data += n;
    length -= (size_t)n;
  }
  return 0;
}

static int exact_child_present(int dirfd, const char *name) {
  int copy = openat(dirfd, ".",
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (copy < 0) return -1;
  DIR *dir = fdopendir(copy);
  if (!dir) { close(copy); return -1; }
  int found = 0;
  struct dirent *entry;
  while ((entry = readdir(dir)) != NULL) {
    if (strcmp(entry->d_name, name) == 0) { found = 1; break; }
  }
  closedir(dir);
  return found;
}

static int ensure_directory(int parentfd, const char *name) {
  if (mkdirat(parentfd, name, 0700) != 0) {
    if (errno != EEXIST || exact_child_present(parentfd, name) != 1)
      return -1;
  }
  return openat(parentfd, name,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
}

static int open_safe_parent(const char *destination, char *base,
                            size_t base_capacity) {
  size_t length = destination ? strlen(destination) : 0;
  if (length == 0 || length > 4096) return -1;
  const char *slash = strrchr(destination, '/');
  const char *leaf = slash ? slash + 1 : destination;
  size_t leaf_length = strlen(leaf);
  if (leaf_length == 0 || leaf_length >= base_capacity ||
      strcmp(leaf, ".") == 0 || strcmp(leaf, "..") == 0 ||
      strchr(leaf, ':') || strchr(leaf, '\\')) return -1;
  memcpy(base, leaf, leaf_length + 1);
  int fd = open(destination[0] == '/' ? "/" : ".",
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  if (fd < 0) return -1;
  size_t parent_length = slash ? (size_t)(slash - destination) : 0;
  size_t pos = destination[0] == '/' ? 1 : 0;
  while (pos < parent_length) {
    size_t start = pos;
    while (pos < parent_length && destination[pos] != '/') ++pos;
    size_t n = pos - start;
    char component[4097];
    if (n == 1 && destination[start] == '.') {
      if (pos < parent_length) ++pos;
      continue;
    }
    if (n == 0 || n >= sizeof(component) ||
        (n == 2 && destination[start] == '.' &&
         destination[start + 1] == '.')) {
      close(fd);
      return -1;
    }
    memcpy(component, destination + start, n);
    component[n] = 0;
    int child = openat(fd, component,
                       O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    close(fd);
    if (child < 0) return -1;
    fd = child;
    if (pos < parent_length) ++pos;
  }
  return fd;
}

static int parent_for_entry(int stagefd, const char *path,
                             char *leaf, size_t leaf_capacity) {
  size_t length = strlen(path);
  if (length > 0 && path[length - 1] == '/') --length;
  size_t last = length;
  while (last > 0 && path[last - 1] != '/') --last;
  size_t leaf_length = length - last;
  if (leaf_length == 0 || leaf_length >= leaf_capacity) return -1;
  memcpy(leaf, path + last, leaf_length);
  leaf[leaf_length] = 0;
  int fd = dup(stagefd);
  if (fd < 0) return -1;
  for (size_t pos = 0; pos < last;) {
    size_t start = pos;
    while (pos < last && path[pos] != '/') ++pos;
    size_t n = pos - start;
    char component[4097];
    if (n == 0 || n >= sizeof(component)) { close(fd); return -1; }
    memcpy(component, path + start, n);
    component[n] = 0;
    int child = ensure_directory(fd, component);
    close(fd);
    if (child < 0) return -1;
    fd = child;
    ++pos;
  }
  return fd;
}

static int cancelled(const atomic_int *cancel) {
  return cancel && atomic_load(cancel);
}

static int extract_file(int archivefd, const ZipEntry *entry, int outputfd,
                        const atomic_int *cancel) {
  uint8_t input[65536], output[65536];
  uint64_t actual = 0;
  uLong crc = crc32(0, Z_NULL, 0);
  if (entry->method == 0) {
    uint64_t position = 0;
    while (position < entry->compressed) {
      if (cancelled(cancel)) return fail("ZIP extraction cancelled");
      size_t n = entry->compressed - position > sizeof(input)
        ? sizeof(input) : (size_t)(entry->compressed - position);
      if (read_at(archivefd, entry->data_start + position, input, n))
        return fail("stored ZIP data is truncated");
      actual += n;
      if (actual > entry->uncompressed || actual > ZIP_MAX_ENTRY_BYTES)
        return fail("stored ZIP output exceeds declared size");
      crc = crc32(crc, input, (uInt)n);
      if (write_all(outputfd, input, n))
        return fail("cannot write extracted ZIP file");
      position += n;
    }
  } else {
    z_stream stream = {0};
    if (inflateInit2(&stream, -MAX_WBITS) != Z_OK)
      return fail("cannot initialize ZIP deflate decoder");
    uint64_t remaining = entry->compressed;
    uint64_t position = entry->data_start;
    int complete = 0;
    for (;;) {
      if (cancelled(cancel)) break;
      if (stream.avail_in == 0 && remaining > 0) {
        size_t n = remaining > sizeof(input) ? sizeof(input) : (size_t)remaining;
        if (read_at(archivefd, position, input, n)) break;
        position += n;
        remaining -= n;
        stream.next_in = input;
        stream.avail_in = (uInt)n;
      }
      uInt before = stream.avail_in;
      stream.next_out = output;
      stream.avail_out = sizeof(output);
      int status = inflate(&stream, Z_NO_FLUSH);
      size_t produced = sizeof(output) - stream.avail_out;
      if (produced > 0) {
        actual += produced;
        if (actual > entry->uncompressed || actual > ZIP_MAX_ENTRY_BYTES) break;
        crc = crc32(crc, output, (uInt)produced);
        if (write_all(outputfd, output, produced)) break;
      }
      if (status == Z_STREAM_END) {
        complete = remaining == 0 && stream.avail_in == 0;
        break;
      }
      if (status != Z_OK && status != Z_BUF_ERROR) break;
      if (before == stream.avail_in && produced == 0) break;
      if (stream.avail_in == 0 && remaining == 0 && produced == 0) break;
    }
    inflateEnd(&stream);
    if (cancelled(cancel)) return fail("ZIP extraction cancelled");
    if (!complete) return fail("ZIP deflate data is corrupt or incomplete");
  }
  if (actual != entry->uncompressed || (uint32_t)crc != entry->crc)
    return fail("ZIP entry size or CRC32 disagrees with content");
  if (fsync(outputfd) != 0) return fail("cannot synchronize extracted ZIP file");
  return 0;
}

static int remove_tree_contents(int dirfd) {
  int copy = openat(dirfd, ".",
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (copy < 0) return -1;
  DIR *dir = fdopendir(copy);
  if (!dir) { close(copy); return -1; }
  int status = 0;
  struct dirent *entry;
  while ((entry = readdir(dir)) != NULL) {
    if (strcmp(entry->d_name, ".") == 0 ||
        strcmp(entry->d_name, "..") == 0) continue;
    struct stat st;
    if (fstatat(dirfd, entry->d_name, &st, AT_SYMLINK_NOFOLLOW) != 0) {
      status = -1; break;
    }
    if (S_ISDIR(st.st_mode)) {
      int child = openat(dirfd, entry->d_name,
                         O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
      if (child < 0) { status = -1; break; }
      status = remove_tree_contents(child);
      close(child);
      if (status || unlinkat(dirfd, entry->d_name, AT_REMOVEDIR)) {
        status = -1; break;
      }
    } else if (unlinkat(dirfd, entry->d_name, 0) != 0) {
      status = -1; break;
    }
  }
  closedir(dir);
  return status;
}

static atomic_uint_fast64_t stage_sequence;
#define GENE_ARCHIVE_MAX_JOBS 16u
static atomic_uint active_jobs;

static int extract_zip_impl(const char *archive_path,
                            const char *destination_path,
                            const atomic_int *cancel) {
  ZipEntry *entries = NULL;
  uint16_t count = 0;
  int archivefd = -1, parentfd = -1, stagefd = -1;
  int result = -1;
  char base[4097], stage[96] = "";
  if (parse_zip(archive_path, &entries, &count, &archivefd) < 0) return -1;
  parentfd = open_safe_parent(destination_path, base, sizeof(base));
  if (parentfd < 0) { fail("destination parent has an unsafe component"); goto done; }
  struct stat existing;
  if (fstatat(parentfd, base, &existing, AT_SYMLINK_NOFOLLOW) == 0 ||
      errno != ENOENT) {
    fail("ZIP destination already exists or cannot be inspected");
    goto done;
  }
  for (int attempt = 0; attempt < 128; ++attempt) {
    uint64_t id = atomic_fetch_add(&stage_sequence, 1) + 1;
    snprintf(stage, sizeof(stage), ".gene-archive-%ld-%llu",
             (long)getpid(), (unsigned long long)id);
    if (mkdirat(parentfd, stage, 0700) == 0) break;
    if (errno != EEXIST) {
      fail("cannot create ZIP staging directory");
      goto done;
    }
    stage[0] = 0;
  }
  if (stage[0] == 0) { fail("ZIP staging names are exhausted"); goto done; }
  stagefd = openat(parentfd, stage,
                   O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (stagefd < 0) { fail("cannot open ZIP staging directory"); goto done; }
  for (uint32_t i = 0; i < count; ++i) {
    if (cancelled(cancel)) { fail("ZIP extraction cancelled"); goto done; }
    char leaf[4097];
    int dirfd = parent_for_entry(stagefd, entries[i].name,
                                  leaf, sizeof(leaf));
    if (dirfd < 0) { fail("unsafe ZIP directory component"); goto done; }
    if (entries[i].directory) {
      int child = ensure_directory(dirfd, leaf);
      if (child < 0) {
        close(dirfd);
        fail("cannot create ZIP directory");
        goto done;
      }
      close(child);
      if (fsync(dirfd) != 0) {
        close(dirfd);
        fail("cannot synchronize ZIP directory");
        goto done;
      }
    } else {
      int outputfd = openat(dirfd, leaf,
        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
      if (outputfd < 0) {
        close(dirfd);
        fail("cannot create extracted ZIP file exclusively");
        goto done;
      }
      int extracted = extract_file(archivefd, &entries[i], outputfd, cancel);
      int closed = close(outputfd);
      if (extracted || closed || fsync(dirfd) != 0) {
        close(dirfd);
        if (!extracted) fail("cannot retire extracted ZIP file");
        goto done;
      }
    }
    close(dirfd);
  }
  if (fsync(stagefd) != 0) { fail("cannot synchronize ZIP staging tree"); goto done; }
#ifdef GENE_ARCHIVE_TEST_PAUSE_BEFORE_PUBLISH
  struct timespec pause = {0, 100000000};
  nanosleep(&pause, NULL);
#endif
  if (cancelled(cancel)) { fail("ZIP extraction cancelled"); goto done; }
#if defined(__APPLE__)
  if (renameatx_np(parentfd, stage, parentfd, base, RENAME_EXCL) != 0) {
#else
  if (syscall(SYS_renameat2, parentfd, stage, parentfd, base,
              RENAME_NOREPLACE) != 0) {
#endif
    fail("exclusive ZIP destination publication failed");
    goto done;
  }
  stage[0] = 0;
  result = count;
done:
  if (stagefd >= 0) close(stagefd);
  if (stage[0] != 0 && parentfd >= 0) {
    int cleanupfd = openat(parentfd, stage,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    int cleanup = cleanupfd < 0 ? -1 : remove_tree_contents(cleanupfd);
    if (cleanupfd >= 0) close(cleanupfd);
    if (cleanup || unlinkat(parentfd, stage, AT_REMOVEDIR) != 0) {
      size_t used = strlen(last_error);
      snprintf(last_error + used, sizeof(last_error) - used,
               "; cleanup remains: %s beside %s", stage,
               destination_path ? destination_path : "<unknown>");
    }
  }
  if (parentfd >= 0) close(parentfd);
  if (archivefd >= 0) close(archivefd);
  free_entries(entries, count);
  return result;
}

int gene_archive_zip_extract(const char *archive_path,
                             const char *destination_path) {
  return extract_zip_impl(archive_path, destination_path, NULL);
}

struct GeneArchiveZipJob {
  pthread_t thread;
  atomic_int cancel;
  atomic_int done;
  int result;
  char error[256];
  char *archive_path;
  char *destination_path;
};

static void *zip_job_worker(void *raw) {
  GeneArchiveZipJob *job = raw;
  job->result = extract_zip_impl(job->archive_path, job->destination_path,
                                  &job->cancel);
  snprintf(job->error, sizeof(job->error), "%s", last_error);
  atomic_store_explicit(&job->done, 1, memory_order_release);
  return NULL;
}

GeneArchiveZipJob *gene_archive_zip_job_start(const char *archive_path,
                                             const char *destination_path) {
  last_error[0] = 0;
  if (!archive_path || !destination_path) {
    fail("archive worker paths are missing");
    return NULL;
  }
  unsigned int count = atomic_load(&active_jobs);
  while (count < GENE_ARCHIVE_MAX_JOBS) {
    if (atomic_compare_exchange_weak(&active_jobs, &count, count + 1)) break;
  }
  if (count >= GENE_ARCHIVE_MAX_JOBS) {
    fail("archive worker limit is reached");
    return NULL;
  }
  GeneArchiveZipJob *job = calloc(1, sizeof(*job));
  if (!job) {
    atomic_fetch_sub(&active_jobs, 1);
    fail("cannot allocate archive worker");
    return NULL;
  }
  job->archive_path = strdup(archive_path);
  job->destination_path = strdup(destination_path);
  if (!job->archive_path || !job->destination_path ||
      pthread_create(&job->thread, NULL, zip_job_worker, job) != 0) {
    free(job->archive_path);
    free(job->destination_path);
    free(job);
    atomic_fetch_sub(&active_jobs, 1);
    fail("cannot start archive worker thread");
    return NULL;
  }
  return job;
}

int gene_archive_zip_job_poll(const GeneArchiveZipJob *job) {
  if (!job) return -1;
  if (!atomic_load_explicit(&job->done, memory_order_acquire)) return 0;
  if (job->result >= 0) return job->result + 1;
  return atomic_load(&job->cancel) ? -2 : -1;
}

void gene_archive_zip_job_cancel(GeneArchiveZipJob *job) {
  if (job) atomic_store(&job->cancel, 1);
}

const char *gene_archive_zip_job_error(const GeneArchiveZipJob *job) {
  return job ? job->error : "invalid archive extraction job";
}

void gene_archive_zip_job_release(GeneArchiveZipJob *job) {
  if (!job) return;
  atomic_store(&job->cancel, 1);
  pthread_join(job->thread, NULL);
  free(job->archive_path);
  free(job->destination_path);
  free(job);
  atomic_fetch_sub(&active_jobs, 1);
}
