#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^VCMJPEGPushDataHandler)(NSData *data);
typedef void (^VCMJPEGPushConnectionHandler)(BOOL connected);

@interface VCMJPEGPushServer : NSObject
@property (atomic, readonly, getter=isConnected) BOOL connected;
@property (atomic, copy, nullable) VCMJPEGPushDataHandler dataHandler;
@property (atomic, copy, nullable) VCMJPEGPushConnectionHandler connectionHandler;
- (instancetype)initWithPort:(uint16_t)port path:(NSString *)path;
- (BOOL)startWithError:(NSError * _Nullable * _Nullable)error;
- (void)stop;
@end

NS_ASSUME_NONNULL_END
