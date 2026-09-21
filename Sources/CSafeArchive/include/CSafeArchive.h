#ifndef CS_SAFE_ARCHIVE_H
#define CS_SAFE_ARCHIVE_H
#include <stddef.h>
#include <stdint.h>

typedef enum { MS_OK=0, MS_INVALID=1, MS_LIMIT=2, MS_UNSUPPORTED=3,
               MS_INTEGRITY=4, MS_MEMORY=5, MS_DONE=6 } ms_status;
typedef struct {
    uint32_t entry_limit, entry_bytes_limit;
    uint64_t total_bytes_limit;
    uint32_t ratio_limit;
} ms_zip_limits;
typedef struct {
    const uint8_t *name;
    uint16_t name_length, method, flags;
    uint32_t compressed_size, uncompressed_size, crc;
    size_t data_offset;
} ms_zip_entry;
typedef struct {
    const uint8_t *bytes;
    size_t size, central_offset, central_end, cursor;
    uint32_t count, seen;
    uint64_t expanded_total;
    ms_zip_limits limits;
} ms_zip;
typedef struct {
    uint32_t number, wire_type;
    uint64_t integer;
    const uint8_t *bytes;
    size_t length;
} ms_pb_field;

// Views borrow the caller's immutable input. No input is ever executed or written.
ms_status ms_zip_open(const uint8_t *, size_t, ms_zip_limits, ms_zip *);
ms_status ms_zip_next(ms_zip *, ms_zip_entry *);
ms_status ms_zip_extract(const ms_zip *, const ms_zip_entry *, uint8_t *, size_t);
ms_status ms_gzip_decode(const uint8_t *, size_t, uint8_t *, size_t, size_t *);
ms_status ms_pb_next(const uint8_t *, size_t, size_t *, ms_pb_field *);
const char *ms_status_message(ms_status);
#include "MSJNIBridge.h"
#endif
