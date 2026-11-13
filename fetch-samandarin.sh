#!/usr/bin/env bash
#
# Stáhne původní Windows zdrojáky Open Samandarin do adresáře `samandarin/`
# v kořeni projektu a odstraní z nich vazbu na git (adresář `.git`).
#
# Použití:
#   ./fetch-samandarin.sh            – stáhne výchozí větev
#   ./fetch-samandarin.sh <větev>    – stáhne zadanou větev nebo tag
#
# Proměnná prostředí SAMANDARIN_REPO umožňuje přepsat zdrojový repozitář.

set -euo pipefail

REPO_URL="${SAMANDARIN_REPO:-https://github.com/KRtkovo-eu-AI/salamander.git}"
BRANCH="${1:-}"

# Cílový adresář je vždy vedle skriptu, bez ohledu na to, odkud se spouští
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$ROOT/samandarin"

# Klonuje se nejdřív do dočasného adresáře, aby případné selhání stahování
# nesmazalo stávající funkční kopii
TMP_DIR="$(mktemp -d "$ROOT/.samandarin-tmp.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

# Mělký klon (jen poslední commit) – historie není potřeba a ušetří čas i místo.
# Včetně git submodulů (např. plugin src/plugins/sftp, 3rd-party/HardView),
# jinak by po nich zůstaly jen prázdné adresáře. Submoduly se stahují paralelně.
CLONE_ARGS=(--depth 1 --recurse-submodules --shallow-submodules --jobs 4)
if [[ -n "$BRANCH" ]]; then
    CLONE_ARGS+=(--branch "$BRANCH")
fi

echo "Stahuji $REPO_URL ${BRANCH:+(větev $BRANCH)}…"
git clone "${CLONE_ARGS[@]}" "$REPO_URL" "$TMP_DIR/samandarin"

# Odstranění vazby na git: adresář .git a případné .git soubory submodulů
find "$TMP_DIR/samandarin" -name .git -prune -exec rm -rf {} +

# Nahrazení stávajícího adresáře novou kopií (rm -rf neselže, když neexistuje)
rm -rf "$TARGET"
mv "$TMP_DIR/samandarin" "$TARGET"

echo "Hotovo: $TARGET (bez .git)"
