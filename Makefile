ARCHS = arm64 arm64e
TARGET := iphone:clang:latest:12.0
INSTALL_TARGET_PROCESSES = VK

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = OpenGate

OpenGate_FILES = Tweak.xm VKOpenVK.xm Managers/OpenGateAPIManager.xm Controllers/InstanceSelectionViewController.xm
OpenGate_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
OpenGate_FRAMEWORKS = UIKit Foundation

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 VK || true"