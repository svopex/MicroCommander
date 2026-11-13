# MicroCommander – build jádra (Rust) a aplikace (Swift/AppKit) pro macOS.
#
#   make            – sestaví jádro (release) i aplikaci (.app bundle)
#   make run        – sestaví a spustí aplikaci
#   make test       – unit testy jádra
#   make smoke      – end-to-end test FFI vrstvy (Swift ↔ Rust)
#   make selftest   – self-test UI (klávesy, dialogy, F5/F8) nad spuštěnou aplikací
#   make keycheck   – kontrola Home/End ve všech režimech bez zobrazení okna
#   make sftp-test  – SFTP přihlášení klíčem/agentem proti dočasnému lokálnímu sshd
#   make icon       – vykreslí ikonu (tools/make-icon.swift) do app/AppIcon.icns
#   make clean      – smaže build adresář

RUST ?= $(HOME)/.cargo/bin
export PATH := $(RUST):$(PATH)

ROOT := $(patsubst %/,%, $(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
CORE := $(ROOT)/core
APP := $(ROOT)/app
BUILD := $(ROOT)/build
APPDIR := $(BUILD)/MicroCommander.app
BIN := $(APPDIR)/Contents/MacOS/MicroCommander
DYLIB := $(CORE)/target/release/libsalcore.dylib
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

.PHONY: all app release test smoke selftest keycheck sftp-test icon clean run

all: app

# Jádro: release build Rust knihovny (cdylib).
release:
	cd $(CORE) && cargo build --release

# Unit testy jádra.
test:
	cd $(CORE) && cargo test

# End-to-end smoke test FFI vrstvy (Swift CLI binárka nad stejnou knihovnou).
# Soubor se jmenuje main.swift, protože obsahuje top-level kód.
smoke:
	swiftc -O -I $(CORE)/include -L $(CORE)/target/release -lsalcore \
		-Xlinker -rpath -Xlinker $(CORE)/target/release \
		$(ROOT)/tests/main.swift $(APP)/Sources/Core.swift -o $(BUILD)/ffi-smoke
	$(BUILD)/ffi-smoke

# .app bundle: vždy celá sekvence (install name → kopie dylib → swiftc → plist).
# cargo i make jsou no-op při nezměněných vstupech, celý krok je rychlý.
app: release
	@mkdir -p $(APPDIR)/Contents/MacOS $(APPDIR)/Contents/Frameworks
	# Install name knihovny přepneme na relativní rpath, aby bundle byl přenositelný.
	install_name_tool -id @rpath/libsalcore.dylib $(DYLIB)
	cp $(DYLIB) $(APPDIR)/Contents/Frameworks/
	# Kompilace Swift UI; jádro se linkuje z target/release, runtime přes rpath.
	swiftc -O \
		-I $(CORE)/include \
		-L $(CORE)/target/release \
		-lsalcore \
		-Xlinker -rpath -Xlinker @executable_path/../Frameworks \
		-framework AppKit \
		$(APP)/Sources/*.swift \
		-o $(BIN)
	# Metadata bundle a ikona.
	cp $(APP)/Info.plist $(APPDIR)/Contents/Info.plist
	@mkdir -p $(APPDIR)/Contents/Resources
	cp $(APP)/AppIcon.icns $(APPDIR)/Contents/Resources/AppIcon.icns
	# Finder a Dock drží ikonu v mezipaměti LaunchServices – změna času balíčku
	# a nová registrace ji obnoví (jinak by zůstala stará / prázdná ikona).
	touch $(APPDIR)
	-$(LSREGISTER) -f $(APPDIR)
	@echo "Hotovo: $(APPDIR)"

# Self-test UI: aplikace si sama posílá klávesové události a ověřuje výsledek.
selftest: app
	SAL_SELFTEST=1 $(BIN)

# Kontrola Home/End/⌥↑/⌥↓ ve všech režimech zobrazení – bez okna a bez krádeže fokusu.
keycheck: app
	SAL_KEYCHECK=1 $(BIN)

# SFTP end-to-end: dočasný sshd na 127.0.0.1 (pod uživatelem), testovací klíče, ssh-agent.
sftp-test:
	$(ROOT)/tests/sftp_test.sh

# Ikona aplikace: PNG 1024 ze skriptu → sada velikostí (sips) → .icns (iconutil).
# Výsledek app/AppIcon.icns je v repozitáři, běžné sestavení skript nespouští.
ICONSET := $(BUILD)/AppIcon.iconset
icon:
	@mkdir -p $(ICONSET)
	swift $(ROOT)/tools/make-icon.swift $(BUILD)/icon-1024.png
	for size in 16 32 128 256 512; do \
		sips -z $$size $$size $(BUILD)/icon-1024.png --out $(ICONSET)/icon_$${size}x$${size}.png >/dev/null; \
		sips -z $$((size * 2)) $$((size * 2)) $(BUILD)/icon-1024.png --out $(ICONSET)/icon_$${size}x$${size}@2x.png >/dev/null; \
	done
	iconutil -c icns $(ICONSET) -o $(APP)/AppIcon.icns
	@echo "Ikona: $(APP)/AppIcon.icns"

# Sestaví a spustí aplikaci.
run: app
	open $(APPDIR)

clean:
	rm -rf $(BUILD)
