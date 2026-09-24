#ifndef GENE_ARCHIVE_ZIP_H
#define GENE_ARCHIVE_ZIP_H

/* Returns the entry count, or -1 with a thread-local diagnostic. This
 * validates metadata only; extraction must independently enforce creation
 * and decompression limits before publishing a destination. */
int gene_archive_zip_validate(const char *archive_path);
int gene_archive_zip_extract(const char *archive_path,
                             const char *destination_path);
typedef struct GeneArchiveZipJob GeneArchiveZipJob;
GeneArchiveZipJob *gene_archive_zip_job_start(const char *archive_path,
                                             const char *destination_path);
int gene_archive_zip_job_poll(const GeneArchiveZipJob *job);
void gene_archive_zip_job_cancel(GeneArchiveZipJob *job);
const char *gene_archive_zip_job_error(const GeneArchiveZipJob *job);
void gene_archive_zip_job_release(GeneArchiveZipJob *job);
const char *gene_archive_zip_last_error(void);

#endif
