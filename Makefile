SHELL := /bin/bash

SWIFT ?= swift
CONFIGURATION ?= release
CLANG_MODULE_CACHE_PATH ?= $(CURDIR)/.build/module-cache
PACKAGE_ARCHS ?= arm64 x86_64
REQUIRE_UNIVERSAL_PACKAGE ?= 0

empty :=
space := $(empty) $(empty)

APP_NAME := Screen Loop
APP_BUNDLE := .build/app/$(APP_NAME).app
APP_BUNDLE_TARGET := $(subst $(space),\$(space),$(APP_BUNDLE))
INFO_PLIST := AppBundle/Info.plist

SOURCE_FILES := $(shell find Sources -type f -name '*.swift' 2>/dev/null)
TEST_FILES := $(shell find Tests -type f -name '*.swift' 2>/dev/null)

VERSION := $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$(INFO_PLIST)" 2>/dev/null)
HOST_ARCH := $(shell uname -m)
XCBUILD_STATUS := $(shell if xcrun -find xcbuild >/dev/null 2>&1 || test -x /Library/Developer/SharedFrameworks/XCBuild.framework/Versions/A/Support/xcbuild; then echo universal-capable; else echo native-only; fi)
REQUESTED_PACKAGE_ARCHS := $(strip $(PACKAGE_ARCHS))
PACKAGE_ACTIVE_ARCHS := $(REQUESTED_PACKAGE_ARCHS)

ifeq ($(REQUESTED_PACKAGE_ARCHS),native)
PACKAGE_ACTIVE_ARCHS := $(HOST_ARCH)
endif
ifeq ($(REQUESTED_PACKAGE_ARCHS),$(HOST_ARCH))
PACKAGE_ACTIVE_ARCHS := $(HOST_ARCH)
endif
ifneq ($(findstring $(space),$(REQUESTED_PACKAGE_ARCHS)),)
ifneq ($(XCBUILD_STATUS),universal-capable)
ifeq ($(REQUIRE_UNIVERSAL_PACKAGE),0)
PACKAGE_ACTIVE_ARCHS := $(HOST_ARCH)
endif
endif
endif

PACKAGE_ARCHIVE_LABEL := $(if $(findstring $(space),$(PACKAGE_ACTIVE_ARCHS)),macos-universal,macos-$(PACKAGE_ACTIVE_ARCHS))

BUILD_PRODUCT := .build/$(CONFIGURATION)/ScreenRecorderApp
PACKAGE_ZIP := dist/ScreenLoop-$(VERSION)-$(PACKAGE_ARCHIVE_LABEL).zip
PACKAGE_SHA256 := $(PACKAGE_ZIP).sha256
README_DEMO_GIF := docs/screen-loop-demo.gif
DEMO_FRAME_DIR ?=

BUILD_INPUTS := Package.swift $(SOURCE_FILES)
TEST_INPUTS := Package.swift $(SOURCE_FILES) $(TEST_FILES)
APP_INPUTS := Package.swift $(INFO_PLIST) scripts/build-app.sh $(SOURCE_FILES)
PACKAGE_INPUTS := $(APP_INPUTS) scripts/package-release.sh

.PHONY: all help build test app package demo-gif run clean

all: build

help:
	@printf "Targets:\n"
	@printf "  build  Build Swift package\n"
	@printf "  test   Run Swift tests\n"
	@printf "  app    Build macOS app bundle (%s)\n" "$(APP_BUNDLE)"
	@printf "  package Build release zip in dist/\n"
	@printf "  demo-gif Generate README demo GIF from the live app (%s)\n" "$(README_DEMO_GIF)"
	@printf "  run    Build and open app bundle\n"
	@printf "  clean  Remove SwiftPM build artifacts\n"

build: $(BUILD_PRODUCT)

$(BUILD_PRODUCT): $(BUILD_INPUTS)
	@mkdir -p "$(dir $@)"
	CLANG_MODULE_CACHE_PATH="$(CLANG_MODULE_CACHE_PATH)" $(SWIFT) build -c "$(CONFIGURATION)"

test: $(BUILD_PRODUCT) $(TEST_INPUTS)
	CLANG_MODULE_CACHE_PATH="$(CLANG_MODULE_CACHE_PATH)" $(SWIFT) test -c "$(CONFIGURATION)"

app: $(APP_BUNDLE_TARGET)
	@printf "%s\n" "$(APP_BUNDLE)"

$(APP_BUNDLE_TARGET): $(APP_INPUTS)
	CLANG_MODULE_CACHE_PATH="$(CLANG_MODULE_CACHE_PATH)" CONFIGURATION="$(CONFIGURATION)" ARCHS="$(ARCHS)" bash scripts/build-app.sh

package: $(PACKAGE_ZIP) $(PACKAGE_SHA256)
	@find dist -maxdepth 1 \( -name '*.zip' -o -name '*.sha256' \) -print | sort

$(PACKAGE_ZIP): $(PACKAGE_INPUTS)
	CLANG_MODULE_CACHE_PATH="$(CLANG_MODULE_CACHE_PATH)" CONFIGURATION="$(CONFIGURATION)" PACKAGE_ARCHS="$(PACKAGE_ARCHS)" REQUIRE_UNIVERSAL_PACKAGE="$(REQUIRE_UNIVERSAL_PACKAGE)" bash scripts/package-release.sh

$(PACKAGE_SHA256): $(PACKAGE_ZIP)
	@test -f "$@" || shasum -a 256 "$<" > "$@"

demo-gif: scripts/render-readme-demo.swift
	@mkdir -p "$(dir $(README_DEMO_GIF))"
	@if [ -n "$(DEMO_FRAME_DIR)" ]; then \
		$(SWIFT) "scripts/render-readme-demo.swift" "$(README_DEMO_GIF)" "$(DEMO_FRAME_DIR)"; \
	else \
		$(SWIFT) "scripts/render-readme-demo.swift" "$(README_DEMO_GIF)"; \
	fi

run: app
	open "$(APP_BUNDLE)"

clean:
	$(SWIFT) package clean
	rm -rf .build/app
	rm -rf dist
