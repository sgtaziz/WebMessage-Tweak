ARCHS = arm64 arm64e

TARGET := iphone:clang:latest:13.0

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = WebMessage

WebMessage_FILES = saWebMessageRootListController.m
WebMessage_FRAMEWORKS = UIKit
WebMessage_PRIVATE_FRAMEWORKS = Preferences
WebMessage_INSTALL_PATH = /Library/PreferenceBundles
WebMessage_CFLAGS = -fobjc-arc
WebMessage_LIBRARIES = mryipc

include $(THEOS_MAKE_PATH)/bundle.mk
