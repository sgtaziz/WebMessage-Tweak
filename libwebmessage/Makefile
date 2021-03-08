ARCHS = arm64 arm64e

TARGET := iphone:clang:latest:12.0
INSTALL_TARGET_PROCESSES = MobileSMS SpringBoard


include $(THEOS)/makefiles/common.mk

TWEAK_NAME = libwebmessage

libwebmessage_FILES = Tweak.x
libwebmessage_CFLAGS = -fobjc-arc
libwebmessage_LIBRARIES = mryipc

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
		install.exec "killall -9 imagent"

