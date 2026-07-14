.PHONY: build app run selftest clean

BINARY := .build/release/Rdio

build:
	swift build -c release

app: build
	rm -rf Rdio.app
	mkdir -p Rdio.app/Contents/MacOS Rdio.app/Contents/Resources
	cp packaging/Info.plist Rdio.app/Contents/Info.plist
	cp packaging/AppIcon.icns Rdio.app/Contents/Resources/AppIcon.icns
	cp $(BINARY) Rdio.app/Contents/MacOS/Rdio
	codesign --force --sign - Rdio.app
	@echo "Rdio.app ready — open it or move it to /Applications"

run: build
	$(BINARY)

selftest: build
	$(BINARY) --selftest

clean:
	rm -rf .build Rdio.app
