# Podepisování aplikace (aby se macOS neptal po každém buildu)

## Problém

Po každém `make` se macOS znovu ptá, zda smí „MicroCommander.app“ přistupovat
k souborům ve složce Stahování (Dokumenty, Plocha, síťové svazky…).

Příčina: oprávnění soukromí (TCC) si macOS pamatuje podle **podpisu aplikace**.
Bez vlastního certifikátu binárku podepíše jen linker tzv. ad-hoc podpisem,
který je odvozený z hashe obsahu – po každém buildu je jiný, a macOS proto
považuje novou verzi za jinou aplikaci.

Řešení: podepisovat stálou identitou (vlastním certifikátem). Podpis pak
obsahuje identifikátor aplikace a otisk certifikátu, které se mezi buildy
nemění, a udělená oprávnění zůstanou.

## 1. Vytvoření certifikátu (jednorázově)

Certifikát podepsaný sám sebou stačí – není potřeba Apple Developer účet.

1. Otevřít aplikaci **Klíčenka** (Keychain Access).
2. V horní liště menu: **Klíčenka › Průvodce certifikací › Vytvořit certifikát…**
   (ve starších verzích macOS „Asistent certifikátů“).
3. Vyplnit:
   - **Název:** `MicroCommander Dev`
   - **Typ identity:** Kořen podepsaný sebou samým
   - **Typ certifikátu:** **Podepisování kódu** (Code Signing) – ne výchozí
     S/MIME (e-mail), tím kód podepsat nejde
   - „Povolit přepsání výchozích hodnot“ nechat nezaškrtnuté
4. **Vytvořit** a potvrdit upozornění na certifikát podepsaný sám sebou.

Certifikát se objeví v Klíčence (svazek „přihlášení“, záložka Moje certifikáty).

Kontrola v terminálu:

```
security find-identity -p codesigning
```

Ve výpisu musí být `"MicroCommander Dev"`. Stav `CSSMERR_TP_NOT_TRUSTED` je
u certifikátu podepsaného sám sebou v pořádku – podepisování nevadí.

## 2. Build s podpisem

`make` (cíl `app`) certifikát najde sám a podepíše knihovnu
`libsalcore.dylib` i celý bundle:

```
Podepsáno identitou: MicroCommander Dev
```

Při prvním podpisu se macOS zeptá, zda smí `codesign` použít klíč z klíčenky –
zadat heslo k Macu a zvolit **Vždy povolit** (jinak se bude ptát při každém buildu).

Pokud certifikát v klíčence není, build pokračuje s ad-hoc podpisem
a vypíše upozornění. Jiný název identity lze zadat proměnnou:

```
make SIGN_IDENTITY="Apple Development: Jméno (XXXXXXXXXX)"
```

## 3. Ověření

```
codesign -dv build/MicroCommander.app        # Authority=MicroCommander Dev
codesign -d -r- build/MicroCommander.app     # designated => identifier "com.github.svopex.microcommander" and certificate leaf = H"…"
codesign --verify --deep --strict build/MicroCommander.app
```

Po přechodu na podepsanou verzi se macOS na přístup ke Stahování zeptá ještě
**jednou**; další buildy už oprávnění zdědí.

## Poznámky

- Certifikát je jen v klíčence tohoto Macu. Na jiném počítači je potřeba
  vytvořit vlastní (nebo certifikát exportovat jako .p12 i s klíčem a naimportovat).
- Při smazání nebo obnovení certifikátu se změní jeho otisk – macOS se pak
  zeptá znovu (jednou).
- Starou položku oprávnění lze smazat v Nastavení systému › Soukromí
  a zabezpečení › Soubory a složky, případně
  `tccutil reset SystemPolicyDownloadsFolder com.github.svopex.microcommander`.
- Plný přístup k disku problém neřeší – je navázaný na podpis stejně.
