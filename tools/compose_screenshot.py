#!/usr/bin/env python3
# Složí screenshot pro web (site/screenshot-*.webp) ze snímku okna aplikace.
#
# Vstupem je PNG ze SAL_SNAPSHOT pořízené na Retina displeji (2×) z okna
# 1060×760 pt, viz README (sekce o webu). Skript:
#   - ořízne vše nad řádkem s cestou levého panelu (toolbar a lišta disků
#     s osobními názvy disků),
#   - vyřízne pás prázdného místa pod seznamy souborů,
#   - zmenší výsledek na šířku 1760 px (2× zobrazovací šířka 880 px na webu).
#
# Použití: python3 tools/compose_screenshot.py vstup.png výstup.png
# WebP pak: cwebp -q 85 výstup.png -o site/screenshot-cs.webp
import sys

from PIL import Image

# Výstupní šířka v px: 2× max-width obrázku .shot v site/style.css
TARGET_WIDTH = 1760
# Pás prázdného místa pod seznamy (řádky v px vstupního snímku okna 1060×760 pt)
CUT_FROM, CUT_TO = 1090, 1190


def find_top(image):
    # Vrátí první řádek, kde začíná modrý pruh s cestou aktivního (levého) panelu.
    # Parametr image: vstupní snímek okna v RGB.
    for y in range(image.height):
        red, _, blue = image.getpixel((300, y))
        if blue > 200 and red < 60:
            return y
    raise SystemExit("pruh s cestou levého panelu nenalezen")


def check_empty_band(image):
    # Ověří, že vyřezávaný pás je opravdu prázdný (jen pozadí panelů a předěl),
    # jinak by se vyřízly položky seznamu nebo stavový řádek.
    # Parametr image: vstupní snímek okna v RGB.
    for y in range(CUT_FROM, CUT_TO):
        colors = {image.getpixel((x, y)) for x in range(20, image.width - 20, 7)}
        if len(colors) > 3:
            raise SystemExit(f"řádek {y} není prázdný – uprav CUT_FROM/CUT_TO")


def main(source_path, output_path):
    # Načte snímek okna, ořízne, vyřízne prázdný pás, zmenší a uloží PNG.
    # Parametry: source_path – PNG ze SAL_SNAPSHOT, output_path – výstupní PNG.
    source = Image.open(source_path).convert("RGB")
    top = find_top(source)
    check_empty_band(source)

    # Složení: horní část (od pruhu s cestou) + spodní část bez prázdného pásu
    upper = source.crop((0, top, source.width, CUT_FROM))
    lower = source.crop((0, CUT_TO, source.width, source.height))
    composed = Image.new("RGB", (source.width, upper.height + lower.height))
    composed.paste(upper, (0, 0))
    composed.paste(lower, (0, upper.height))

    height = round(composed.height * TARGET_WIDTH / composed.width)
    composed.resize((TARGET_WIDTH, height), Image.LANCZOS).save(output_path)
    print(f"{output_path}: {TARGET_WIDTH}×{height}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("použití: compose_screenshot.py vstup.png výstup.png")
    main(sys.argv[1], sys.argv[2])
