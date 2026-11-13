#import <Foundation/Foundation.h>

/* The wildcard host identifies a local listener rather than a remote URL. */
static inline BOOL VCURLIsOBSPush(NSURL *url) {
    NSInteger port = url.port.integerValue;
    return [url.scheme.lowercaseString isEqualToString:@"http"] &&
        [url.host isEqualToString:@"0.0.0.0"] &&
        [url.path isEqualToString:@"/obs"] && !url.query.length &&
        port > 0 && port <= 65535;
}
