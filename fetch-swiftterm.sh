#!/usr/bin/env bash
#
# Stáhne zdrojáky knihovny SwiftTerm (emulátor terminálu pro vestavěný
# terminál, licence MIT) v připnuté verzi do adresáře `vendor/SwiftTerm/`
# v kořeni projektu. Adresář se do repozitáře necommituje (viz `.gitignore`).
#
# Použití (volá ho Makefile, verzi a commit drží Makefile):
#   ./fetch-swiftterm.sh <tag> <commit>
#
# Proměnná prostředí SWIFTTERM_REPO umožňuje přepsat zdrojový repozitář.

set -euo pipefail

REPO_URL="${SWIFTTERM_REPO:-https://github.com/migueldeicaza/SwiftTerm.git}"
VERSION="${1:?Chybí tag verze (např. v1.20.0)}"
COMMIT="${2:?Chybí očekávaný commit tagu}"

# Cílový adresář je vždy vedle skriptu, bez ohledu na to, odkud se spouští
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$ROOT/vendor/SwiftTerm"

# Klonuje se nejdřív do dočasného adresáře systému, aby případné selhání
# stahování nesmazalo stávající funkční kopii (a klon s vlastním .git
# nevznikal uvnitř repozitáře projektu)
mkdir -p "$ROOT/vendor"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/microcommander-swiftterm.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "Stahuji SwiftTerm ${VERSION} z ${REPO_URL}…"
git clone --quiet --depth 1 --branch "$VERSION" -c advice.detachedHead=false "$REPO_URL" "$TMP_DIR/repo"

# Tag musí ukazovat na připnutý commit – přepsaný tag (jiný kód pod stejným
# jménem) se odmítne
ACTUAL="$(git -C "$TMP_DIR/repo" rev-parse HEAD)"
if [[ "$ACTUAL" != "$COMMIT" ]]; then
    echo "Chyba: tag $VERSION ukazuje na commit $ACTUAL, očekáván $COMMIT." >&2
    exit 1
fi

# Do projektu jdou jen zdrojáky knihovny a licence (bez testů, ukázek a .git)
mkdir -p "$TMP_DIR/SwiftTerm/Sources"
mv "$TMP_DIR/repo/Sources/SwiftTerm" "$TMP_DIR/SwiftTerm/Sources/SwiftTerm"
mv "$TMP_DIR/repo/LICENSE" "$TMP_DIR/SwiftTerm/LICENSE"
# Značka stažené verze – podle ní Makefile pozná, že není co stahovat
touch "$TMP_DIR/SwiftTerm/.fetched-$VERSION"

# Nahrazení stávajícího adresáře novou kopií (rm -rf neselže, když neexistuje)
rm -rf "$TARGET"
mv "$TMP_DIR/SwiftTerm" "$TARGET"

echo "Hotovo: $TARGET ($VERSION)"
