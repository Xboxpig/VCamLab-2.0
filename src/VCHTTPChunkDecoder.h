#ifndef VC_HTTP_CHUNK_DECODER_H
#define VC_HTTP_CHUNK_DECODER_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* A bounded incremental decoder for HTTP/1.1 chunked request bodies. */
typedef enum {
    VCChunkReadingSize,
    VCChunkReadingData,
    VCChunkReadingDataTerminator,
    VCChunkReadingTrailers,
    VCChunkDone,
    VCChunkInvalid,
} VCChunkState;

typedef struct {
    VCChunkState state;
    uint64_t remaining;
    char line[128];
    size_t lineLength;
    size_t trailerBytes;
    unsigned int terminatorPosition;
} VCChunkDecoder;

typedef bool (*VCChunkBodyCallback)(const uint8_t *bytes, size_t length, void *context);

static inline void VCChunkDecoderReset(VCChunkDecoder *decoder) {
    *decoder = (VCChunkDecoder){0};
}

static inline bool VCChunkParseSize(VCChunkDecoder *decoder) {
    if (decoder->lineLength < 2 || decoder->line[decoder->lineLength - 1] != '\r') return false;
    size_t end = decoder->lineLength - 1;
    uint64_t size = 0;
    size_t digits = 0;
    for (size_t i = 0; i < end; i++) {
        unsigned char c = (unsigned char)decoder->line[i];
        if (c == ';') break;
        unsigned int digit;
        if (c >= '0' && c <= '9') digit = c - '0';
        else if (c >= 'a' && c <= 'f') digit = c - 'a' + 10;
        else if (c >= 'A' && c <= 'F') digit = c - 'A' + 10;
        else return false;
        if (size > (UINT64_C(33554432) - digit) / 16) return false;
        size = size * 16 + digit;
        digits++;
    }
    if (!digits) return false;
    decoder->remaining = size;
    decoder->lineLength = 0;
    decoder->state = size ? VCChunkReadingData : VCChunkReadingTrailers;
    return true;
}

static inline bool VCChunkDecoderConsume(VCChunkDecoder *decoder,
                                         const uint8_t *bytes,
                                         size_t length,
                                         VCChunkBodyCallback callback,
                                         void *context) {
    if (!decoder || (!bytes && length) || !callback || decoder->state == VCChunkInvalid) return false;
    size_t offset = 0;
    while (offset < length) {
        switch (decoder->state) {
            case VCChunkReadingSize: {
                uint8_t c = bytes[offset++];
                if (c == '\n') {
                    if (!VCChunkParseSize(decoder)) goto invalid;
                } else {
                    if (decoder->lineLength >= sizeof(decoder->line)) goto invalid;
                    decoder->line[decoder->lineLength++] = (char)c;
                }
                break;
            }
            case VCChunkReadingData: {
                size_t available = length - offset;
                size_t take = decoder->remaining < available ? (size_t)decoder->remaining : available;
                if (take && !callback(bytes + offset, take, context)) goto invalid;
                offset += take;
                decoder->remaining -= take;
                if (!decoder->remaining) {
                    decoder->terminatorPosition = 0;
                    decoder->state = VCChunkReadingDataTerminator;
                }
                break;
            }
            case VCChunkReadingDataTerminator: {
                uint8_t expected = decoder->terminatorPosition == 0 ? '\r' : '\n';
                if (bytes[offset++] != expected) goto invalid;
                if (++decoder->terminatorPosition == 2) decoder->state = VCChunkReadingSize;
                break;
            }
            case VCChunkReadingTrailers: {
                uint8_t c = bytes[offset++];
                if (++decoder->trailerBytes > 8192 || decoder->lineLength >= sizeof(decoder->line)) goto invalid;
                if (c == '\n') {
                    if (!decoder->lineLength || decoder->line[decoder->lineLength - 1] != '\r') goto invalid;
                    if (decoder->lineLength == 1) decoder->state = VCChunkDone;
                    decoder->lineLength = 0;
                } else {
                    decoder->line[decoder->lineLength++] = (char)c;
                }
                break;
            }
            case VCChunkDone:
            case VCChunkInvalid:
                goto invalid;
        }
    }
    return true;
invalid:
    decoder->state = VCChunkInvalid;
    return false;
}

#endif
