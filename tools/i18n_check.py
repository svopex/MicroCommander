#!/usr/bin/env python3
"""Kontrola úplnosti anglických překladů (spuštění: python3 tools/i18n_check.py [soubor…]).

Swift UI (app/Sources/*.swift, kromě SelfTest.swift):
- české texty (s diakritikou) mimo první parametr tr(…) – včetně spojení "a" + "b",
- tr() s interpolací "\\(x)" (klíč musí být pevný text, hodnoty přes %@),
- klíče tr() bez překladu ve slovnících app/Locales/en/*.json.
Jádro (core/crates/salcore/src/*.rs, bez testových modulů a i18n.rs):
- české texty mimo první parametr tr(…) / trf(…), klíče bez překladu v tabulce EN (i18n.rs).
Slovníky: stejný český text přeložený v různých souborech různě, jiný počet
zástupných symbolů (%@ ve Swiftu, {} v Rustu) v překladu než v originále.
Pozor: české texty bez diakritiky (např. „Kopie“) kontrola nepozná – projít ručně.
"""

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SWIFT_DIR = ROOT / "app" / "Sources"
LOCALES_DIR = ROOT / "app" / "Locales" / "en"
RUST_DIR = ROOT / "core" / "crates" / "salcore" / "src"
RUST_TABLE = RUST_DIR / "i18n.rs"
# Self-test vypisuje vývojářské hlášky a hledá prvky podle českých popisků;
# Localization.swift má názvy jazyků záměrně v jejich vlastním jazyce („Čeština“)
SWIFT_SKIP = {"SelfTest.swift", "Localization.swift"}

CZECH = re.compile(r"[áčďéěíňóřšťúůýžÁČĎÉĚÍŇÓŘŠŤÚŮÝŽ]")
# Řetězec v uvozovkách (bez víceřádkových """ – ty se zpracují zvlášť) nebo komentář
# Raw stringy Swiftu (#"…"#, #"""…"""#) začínají '#' – jde o vložené skripty, které se nepřekládají
STRING_OR_COMMENT = re.compile(
    r'#"""[\s\S]*?"""#|#"[^"\n]*"#|"""[\s\S]*?"""|"(?:\\.|[^"\\\n])*"|//[^\n]*|/\*[\s\S]*?\*/'
)
# Formátovací symboly String(format:) (bez %%) a zástupné symboly Rustu
SWIFT_SPEC = re.compile(r"%(?:\d+\$)?[-+ 0#]*\d*(?:\.\d+)?(?:ll|l|h)?[@dDiuUxXoOfeEgGcCsSp]")
RUST_SPEC = re.compile(r"\{\}")


def unescape(literal: str) -> str:
    """Hodnota řetězcového literálu Swiftu/Rustu (bez uvozovek, s rozbalenými escapy)."""
    body = literal[3:-3] if literal.startswith('"""') else literal[1:-1]
    body = re.sub(r"\\u\{([0-9A-Fa-f]+)\}", lambda m: chr(int(m.group(1), 16)), body)
    replacements = {"\\n": "\n", "\\t": "\t", '\\"': '"', "\\\\": "\\", "\\0": "\0", "\\'": "'"}
    return re.sub(r"\\[nt\"\\0']", lambda m: replacements[m.group(0)], body)


def tokens(source: str):
    """Řetězcové literály souboru jako (začátek, konec, literál); komentáře se přeskočí."""
    for match in STRING_OR_COMMENT.finditer(source):
        if match.group(0).startswith('"'):
            yield match.start(), match.end(), match.group(0)


def translation_keys(source: str, funcs: tuple[str, ...]) -> tuple[dict[int, str], set[int], list[int]]:
    """Najde klíče prvních parametrů volání funcs (literály spojené +).

    Vrací (pozice začátku volání → klíč, množina pozic literálů, které jsou součástí
    klíče, pozice volání s interpolací).
    """
    literals = list(tokens(source))
    by_start = {start: (end, text) for start, end, text in literals}
    keys: dict[int, str] = {}
    used: set[int] = set()
    interpolated: list[int] = []
    pattern = re.compile(r"\b(" + "|".join(funcs) + r")\(\s*")
    for call in pattern.finditer(source):
        position = call.end()
        # trc("kontext", "text"): kontext je první literál, klíč je "kontext|text"
        prefix = ""
        if call.group(1) == "trc" and position in by_start:
            context_end, context_text = by_start[position]
            used.add(position)
            prefix = unescape(context_text) + "|"
            rest = re.match(r"\s*,\s*", source[context_end:])
            position = context_end + rest.end() if rest else context_end
        parts = []
        # Literály spojené operátorem + až do čárky nebo konce argumentu
        while position in by_start:
            end, text = by_start[position]
            parts.append(text)
            used.add(position)
            rest = re.match(r"\s*\+\s*", source[end:])
            if not rest or end + rest.end() not in by_start:
                break
            position = end + rest.end()
        if parts:
            if any("\\(" in part for part in parts):
                interpolated.append(call.start())
            keys[call.start()] = prefix + "".join(unescape(part) for part in parts)
    # plural(count, "soubor", "soubory", "souborů"): všechny literály v závorce jsou klíče
    for call in re.finditer(r"\bplural\(", source):
        depth, position = 1, call.end()
        while position < len(source) and depth:
            if position in by_start:
                end, text = by_start[position]
                used.add(position)
                keys[position] = unescape(text)
                position = end
                continue
            depth += {"(": 1, ")": -1}.get(source[position], 0)
            position += 1
    return keys, used, interpolated


def line_of(source: str, position: int) -> int:
    """Číslo řádku pozice v souboru."""
    return source.count("\n", 0, position) + 1


def check_source(path: Path, source: str, funcs: tuple[str, ...]) -> tuple[list[str], set[str]]:
    """Zkontroluje zdrojový text: nepřeložené české literály a interpolace v klíčích."""
    keys, used, interpolated = translation_keys(source, funcs)
    problems = [f"{path.relative_to(ROOT)}:{line_of(source, p)}: tr() s interpolací \\(…) – použijte %@"
                for p in interpolated]
    for start, _end, text in tokens(source):
        if start not in used and CZECH.search(text):
            problems.append(f"{path.relative_to(ROOT)}:{line_of(source, start)}: nepřeložený text: {text[:90]}")
    return problems, set(keys.values())


def rust_source(path: Path) -> str:
    """Zdroják Rustu bez testového modulu (#[cfg(test)] a vše za ním)."""
    source = path.read_text(encoding="utf-8")
    marker = source.find("#[cfg(test)]")
    return source if marker == -1 else source[:marker]


def swift_catalog() -> tuple[dict[str, str], list[str]]:
    """Sloučený anglický slovník Swiftu a konflikty mezi soubory."""
    words: dict[str, tuple[str, str]] = {}
    problems = []
    for file in sorted(LOCALES_DIR.glob("*.json")):
        for key, value in json.loads(file.read_text(encoding="utf-8")).items():
            if key in words and words[key][1] != value:
                problems.append(f"různé překlady {key!r}: {words[key][0]}={words[key][1]!r}, {file.name}={value!r}")
            words.setdefault(key, (file.name, value))
    return {key: value for key, (_, value) in words.items()}, problems


def rust_catalog() -> dict[str, str]:
    """Tabulka EN z i18n.rs (český text → překlad)."""
    source = rust_source(RUST_TABLE)
    pairs = re.findall(r'\(\s*("(?:\\.|[^"\\])*")\s*,\s*("(?:\\.|[^"\\])*")\s*\)', source)
    return {unescape(czech): unescape(english) for czech, english in pairs}


def check_keys(keys: set[str], words: dict[str, str], spec: re.Pattern, where: str) -> list[str]:
    """Klíče bez překladu a překlady s jiným počtem zástupných symbolů."""
    problems = []
    for key in sorted(keys):
        if key not in words:
            problems.append(f"chybí překlad ({where}): {key!r}")
        elif len(spec.findall(key.replace("%%", ""))) != len(spec.findall(words[key].replace("%%", ""))):
            problems.append(f"jiné zástupné symboly ({where}): {key!r} => {words[key]!r}")
    return problems


def run(paths: list[Path] | None = None) -> list[str]:
    """Spustí kontrolu (bez zadání všech souborů) a vrátí seznam problémů."""
    # Vynechané soubory (self-test, tabulky překladů) se nekontrolují ani při výslovném zadání
    candidates = paths or [*sorted(SWIFT_DIR.glob("*.swift")), *sorted(RUST_DIR.glob("*.rs"))]
    swift_files = [p for p in candidates if p.suffix == ".swift" and p.name not in SWIFT_SKIP]
    rust_files = [p for p in candidates if p.suffix == ".rs" and p.name != "i18n.rs"]
    problems: list[str] = []
    swift_keys: set[str] = set()
    rust_keys: set[str] = set()
    for path in swift_files:
        file_problems, keys = check_source(path, path.read_text(encoding="utf-8"), ("tr", "trc"))
        problems += file_problems
        swift_keys |= keys
    for path in rust_files:
        file_problems, keys = check_source(path, rust_source(path), ("tr", "trf"))
        problems += file_problems
        rust_keys |= keys
    words, conflicts = swift_catalog()
    problems += conflicts
    problems += check_keys(swift_keys, words, SWIFT_SPEC, "Swift")
    problems += check_keys(rust_keys, rust_catalog(), RUST_SPEC, "Rust")
    return problems


def main() -> int:
    """Vypíše problémy; návratový kód 1, když nějaké jsou."""
    paths = [Path(arg).resolve() for arg in sys.argv[1:]] or None
    problems = run(paths)
    for problem in problems:
        print(problem)
    print(f"Problémů: {len(problems)}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
