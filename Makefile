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
#
# Vestavěný terminál používá knihovnu SwiftTerm (MIT). Její zdrojáky v připnuté
# verzi se při prvním sestavení stáhnou do vendor/SwiftTerm (mimo repozitář)
# a přeloží se jako statická knihovna do build adresáře.

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
# Nejstarší podporovaný macOS se čte z LSMinimumSystemVersion v app/Info.plist
# (jediné místo, kde se nastavuje). Platí pro Swift (-target) i pro C části
# jádra (OpenSSL, libssh2), které se sestavují podle MACOSX_DEPLOYMENT_TARGET.
MACOS_MIN := $(shell /usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" $(APP)/Info.plist)
SWIFT_TARGET := $(shell uname -m)-apple-macos$(MACOS_MIN)
export MACOSX_DEPLOYMENT_TARGET := $(MACOS_MIN)
# Identita pro podpis aplikace (viz CODESIGNING.md). Stálý podpis zachová
# oprávnění macOS (přístup ke Stahování, Dokumentům…) i po novém buildu;
# bez certifikátu v klíčence zůstane ad-hoc podpis linkeru.
SIGN_IDENTITY ?= MicroCommander Dev
# Další přepínače pro swiftc (např. -module-cache-path při sestavení v sandboxu).
SWIFTFLAGS ?=

# SwiftTerm – emulátor terminálu (licence MIT). Verze je připnutá tagem
# i commitem; fetch-swiftterm.sh odmítne tag, který ukazuje jinam.
SWIFTTERM_VERSION := v1.20.0
SWIFTTERM_COMMIT := 5d14406844143538cd8f8851d2d8a67c1fe443e5
SWIFTTERM_SRC := $(ROOT)/vendor/SwiftTerm
SWIFTTERM_STAMP := $(SWIFTTERM_SRC)/.fetched-$(SWIFTTERM_VERSION)
# Výstup závisí na verzi i cílové platformě – změna jedné z nich knihovnu přeloží znovu.
SWIFTTERM_OUT := $(BUILD)/swiftterm-$(SWIFTTERM_VERSION)-$(SWIFT_TARGET)
SWIFTTERM_LIB := $(SWIFTTERM_OUT)/libSwiftTerm.a

.PHONY: all app release test smoke selftest keycheck sftp-test icon clean run

all: app

# Jádro: release build Rust knihovny (cdylib).
release:
	cd $(CORE) && cargo build --release

# Zdrojáky SwiftTermu v připnuté verzi (stáhnou se jen jednou).
$(SWIFTTERM_STAMP):
	$(ROOT)/fetch-swiftterm.sh $(SWIFTTERM_VERSION) $(SWIFTTERM_COMMIT)
	@# Bez značky stažené verze se nepokračuje (knihovna by se přeložila prázdná).
	@test -f $@

# SwiftTerm jako statická knihovna + modul pro `import SwiftTerm`. Překládá se
# přímo přes swiftc (projekt nepoužívá SwiftPM); BuildInfo.swift v balíčku
# generuje build plugin SwiftPM, tady ho nahrazuje soubor s připnutou verzí.
# Shader pro Metal se nepřekládá – terminál kreslí přes CoreGraphics.
$(SWIFTTERM_LIB): $(SWIFTTERM_STAMP)
	@mkdir -p $(SWIFTTERM_OUT)
	@printf '%s\n' \
		'// Generováno Makefilem (v balíčku SwiftPM soubor vytváří build plugin).' \
		'public enum SwiftTermBuildInfo {' \
		'    public static let branch: String? = nil' \
		'    public static let tag: String? = "$(SWIFTTERM_VERSION)"' \
		'    public static let commit: String? = "$(SWIFTTERM_COMMIT)"' \
		'    public static let hasUncommittedChanges: Bool? = false' \
		'    public static let version: String = "$(SWIFTTERM_VERSION)"' \
		'}' > $(SWIFTTERM_OUT)/BuildInfo.swift
	swiftc -O -wmo -parse-as-library -swift-version 5 -suppress-warnings \
		-target $(SWIFT_TARGET) $(SWIFTFLAGS) \
		-module-name SwiftTerm \
		-emit-module -emit-module-path $(SWIFTTERM_OUT)/SwiftTerm.swiftmodule \
		-emit-library -static -o $(SWIFTTERM_LIB) \
		$$(find $(SWIFTTERM_SRC)/Sources/SwiftTerm -name '*.swift') $(SWIFTTERM_OUT)/BuildInfo.swift

# Unit testy jádra.
test:
	cd $(CORE) && cargo test

# End-to-end smoke test FFI vrstvy (Swift CLI binárka nad stejnou knihovnou).
# Soubor se jmenuje main.swift, protože obsahuje top-level kód.
# Potřebuje sestavené jádro a adresář build (i po `make clean`).
smoke: release
	@mkdir -p $(BUILD)
	swiftc -O -target $(SWIFT_TARGET) -I $(CORE)/include -L $(CORE)/target/release -lsalcore \
		-Xlinker -rpath -Xlinker $(CORE)/target/release \
		$(ROOT)/tests/main.swift $(APP)/Sources/Core.swift -o $(BUILD)/ffi-smoke
	$(BUILD)/ffi-smoke

# .app bundle: vždy celá sekvence (install name → kopie dylib → swiftc → plist).
# cargo i make jsou no-op při nezměněných vstupech, celý krok je rychlý.
app: release $(SWIFTTERM_LIB)
	@mkdir -p $(APPDIR)/Contents/MacOS $(APPDIR)/Contents/Frameworks
	# Install name knihovny přepneme na relativní rpath, aby bundle byl přenositelný.
	install_name_tool -id @rpath/libsalcore.dylib $(DYLIB)
	cp $(DYLIB) $(APPDIR)/Contents/Frameworks/
	# Kompilace Swift UI; jádro se linkuje z target/release, runtime přes rpath,
	# SwiftTerm staticky (jeho systémové frameworky se přilinkují automaticky).
	swiftc -O \
		-target $(SWIFT_TARGET) $(SWIFTFLAGS) \
		-I $(CORE)/include \
		-L $(CORE)/target/release \
		-lsalcore \
		-I $(SWIFTTERM_OUT) \
		-L $(SWIFTTERM_OUT) \
		-lSwiftTerm \
		-Xlinker -rpath -Xlinker @executable_path/../Frameworks \
		-framework AppKit \
		$(APP)/Sources/*.swift \
		-o $(BIN)
	# Metadata bundle a ikona.
	cp $(APP)/Info.plist $(APPDIR)/Contents/Info.plist
	# Commit a datum sestavení pro okno O aplikaci (mimo git repozitář se commit vynechá).
	-/usr/libexec/PlistBuddy -c "Add :MCBuildCommit string $$(git -C $(ROOT) describe --always --dirty 2>/dev/null)" $(APPDIR)/Contents/Info.plist
	/usr/libexec/PlistBuddy -c "Add :MCBuildDate string $$(date '+%Y-%m-%d %H:%M')" $(APPDIR)/Contents/Info.plist
	@mkdir -p $(APPDIR)/Contents/Resources
	cp $(APP)/AppIcon.icns $(APPDIR)/Contents/Resources/AppIcon.icns
	# Licence staticky přilinkované knihovny SwiftTerm (MIT) jde s aplikací.
	cp $(SWIFTTERM_SRC)/LICENSE $(APPDIR)/Contents/Resources/SwiftTerm-LICENSE.txt
	# Podpis stálou identitou (nejdřív knihovna, pak bundle), pokud je certifikát v klíčence.
	@if security find-identity -p codesigning | grep -q "\"$(SIGN_IDENTITY)\""; then \
		codesign --force --timestamp=none -s "$(SIGN_IDENTITY)" $(APPDIR)/Contents/Frameworks/libsalcore.dylib && \
		codesign --force --timestamp=none -s "$(SIGN_IDENTITY)" $(APPDIR) && \
		echo "Podepsáno identitou: $(SIGN_IDENTITY)"; \
	else \
		echo "Certifikát „$(SIGN_IDENTITY)“ nenalezen – ad-hoc podpis (viz CODESIGNING.md)."; \
	fi
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
