#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(uint8_t, VCFrameConversionFailure) {
    VCFrameConversionFailureNone = 0,
    VCFrameConversionFailureTemplate = 1,
    VCFrameConversionFailurePoolLimit = 2,
    VCFrameConversionFailurePoolAllocation = 3,
    VCFrameConversionFailureTransfer = 4,
    VCFrameConversionFailureFormatDescription = 5,
    VCFrameConversionFailureSampleBuffer = 6,
};

FOUNDATION_EXPORT VCFrameConversionFailure VCFrameConversionLastFailure(void);

FOUNDATION_EXPORT CVPixelBufferRef _Nullable VCCopyPixelBufferMatchingTemplate(
    CVPixelBufferRef source,
    CVPixelBufferRef templateBuffer,
    BOOL aspectFill) CF_RETURNS_RETAINED;

/// Creates a process-local pixel copy whose storage no longer depends on a
/// cross-process IOSurface lease. Intended for asynchronous consumers such as
/// AVCapturePhoto snapshots.
FOUNDATION_EXPORT CVPixelBufferRef _Nullable VCCopyStablePixelBuffer(
    CVPixelBufferRef source) CF_RETURNS_RETAINED;

FOUNDATION_EXPORT CVPixelBufferRef _Nullable VCCopyPixelBufferApplyingOrientation(
    CVPixelBufferRef source,
    NSInteger clockwiseRotation,
    BOOL mirrorHorizontally) CF_RETURNS_RETAINED;

/// Reuses one 180-degree copy while a shared source frame fans out to camera nodes.
FOUNDATION_EXPORT CVPixelBufferRef _Nullable VCCopyFrontCameraPixelBuffer(
    CVPixelBufferRef source) CF_RETURNS_RETAINED;

FOUNDATION_EXPORT CVPixelBufferRef _Nullable VCCopyDisplayPixelBuffer(
    CVPixelBufferRef source) CF_RETURNS_RETAINED;

FOUNDATION_EXPORT CMSampleBufferRef _Nullable VCCopyReplacementSampleBuffer(
    CMSampleBufferRef original,
    CVPixelBufferRef source,
    BOOL aspectFill,
    NSInteger preferredFPS) CF_RETURNS_RETAINED;

FOUNDATION_EXPORT BOOL VCIsSupportedReplacementPixelFormat(OSType pixelFormat);
FOUNDATION_EXPORT void VCResetFrameConverterCache(void);
FOUNDATION_EXPORT void VCFlushFrameConverterCaches(BOOL releasePoolsAndSession);

NS_ASSUME_NONNULL_END
