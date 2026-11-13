#include "../src/VCHTTPChunkDecoder.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

typedef struct { uint8_t bytes[256]; size_t length; } Output;

static bool append(const uint8_t *bytes, size_t length, void *context) {
    Output *out = context;
    if (length > sizeof(out->bytes) - out->length) return false;
    memcpy(out->bytes + out->length, bytes, length);
    out->length += length;
    return true;
}

static void test_every_fragment_size(void) {
    static const uint8_t encoded[] = "4;foo=bar\r\nABCD\r\n3\r\nEFG\r\n0\r\nX-Test: yes\r\n\r\n";
    for (size_t step = 1; step <= sizeof(encoded) - 1; step++) {
        VCChunkDecoder decoder; VCChunkDecoderReset(&decoder);
        Output out = {0};
        for (size_t offset = 0; offset < sizeof(encoded) - 1;) {
            size_t count = sizeof(encoded) - 1 - offset;
            if (count > step) count = step;
            assert(VCChunkDecoderConsume(&decoder, encoded + offset, count, append, &out));
            offset += count;
        }
        assert(decoder.state == VCChunkDone);
        assert(out.length == 7 && memcmp(out.bytes, "ABCDEFG", 7) == 0);
    }
}

static void test_invalid(const char *input) {
    VCChunkDecoder decoder; VCChunkDecoderReset(&decoder);
    Output out = {0};
    assert(!VCChunkDecoderConsume(&decoder, (const uint8_t *)input, strlen(input), append, &out));
    assert(decoder.state == VCChunkInvalid);
}

int main(void) {
    test_every_fragment_size();
    test_invalid("Z\r\n");
    test_invalid("2000001\r\n");
    test_invalid("1\r\nxX\n");
    test_invalid("0\r\n\n");
    test_invalid("0\r\n\r\nextra");
    puts("HTTP chunk decoder tests passed");
    return 0;
}
