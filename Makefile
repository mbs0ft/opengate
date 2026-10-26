TARGET := iphone:clang:latest:12.0
ARCHS := arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = OpenGate

OpenGate_FILES = Tweak.xm VKOpenVK.xm Managers/OpenGateAPIManager.xm Controllers/InstanceSelectionViewController.xm
OpenGate_CFLAGS = -fobjc-arc
OpenGate_FRAMEWORKS = UIKit Foundation
OpenGate_LDFLAGS = -Wl,-multiply_defined,suppress

include $(THEOS_MAKE_PATH)/tweak.mk