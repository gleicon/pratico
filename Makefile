CONFIG       ?= release
INSTALL_DIR  ?= /Applications
BUILD_DIR    := .build
BIN_DIR       = $(shell swift build -c $(CONFIG) --show-bin-path)
DIST_DIR     := dist
APP          := $(DIST_DIR)/Pratico.app
ENTITLEMENTS := Support/pratico.entitlements
# Ad-hoc by default (SPEC D-10). Set to a Developer ID identity to sign for distribution.
SIGN_IDENTITY ?= -

.PHONY: all build test e2e e2e-registry app sign install uninstall clean

all: build

build:
	swift build -c $(CONFIG)

test:
	swift test

e2e: build
	e2e/run.sh "$(BIN_DIR)"

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

# Locally built bundles carry no quarantine flag, so Gatekeeper does not prompt (SPEC D-10).
install: app
	rm -rf "$(INSTALL_DIR)/Pratico.app"
	cp -R "$(APP)" "$(INSTALL_DIR)/"

uninstall:
	rm -rf "$(INSTALL_DIR)/Pratico.app"

clean:
	rm -rf "$(BUILD_DIR)" "$(DIST_DIR)"
