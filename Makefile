.PHONY: build app run selftest clean

BINARY := .build/release/Rdio
ARCH ?= $(shell uname -m)
GIT_VERSION := $(shell git describe --tags --always 2>/dev/null | sed 's/^v//')
VERSION ?= $(or $(GIT_VERSION),0.0.0)

build:
	swift build -c release

app:
	swift build -c release --arch $(ARCH)
	rm -rf Rdio.app
	mkdir -p Rdio.app/Contents/MacOS Rdio.app/Contents/Resources
	cp packaging/Info.plist Rdio.app/Contents/Info.plist
	cp packaging/AppIcon.icns Rdio.app/Contents/Resources/AppIcon.icns
	cp "$$(swift build -c release --arch $(ARCH) --show-bin-path)/Rdio" Rdio.app/Contents/MacOS/Rdio
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" Rdio.app/Contents/Info.plist
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(VERSION)" Rdio.app/Contents/Info.plist
	codesign --force --sign - Rdio.app
	@echo "Rdio.app ready ($(ARCH), v$(VERSION)) — open it or move it to /Applications"

run: build
	$(BINARY)

selftest: build
	$(BINARY) --selftest

clean:
	rm -rf .build Rdio.app
