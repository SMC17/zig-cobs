/*
 * cobs_ref.h — independent reference COBS encoder/decoder in C.
 *
 * Algorithm: Cheshire & Baker, "Consistent Overhead Byte Stuffing",
 *            SIGCOMM 1997 (and the canonical 1999 IEEE/ACM Transactions
 *            on Networking writeup). Independent implementation written
 *            from the paper for the zig-cobs differential conformance
 *            test — NOT derived from any specific third-party codebase.
 *
 * Semantics (matches zig-cobs `src/root.zig`):
 *   - Encoder emits the canonical COBS body WITHOUT a trailing 0x00
 *     frame delimiter. Caller appends delimiter when framing on the
 *     wire.
 *   - Worst-case encoded length is `input_len + (input_len / 254) + 1`.
 *   - Encoded output contains zero 0x00 bytes.
 *   - Decoder rejects a 0x00 inside the frame as malformed.
 *
 * Use: include this header, define COBS_REF_IMPLEMENTATION in exactly
 * one translation unit before including, then call `cobs_ref_encode`
 * / `cobs_ref_decode`.
 */

#ifndef COBS_REF_H
#define COBS_REF_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Return values:
 *   >= 0  : number of bytes written to `dst`.
 *   -1    : `dst_cap` is smaller than the worst-case encoded length
 *           (encode) / smaller than the decoded payload (decode).
 *   -2    : malformed COBS frame (decode only). Either truncated, or
 *           contains an embedded 0x00 byte.
 */
typedef ptrdiff_t cobs_ref_ssize_t;

cobs_ref_ssize_t cobs_ref_encode(const uint8_t *src, size_t src_len,
                                 uint8_t *dst, size_t dst_cap);

cobs_ref_ssize_t cobs_ref_decode(const uint8_t *src, size_t src_len,
                                 uint8_t *dst, size_t dst_cap);

static inline size_t cobs_ref_max_encoded_len(size_t src_len) {
    return src_len + (src_len / 254) + 1;
}

#ifdef __cplusplus
}
#endif

#endif /* COBS_REF_H */

#ifdef COBS_REF_IMPLEMENTATION

cobs_ref_ssize_t cobs_ref_encode(const uint8_t *src, size_t src_len,
                                 uint8_t *dst, size_t dst_cap) {
    const size_t required = cobs_ref_max_encoded_len(src_len);
    if (dst_cap < required) return -1;

    /* Classic Cheshire/Baker single-pass encoder.
     *   code_index : position of the current code byte (the run length).
     *   write_index: next free output slot.
     *   code       : current run length being accumulated (1..0xFF).
     *
     * On a zero in the input, we flush the current code and start a new
     * run. On a run hitting 0xFF, we flush a "literal 254 non-zero bytes
     * follow" code and continue without producing an output zero (this
     * is the asymmetry that gives COBS its bounded 0.4% overhead).
     */
    size_t read_index  = 0;
    size_t write_index = 1;
    size_t code_index  = 0;
    uint8_t code       = 1;

    while (read_index < src_len) {
        if (src[read_index] == 0) {
            dst[code_index] = code;
            code_index = write_index++;
            code = 1;
        } else {
            dst[write_index++] = src[read_index];
            code++;
            if (code == 0xFF) {
                dst[code_index] = code;
                code_index = write_index++;
                code = 1;
            }
        }
        read_index++;
    }
    dst[code_index] = code;
    return (cobs_ref_ssize_t)write_index;
}

cobs_ref_ssize_t cobs_ref_decode(const uint8_t *src, size_t src_len,
                                 uint8_t *dst, size_t dst_cap) {
    if (src_len == 0) return 0;

    size_t read_index  = 0;
    size_t write_index = 0;

    while (read_index < src_len) {
        const uint8_t code = src[read_index];
        if (code == 0) return -2;          /* embedded delimiter */
        read_index++;

        for (uint8_t i = 1; i < code; i++) {
            if (read_index >= src_len) return -2;       /* truncated */
            if (write_index >= dst_cap)  return -1;     /* dst too small */
            dst[write_index++] = src[read_index++];
        }

        /* Inject a zero unless this was a max-length (0xFF) literal run
         * OR we have consumed the entire frame. */
        if (code < 0xFF && read_index < src_len) {
            if (write_index >= dst_cap) return -1;
            dst[write_index++] = 0;
        }
    }
    return (cobs_ref_ssize_t)write_index;
}

#endif /* COBS_REF_IMPLEMENTATION */
