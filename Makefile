CONFIG       ?= release
INSTALL_DIR  ?= /Applications
BUILD_DIR    := .build
BIN_DIR       = $(shell swift build -c $(CONFIG) --show-bin-path)
DIST_DIR     := dist
APP          := $(DIST_DIR)/Pratico.app
ENTITLEMENTS := Support/pratico.entitlements
# Ad-hoc by default (SPEC D-10). Set to a Developer ID identity to sign for distribution.
SIGN_IDENTITY ?= -
VERSION      ?= $(shell sed -n 's/.*static let version = "\(.*\)"/\1/p' Sources/PraticoCore/Pratico.swift)
DMG          := $(DIST_DIR)/Pratico-$(VERSION).dmg

ASSETS_DIR   := $(BUILD_DIR)/runtime-assets

.PHONY: all build assets probe test e2e e2e-embedded e2e-registry app sign dmg release install run uninstall clean

all: build

# The shim runs VMs, so every build re-signs it with the virtualization entitlement.
build:
	swift build -c $(CONFIG)
	codesign --force --sign - --entitlements "$(ENTITLEMENTS)" "$(BIN_DIR)/pratico-shim"

# Kernel + vminit for the embedded runtime, pinned and verified (docs/design/runtime.md).
assets:
	scripts/fetch-runtime-assets.sh "$(ASSETS_DIR)"

# Boots one container on the embedded runtime: make probe ARGS="alpine echo hi"
probe: build assets
	codesign --force --sign - --entitlements "$(ENTITLEMENTS)" "$(BIN_DIR)/pratico-runtime-probe"
	PRATICO_RUNTIME_ASSETS="$(ASSETS_DIR)" "$(BIN_DIR)/pratico-runtime-probe" $(ARGS)

test:
	swift test

e2e: build
	e2e/run.sh "$(BIN_DIR)"

# The embedded runtime, with Apple's `container` CLI replaced by a fake that must stay unused.
e2e-embedded: build assets
	e2e/embedded.sh "$(BIN_DIR)"

# Test harness only: spins up a throwaway private registry to check docker login + pull.
e2e-registry: build
	e2e/registry.sh "$(BIN_DIR)"

app: build
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Library/LaunchAgents"
	cp Support/Info.plist "$(APP)/Contents/Info.plist"
	cp Support/dev.pratico.daemon.plist "$(APP)/Contents/Library/LaunchAgents/"
	cp "$(BIN_DIR)/pratico-menubar" "$(BIN_DIR)/pratico-daemon" "$(APP)/Contents/MacOS/"
	$(MAKE) sign

sign:
	codesign --force --sign "$(SIGN_IDENTITY)" --entitlements "$(ENTITLEMENTS)" --options runtime \
		"$(APP)/Contents/MacOS/pratico-daemon"
	codesign --force --sign "$(SIGN_IDENTITY)" --entitlements "$(ENTITLEMENTS)" --options runtime "$(APP)"

# Drag-to-Applications image with the Gatekeeper walkthrough (SPEC D-10).
dmg: app
	rm -rf "$(DIST_DIR)/dmg" "$(DMG)"
	mkdir -p "$(DIST_DIR)/dmg"
	cp -R "$(APP)" "$(DIST_DIR)/dmg/"
	ln -s /Applications "$(DIST_DIR)/dmg/Applications"
	cp Support/dmg-README.txt "$(DIST_DIR)/dmg/READ ME FIRST.txt"
	hdiutil create -volname "Pratico $(VERSION)" -srcfolder "$(DIST_DIR)/dmg" -ov -format UDZO "$(DMG)"
	codesign --force --sign "$(SIGN_IDENTITY)" "$(DMG)"
	rm -rf "$(DIST_DIR)/dmg"

# Tags vVERSION and publishes the DMG to GitHub; see scripts/release.sh for the checks.
release:
	scripts/release.sh "$(VERSION)"

# Locally built bundles carry no quarantine flag, so Gatekeeper does not prompt (SPEC D-10).
install: app
	rm -rf "$(INSTALL_DIR)/Pratico.app"
	cp -R "$(APP)" "$(INSTALL_DIR)/"

# Installs and opens the app: its menubar item starts the daemon.
run: install
	open "$(INSTALL_DIR)/Pratico.app"

uninstall:
	rm -rf "$(INSTALL_DIR)/Pratico.app"

clean:
	rm -rf "$(BUILD_DIR)" "$(DIST_DIR)"
