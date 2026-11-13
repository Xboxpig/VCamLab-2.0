#import "VCMJPEGPushServer.h"
#import "VCHTTPChunkDecoder.h"

#import <arpa/inet.h>
#import <errno.h>
#import <fcntl.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <unistd.h>

static const void *VCMJPEGPushQueueKey = &VCMJPEGPushQueueKey;
static const NSUInteger VCMaximumHTTPHeaderBytes = 16384;

@interface VCMJPEGPushServer () {
    uint16_t _port;
    NSString *_path;
    dispatch_queue_t _queue;
    dispatch_source_t _listener;
    dispatch_source_t _client;
    dispatch_source_t _idleTimer;
    int _clientFD;
    NSMutableData *_headerData;
    BOOL _headersComplete;
    BOOL _chunked;
    BOOL _hasContentLength;
    uint64_t _contentRemaining;
    CFAbsoluteTime _lastReadTime;
    VCChunkDecoder _chunkDecoder;
}
@property (atomic, readwrite, getter=isConnected) BOOL connected;
- (void)acceptConnections;
- (void)readClient:(int)clientFD;
- (void)closeClient;
- (BOOL)consumeBody:(const uint8_t *)bytes length:(size_t)length;
@end

static bool VCMJPEGPushConsumeChunk(const uint8_t *bytes, size_t length, void *context) {
    VCMJPEGPushServer *server = (__bridge VCMJPEGPushServer *)context;
    VCMJPEGPushDataHandler handler = server.dataHandler;
    if (handler && length) handler([NSData dataWithBytes:bytes length:length]);
    return true;
}

@implementation VCMJPEGPushServer

- (instancetype)initWithPort:(uint16_t)port path:(NSString *)path {
    self = [super init];
    if (self) {
        _port = port;
        _path = [path copy];
        _clientFD = -1;
        _queue = dispatch_queue_create("com.murkaska.virtualcampro.obs-push", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(_queue, VCMJPEGPushQueueKey, (__bridge void *)self, NULL);
    }
    return self;
}

- (void)performOnQueueAndWait:(dispatch_block_t)block {
    if (dispatch_get_specific(VCMJPEGPushQueueKey) == (__bridge void *)self) block();
    else dispatch_sync(_queue, block);
}

- (BOOL)startWithError:(NSError **)error {
    __block NSError *setupError = nil;
    [self performOnQueueAndWait:^{
        if (self->_listener) return;
        int listenerFD = socket(AF_INET, SOCK_STREAM, 0);
        if (listenerFD < 0) {
            setupError = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
            return;
        }
        int enabled = 1;
        setsockopt(listenerFD, SOL_SOCKET, SO_REUSEADDR, &enabled, sizeof(enabled));
        struct sockaddr_in address = {0};
        address.sin_len = sizeof(address);
        address.sin_family = AF_INET;
        address.sin_port = htons(self->_port);
        address.sin_addr.s_addr = htonl(INADDR_ANY);
        int flags = fcntl(listenerFD, F_GETFL, 0);
        if (flags < 0 || fcntl(listenerFD, F_SETFL, flags | O_NONBLOCK) < 0 ||
            bind(listenerFD, (struct sockaddr *)&address, sizeof(address)) < 0 ||
            listen(listenerFD, 4) < 0) {
            int failure = errno;
            close(listenerFD);
            setupError = [NSError errorWithDomain:NSPOSIXErrorDomain code:failure userInfo:nil];
            return;
        }
        dispatch_source_t listener = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ,
                                                              (uintptr_t)listenerFD, 0, self->_queue);
        if (!listener) {
            close(listenerFD);
            setupError = [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOMEM userInfo:nil];
            return;
        }
        self->_listener = listener;
        __weak VCMJPEGPushServer *weakSelf = self;
        dispatch_source_set_event_handler(listener, ^{ [weakSelf acceptConnections]; });
        dispatch_source_set_cancel_handler(listener, ^{ close(listenerFD); });
        dispatch_resume(listener);

        self->_idleTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self->_queue);
        if (!self->_idleTimer) {
            dispatch_source_cancel(listener);
            self->_listener = nil;
            setupError = [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOMEM userInfo:nil];
            return;
        }
        dispatch_source_set_timer(self->_idleTimer, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                                  5 * NSEC_PER_SEC, NSEC_PER_SEC / 2);
        dispatch_source_set_event_handler(self->_idleTimer, ^{
            VCMJPEGPushServer *server = weakSelf;
            if (server && server->_clientFD >= 0 &&
                CFAbsoluteTimeGetCurrent() - server->_lastReadTime > 15.0) [server closeClient];
        });
        dispatch_resume(self->_idleTimer);
    }];
    if (error) *error = setupError;
    return setupError == nil;
}

- (void)stop {
    [self performOnQueueAndWait:^{
        [self closeClient];
        if (self->_listener) dispatch_source_cancel(self->_listener);
        self->_listener = nil;
        if (self->_idleTimer) dispatch_source_cancel(self->_idleTimer);
        self->_idleTimer = nil;
    }];
}

- (void)dealloc {
    [self stop];
}

- (void)acceptConnections {
    if (!_listener) return;
    int listenerFD = (int)dispatch_source_get_handle(_listener);
    for (;;) {
        int clientFD = accept(listenerFD, NULL, NULL);
        if (clientFD < 0) {
            if (errno == EINTR) continue;
            return;
        }
        int noSigPipe = 1;
        setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe));
        if (_client) {
            static const char busy[] = "HTTP/1.1 409 Conflict\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
            send(clientFD, busy, sizeof(busy) - 1, 0);
            close(clientFD);
            continue;
        }
        int flags = fcntl(clientFD, F_GETFL, 0);
        if (flags < 0 || fcntl(clientFD, F_SETFL, flags | O_NONBLOCK) < 0) {
            close(clientFD);
            continue;
        }
        _clientFD = clientFD;
        _headersComplete = NO;
        _chunked = NO;
        _hasContentLength = NO;
        _contentRemaining = 0;
        _headerData = [NSMutableData data];
        _lastReadTime = CFAbsoluteTimeGetCurrent();
        VCChunkDecoderReset(&_chunkDecoder);
        dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ,
                                                           (uintptr_t)clientFD, 0, _queue);
        if (!source) {
            _clientFD = -1;
            close(clientFD);
            continue;
        }
        _client = source;
        __weak VCMJPEGPushServer *weakSelf = self;
        dispatch_source_set_event_handler(source, ^{ [weakSelf readClient:clientFD]; });
        dispatch_source_set_cancel_handler(source, ^{ close(clientFD); });
        dispatch_resume(source);
    }
}

- (void)closeClient {
    BOOL wasConnected = self.connected;
    self.connected = NO;
    if (_client) dispatch_source_cancel(_client);
    _client = nil;
    _clientFD = -1;
    _headerData = nil;
    _headersComplete = NO;
    VCChunkDecoderReset(&_chunkDecoder);
    if (wasConnected) {
        VCMJPEGPushConnectionHandler handler = self.connectionHandler;
        if (handler) handler(NO);
    }
}

- (void)rejectClient {
    static const char response[] = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
    if (_clientFD >= 0) send(_clientFD, response, sizeof(response) - 1, 0);
    [self closeClient];
}

- (void)finishClient {
    static const char response[] = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
    if (_clientFD >= 0) send(_clientFD, response, sizeof(response) - 1, 0);
    [self closeClient];
}

- (BOOL)parseHeaders:(NSData *)data {
    NSString *text = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    NSArray<NSString *> *lines = [text componentsSeparatedByString:@"\r\n"];
    NSArray<NSString *> *request = [lines.firstObject componentsSeparatedByString:@" "];
    if (request.count != 3 || ![request[0] isEqualToString:@"POST"] ||
        ![request[1] isEqualToString:_path] || ![request[2] hasPrefix:@"HTTP/1."]) return NO;
    NSString *transferEncoding = nil;
    NSString *contentLength = nil;
    BOOL expectContinue = NO;
    for (NSUInteger i = 1; i < lines.count; i++) {
        NSString *line = lines[i];
        if (!line.length) continue;
        NSRange colon = [line rangeOfString:@":"];
        if (colon.location == NSNotFound) return NO;
        NSString *name = [[line substringToIndex:colon.location] lowercaseString];
        NSString *value = [[line substringFromIndex:colon.location + 1]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if ([name isEqualToString:@"transfer-encoding"]) {
            if (transferEncoding) return NO;
            transferEncoding = value.lowercaseString;
        } else if ([name isEqualToString:@"content-length"]) {
            if (contentLength) return NO;
            contentLength = value;
        } else if ([name isEqualToString:@"expect"]) {
            expectContinue = [value.lowercaseString isEqualToString:@"100-continue"];
        }
    }
    if (transferEncoding) {
        if (contentLength || ![transferEncoding isEqualToString:@"chunked"]) return NO;
        _chunked = YES;
    } else if (contentLength) {
        const char *str = contentLength.UTF8String;
        if (!str || !*str || *str == '-' || *str == '+') return NO;
        char *end = NULL;
        errno = 0;
        unsigned long long value = strtoull(str, &end, 10);
        if (errno || !end || *end) return NO;
        _hasContentLength = YES;
        _contentRemaining = value;
    }
    if (expectContinue) {
        static const char response[] = "HTTP/1.1 100 Continue\r\n\r\n";
        if (send(_clientFD, response, sizeof(response) - 1, 0) != sizeof(response) - 1) return NO;
    }
    _headersComplete = YES;
    self.connected = YES;
    VCMJPEGPushConnectionHandler handler = self.connectionHandler;
    if (handler) handler(YES);
    return YES;
}

- (BOOL)consumeBody:(const uint8_t *)bytes length:(size_t)length {
    if (_chunked) {
        BOOL valid = VCChunkDecoderConsume(&_chunkDecoder, bytes, length,
                                            VCMJPEGPushConsumeChunk, (__bridge void *)self);
        if (!valid) return NO;
        if (_chunkDecoder.state == VCChunkDone) [self finishClient];
        return YES;
    }
    if (_hasContentLength && length > _contentRemaining) return NO;
    if (length) VCMJPEGPushConsumeChunk(bytes, length, (__bridge void *)self);
    if (_hasContentLength) {
        _contentRemaining -= length;
        if (!_contentRemaining) [self finishClient];
    }
    return YES;
}

- (void)readClient:(int)clientFD {
    uint8_t buffer[65536];
    size_t processed = 0;
    while (_clientFD == clientFD && processed < 512 * 1024) {
        ssize_t count = recv(clientFD, buffer, sizeof(buffer), 0);
        if (count < 0) {
            if (errno == EINTR) continue;
            if (errno != EAGAIN && errno != EWOULDBLOCK) [self closeClient];
            return;
        }
        if (count == 0) { [self closeClient]; return; }
        _lastReadTime = CFAbsoluteTimeGetCurrent();
        processed += (size_t)count;
        if (_headersComplete) {
            if (![self consumeBody:buffer length:(size_t)count]) [self rejectClient];
            continue;
        }
        [_headerData appendBytes:buffer length:(NSUInteger)count];
        static NSData *separator;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ separator = [@"\r\n\r\n" dataUsingEncoding:NSASCIIStringEncoding]; });
        NSRange end = [_headerData rangeOfData:separator options:0 range:NSMakeRange(0, _headerData.length)];
        if (end.location == NSNotFound) {
            if (_headerData.length > VCMaximumHTTPHeaderBytes) [self rejectClient];
            continue;
        }
        if (end.location > VCMaximumHTTPHeaderBytes ||
            ![self parseHeaders:[_headerData subdataWithRange:NSMakeRange(0, end.location)]]) {
            [self rejectClient];
            return;
        }
        NSUInteger bodyOffset = NSMaxRange(end);
        NSData *body = [_headerData subdataWithRange:NSMakeRange(bodyOffset, _headerData.length - bodyOffset)];
        _headerData = nil;
        if (![self consumeBody:body.bytes length:body.length]) [self rejectClient];
    }
}

@end
