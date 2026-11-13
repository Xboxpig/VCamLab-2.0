#import <Foundation/Foundation.h>
#import "../src/VCMJPEGPushServer.h"
#import <unistd.h>

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) return 64;
        int port = atoi(argv[1]);
        if (port < 1 || port > 65535) return 64;
        if (getuid() == 0 && (setgid(501) || setuid(501))) return 77;
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        __block uint64_t byteCount = 0, starts = 0, ends = 0;
        __block unsigned char previous = 0;
        VCMJPEGPushServer *server = [[VCMJPEGPushServer alloc] initWithPort:(uint16_t)port path:@"/obs"];
        server.dataHandler = ^(NSData *data) {
            const unsigned char *bytes = data.bytes;
            for (NSUInteger i = 0; i < data.length; i++) {
                if (previous == 0xFF && bytes[i] == 0xD8) starts++;
                if (previous == 0xFF && bytes[i] == 0xD9) ends++;
                previous = bytes[i];
            }
            byteCount += data.length;
        };
        server.connectionHandler = ^(BOOL connected) {
            printf("connection=%s\n", connected ? "open" : "closed");
            fflush(stdout);
            if (!connected) dispatch_semaphore_signal(done);
        };
        NSError *error = nil;
        if (![server startWithError:&error]) {
            fprintf(stderr, "listen failed: %s\n", error.description.UTF8String);
            return 1;
        }
        printf("READY uid=%u port=%d\n", getuid(), port);
        fflush(stdout);
        long timeout = dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC));
        [server stop];
        printf("bytes=%llu jpeg-starts=%llu jpeg-ends=%llu\n", byteCount, starts, ends);
        return timeout || starts < 5 || ends < 5 ? 1 : 0;
    }
}
