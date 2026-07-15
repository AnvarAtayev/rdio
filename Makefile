.PHONY: build app run selftest clean

BINARY := .build/release/Rdio
# The shipped .app is a universal binary so one download (and one Sparkle feed item) serves both Apple Silicon and Intel.
ARCHS := --arch arm64 --arch x86_64
GIT_VERSION := $(shell git describe --tags --always 2>/dev/null | sed 's/^v//')
VERSION ?= $(or $(GIT_VERSION),0.0.0)

build:
	swift build -c release

app:
	swift build -c release $(ARCHS)
	rm -rf Rdio.app
	mkdir -p Rdio.app/Contents/MacOS Rdio.app/Contents/Resources Rdio.app/Contents/Frameworks
	cp packaging/Info.plist Rdio.app/Contents/Info.plist
	cp packaging/AppIcon.icns Rdio.app/Contents/Resources/AppIcon.icns
	cp "$$(swift build -c release $(ARCHS) --show-bin-path)/Rdio" Rdio.app/Contents/MacOS/Rdio
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" Rdio.app/Contents/Info.plist
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(VERSION)" Rdio.app/Contents/Info.plist
	# Embed Sparkle: point the executable at Contents/Frameworks, copy the
	# (universal) framework in, then ad-hoc sign inside-out so the seal is valid.
	install_name_tool -add_rpath @executable_path/../Frameworks Rdio.app/Contents/MacOS/Rdio
	FW=$$(find .build/artifacts -type d -path '*Sparkle.xcframework/macos-*/Sparkle.framework' | head -1); \
	  cp -R "$$FW" Rdio.app/Contents/Frameworks/Sparkle.framework
	codesign --force --sign - --preserve-metadata=entitlements,flags,runtime \
	  Rdio.app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc
	codesign --force --sign - --preserve-metadata=entitlements,flags,runtime \
	  Rdio.app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc
	codesign --force --sign - --preserve-metadata=entitlements,flags,runtime \
	  Rdio.app/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app
	codesign --force --sign - --preserve-metadata=entitlements,flags,runtime \
	  Rdio.app/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate
	codesign --force --sign - Rdio.app/Contents/Frameworks/Sparkle.framework
	codesign --force --sign - Rdio.app
	@echo "Rdio.app ready (universal, v$(VERSION)) — open it or move it to /Applications"

run: build
	$(BINARY)

selftest: build
	$(BINARY) --selftest

clean:
	rm -rf .build Rdio.app
