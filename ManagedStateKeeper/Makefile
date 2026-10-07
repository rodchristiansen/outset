#!/usr/bin/make -f
#
# Managed State Keeper build
# Builds the app bundle, with its helper and LaunchDaemon plist inside, at
# build/pkg-root/Applications/Utilities. There is no separate package: the
# release puts the bundle into the outset package (Package/buildReleasePackage.zsh).
# With SIGNING_IDENTITY_APP set it signs the bundle; without it the bundle is
# left unsigned, as the public release does. An unsigned helper refuses every
# client by design.
#

-include .env
export

# One build stamp, YYYY.MM.DD.HHMM, split for the About box as 2026.10.06 (1342).
VERSION := $(or $(VERSION),$(shell date '+%Y.%m.%d.%H%M'))
MARKETING_VERSION := $(shell echo $(VERSION) | sed 's/\.[^.]*$$//')
BUILD_NUMBER := $(shell echo $(VERSION) | sed 's/.*\.//')

BUILD_DIR = build
PKG_ROOT = $(BUILD_DIR)/pkg-root
APP_BUNDLE_PATH = Applications/Utilities/Managed State Keeper.app
APP_CONTENTS = $(PKG_ROOT)/$(APP_BUNDLE_PATH)/Contents
GUI_BINARY_NAME = ManagedStateKeeper
HELPER_BINARY_NAME = ManagedStateKeeperHelper
HELPER_LABEL = io.macadmins.Outset.helper
APP_IDENTIFIER = io.macadmins.Outset.gui

# The output path differs between toolchains, so ask SwiftPM for it.
SWIFT_BUILD_DIR = $(shell swift build -c release --arch arm64 --arch x86_64 --show-bin-path)
ICON_SOURCE = ../Outset/Assets.xcassets/AppIcon.appiconset
ICONSET = $(BUILD_DIR)/ManagedStateKeeper.iconset

.PHONY: all build test app verify clean

all: app

# Record the SDK the binaries are linked against. Some toolchains write the
# deployment target as the SDK version, and AppKit then keeps the pre-macOS 26
# window chrome (a title bar plus a small tab strip) instead of the toolbar tabs.
# The version is stamped after linking with vtool, because linker flags passed
# through a universal SwiftPM build reach clang without -Xlinker on some Xcodes.
SDK_VERSION := $(shell xcrun --show-sdk-version)
DEPLOYMENT_TARGET = 14.0

build:
	swift build -c release --arch arm64 --arch x86_64

test:
	swift test

app: build
	@rm -rf "$(PKG_ROOT)" "$(ICONSET)"
	@mkdir -p "$(APP_CONTENTS)/MacOS" "$(APP_CONTENTS)/Resources" "$(APP_CONTENTS)/Library/LaunchDaemons" "$(ICONSET)"
	@cp "$(SWIFT_BUILD_DIR)/ManagedStateKeeperApp" "$(APP_CONTENTS)/MacOS/$(GUI_BINARY_NAME)"
	@cp "$(SWIFT_BUILD_DIR)/ManagedStateKeeperHelper" "$(APP_CONTENTS)/MacOS/$(HELPER_BINARY_NAME)"
	@chmod 755 "$(APP_CONTENTS)/MacOS/"*
	@for bin in "$(APP_CONTENTS)/MacOS/"*; do \
		vtool -set-build-version macos $(DEPLOYMENT_TARGET) $(SDK_VERSION) -replace -output "$$bin.stamped" "$$bin" && \
		mv "$$bin.stamped" "$$bin" && codesign --force --sign - "$$bin" 2>/dev/null; \
	done
	@sed -e 's/{{MARKETING_VERSION}}/$(MARKETING_VERSION)/g' \
	     -e 's/{{BUILD_NUMBER}}/$(BUILD_NUMBER)/g' \
	     packaging/resources/Info.plist.template > "$(APP_CONTENTS)/Info.plist"
	@cp packaging/LaunchDaemons/$(HELPER_LABEL).plist "$(APP_CONTENTS)/Library/LaunchDaemons/"
	@for png in "$(ICON_SOURCE)"/Outset.png_*.png; do \
		name=$$(basename "$$png"); cp "$$png" "$(ICONSET)/icon_$${name#Outset.png_}"; \
	done
	@iconutil -c icns "$(ICONSET)" -o "$(APP_CONTENTS)/Resources/ManagedStateKeeper.icns"
ifneq ($(SIGNING_IDENTITY_APP),)
	@codesign --force --sign "$(SIGNING_IDENTITY_APP)" --options runtime --timestamp \
		--identifier $(HELPER_LABEL) "$(APP_CONTENTS)/MacOS/$(HELPER_BINARY_NAME)"
	@codesign --force --sign "$(SIGNING_IDENTITY_APP)" --options runtime --timestamp \
		--identifier $(APP_IDENTIFIER) "$(PKG_ROOT)/$(APP_BUNDLE_PATH)"
	@echo "Signed app bundle"
else
	@echo "SIGNING_IDENTITY_APP not set: app bundle left unsigned"
endif

verify:
	@codesign --verify --strict --verbose=2 "$(PKG_ROOT)/$(APP_BUNDLE_PATH)"
	@codesign -dr - "$(APP_CONTENTS)/MacOS/$(HELPER_BINARY_NAME)"

clean:
	@rm -rf $(BUILD_DIR) .build
