export THEOS_PACKAGE_SCHEME = rootless
export TARGET = iphone:clang:16.5:15.0
ARCHS ?= arm64 arm64e
export ARCHS

ifeq ($(VC_ARM64E_FIXUPS),1)
export TARGET_CC := $(abspath scripts/clang_with_block_pac.py)
endif

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AVFCameraSupport VCMediaServer

VC_SHARED_FILES = src/AVAssetStreamAdapter.m src/VCMJPEGPushServer.m src/VCPreferences.m src/VCStreamCoordinator.m src/VCFrameConverter.m \
	src/VCSharedMediaBus.m src/VCAudioSampleConverter.m src/VCScreenCaptureSource.m src/VCLocalMediaSource.m

AVFCameraSupport_FILES = src/Tweak.x $(VC_SHARED_FILES)
AVFCameraSupport_CFLAGS = -I$(THEOS_PROJECT_DIR)/src -fobjc-arc -O2 -Wall -Wextra -Wno-unused-parameter -Wno-deprecated-declarations
AVFCameraSupport_FRAMEWORKS = UIKit AVFoundation AudioToolbox CoreImage CoreMedia CoreVideo QuartzCore CoreGraphics Foundation ImageIO IOSurface VideoToolbox
AVFCameraSupport_LDFLAGS = -Wl,-dead_strip
AVFCameraSupport_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

VCMediaServer_FILES = src/MediaServer.x $(VC_SHARED_FILES)
VCMediaServer_CFLAGS = -I$(THEOS_PROJECT_DIR)/src -fobjc-arc -O2 -Wall -Wextra -Wno-unused-parameter -Wno-deprecated-declarations
VCMediaServer_FRAMEWORKS = AVFoundation AudioToolbox CoreImage CoreMedia CoreVideo QuartzCore CoreGraphics Foundation ImageIO IOSurface VideoToolbox
VCMediaServer_LDFLAGS = -Wl,-dead_strip
VCMediaServer_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

INSTALL_TARGET_PROCESSES = SpringBoard Camera mediaserverd

before-package:: $(THEOS_STAGING_DIR)/DEBIAN/control
	chmod 0755 "$(THEOS_STAGING_DIR)/DEBIAN/postinst" "$(THEOS_STAGING_DIR)/DEBIAN/postrm"
	install -d "$(THEOS_STAGING_DIR)/usr/bin"
	install -m 0755 "$(THEOS_PROJECT_DIR)/setup-config.sh" \
		"$(THEOS_STAGING_DIR)/usr/bin/virtualcampro-config"
ifeq ($(VC_ARM64E_FIXUPS),1)
	@set -e; for binary in \
		"$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/AVFCameraSupport.dylib" \
		"$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/VCMediaServer.dylib" \
		"$(THEOS_STAGING_DIR)/Library/PreferenceBundles/VirtualCamPro.bundle/VirtualCamPro"; do \
		python3 "$(THEOS_PROJECT_DIR)/scripts/patch_arm64e.py" "$$binary"; \
		CODESIGN_ALLOCATE="$(TARGET_CODESIGN_ALLOCATE)" $(TARGET_CODESIGN) $(TARGET_CODESIGN_FLAGS) "$$binary"; \
	done
endif

SUBPROJECTS += prefs

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/aggregate.mk
