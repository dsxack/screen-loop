SHELL := /bin/bash

SWIFT ?= swift
CONFIGURATION ?= release
CLANG_MODULE_CACHE_PATH ?= $(CURDIR)/.build/module-cache

APP_NAME := Screen Recorder
APP_BUNDLE := .build/app/$(APP_NAME).app

.PHONY: all help build test app run clean

all: build

help:
	@printf "Targets:\n"
	@printf "  build  Build Swift package\n"
	@printf "  test   Run Swift tests\n"
	@printf "  app    Build macOS app bundle (%s)\n" "$(APP_BUNDLE)"
	@printf "  run    Build and open app bundle\n"
	@printf "  clean  Remove SwiftPM build artifacts\n"

build:
	CLANG_MODULE_CACHE_PATH="$(CLANG_MODULE_CACHE_PATH)" $(SWIFT) build

test:
	CLANG_MODULE_CACHE_PATH="$(CLANG_MODULE_CACHE_PATH)" $(SWIFT) test

app:
	CLANG_MODULE_CACHE_PATH="$(CLANG_MODULE_CACHE_PATH)" CONFIGURATION="$(CONFIGURATION)" bash scripts/build-app.sh

run: app
	open "$(APP_BUNDLE)"

clean:
	$(SWIFT) package clean
	rm -rf .build/app
