# MicroCommander – build jádra (Rust) a aplikace (Swift/AppKit) pro macOS.
#
#   make            – sestaví jádro (release) i aplikaci (.app bundle)
#   make run        – sestaví a spustí aplikaci
#   make test       – unit testy jádra
#   make smoke      – end-to-end test FFI vrstvy (Swift ↔ Rust)
#   make selftest   – self-test UI (klávesy, dialogy, F5/F8) nad spuštěnou aplikací
#   make keycheck   – kontrola Home/End ve všech režimech bez zobrazení okna
#   make sftp-test  – SFTP přihlášení klíčem/agentem proti dočasnému lokálnímu sshd
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

.PHONY: all app release test smoke selftest keycheck sftp-test clean run

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
	# Metadata bundle.
	cp $(APP)/Info.plist $(APPDIR)/Contents/Info.plist
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

# Sestaví a spustí aplikaci.
run: app
	open $(APPDIR)

clean:
	rm -rf $(BUILD)
