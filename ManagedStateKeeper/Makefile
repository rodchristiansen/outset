#!/usr/bin/make -f
#
# Managed State Keeper build
# Builds the app bundle and an installer package. With SIGNING_IDENTITY_APP and
# SIGNING_IDENTITY_PKG set it signs both; without them it builds unsigned, as the
# public release does. An unsigned helper refuses every client by design.
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

PKG_ID = io.macadmins.Outset.gui
PKG_OUTPUT = $(BUILD_DIR)/ManagedStateKeeper-$(VERSION).pkg

.PHONY: all build test app pkg clean

all: pkg

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

pkg: app
	@pkgbuild --analyze --root "$(PKG_ROOT)" "$(BUILD_DIR)/component.plist"
	@/usr/libexec/PlistBuddy -c "Set :0:BundleIsRelocatable false" "$(BUILD_DIR)/component.plist" 2>/dev/null \
		|| /usr/libexec/PlistBuddy -c "Add :0:BundleIsRelocatable bool false" "$(BUILD_DIR)/component.plist"
	@/usr/libexec/PlistBuddy -c "Set :0:BundleIsVersionChecked false" "$(BUILD_DIR)/component.plist"
	@pkgbuild --root "$(PKG_ROOT)" --component-plist "$(BUILD_DIR)/component.plist" \
		--identifier $(PKG_ID) --version $(VERSION) --scripts packaging/scripts \
		"$(BUILD_DIR)/component.pkg"
ifneq ($(SIGNING_IDENTITY_PKG),)
	@productbuild --package "$(BUILD_DIR)/component.pkg" --identifier $(PKG_ID) --version $(VERSION) \
		--sign "$(SIGNING_IDENTITY_PKG)" --timestamp "$(PKG_OUTPUT)"
else
	@productbuild --package "$(BUILD_DIR)/component.pkg" --identifier $(PKG_ID) --version $(VERSION) "$(PKG_OUTPUT)"
endif
	@rm -f "$(BUILD_DIR)/component.pkg"
	@echo "Built $(PKG_OUTPUT)"

clean:
	@rm -rf $(BUILD_DIR) .build
