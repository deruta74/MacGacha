// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
#ifndef MACGACHA_SYSTEM_ARCHIVE_H
#define MACGACHA_SYSTEM_ARCHIVE_H
#include <sys/types.h>
#include <stdint.h>
#include <stddef.h>
// The narrow, stable public libarchive ABI used here. macOS ships the library
// and SDK linker stub, but does not ship its development headers. No implementation
// is bundled: all parsing and decompression use the system library.
struct archive;
struct archive_entry;
struct archive *archive_read_new(void);
int archive_read_support_filter_gzip(struct archive *);
int archive_read_support_filter_xz(struct archive *);
int archive_read_support_format_tar(struct archive *);
int archive_read_support_format_zip(struct archive *);
int archive_read_set_format_option(struct archive *, const char *, const char *, const char *);
int archive_read_open_fd(struct archive *, int, size_t);
int archive_read_next_header(struct archive *, struct archive_entry **);
ssize_t archive_read_data(struct archive *, void *, size_t);
int archive_read_free(struct archive *);
int archive_format(struct archive *);
const char *archive_entry_symlink(struct archive_entry *);
const char *archive_entry_hardlink(struct archive_entry *);
const char *archive_entry_pathname_utf8(struct archive_entry *);
const char *archive_entry_symlink_utf8(struct archive_entry *);
const char *archive_entry_hardlink_utf8(struct archive_entry *);
mode_t archive_entry_filetype(struct archive_entry *);
int64_t archive_entry_size(struct archive_entry *);
int archive_entry_is_encrypted(struct archive_entry *);
#endif
