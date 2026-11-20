// Motiv webu: podle systému / prohlížeče (výchozí), světlý nebo tmavý.
// Načítá se v <head> bez defer, aby se uložený motiv nastavil ještě před
// vykreslením stránky a neproblikl; přepínač v navigaci se napojí až po
// načtení DOM. Volba se pamatuje v localStorage.

"use strict";

(function () {
  const STORAGE_KEY = "microcommander-theme";
  const MODES = ["auto", "light", "dark"];
  // Popisky přepínače podle jazyka stránky (<html lang>; "en" = anglická verze)
  const TEXTS = document.documentElement.lang.toLowerCase().startsWith("en")
    ? { names: { auto: "system", light: "light", dark: "dark" }, label: "Theme: {name} (click to switch)" }
    : { names: { auto: "podle systému", light: "světlý", dark: "tmavý" }, label: "Motiv: {name} (klik přepne)" };

  // Uložená volba; localStorage může být nedostupné (soukromé okno, blokovaná data)
  function readMode() {
    try {
      const stored = localStorage.getItem(STORAGE_KEY);
      return MODES.includes(stored) ? stored : "auto";
    } catch {
      return "auto";
    }
  }

  function saveMode(mode) {
    try {
      if (mode === "auto") localStorage.removeItem(STORAGE_KEY);
      else localStorage.setItem(STORAGE_KEY, mode);
    } catch {
      // Bez úložiště volba platí jen do zavření stránky
    }
  }

  // Režim „auto“ = bez atributu data-theme, barvy pak řídí color-scheme podle systému
  function applyMode(mode) {
    if (mode === "auto") delete document.documentElement.dataset.theme;
    else document.documentElement.dataset.theme = mode;
  }

  let currentMode = readMode();
  applyMode(currentMode);

  // Tlačítko cyklicky přepíná auto → světlý → tmavý; ikona a popisek ukazují aktuální režim
  document.addEventListener("DOMContentLoaded", () => {
    const button = document.querySelector(".theme-toggle");
    if (!button) return;

    const updateButton = () => {
      const label = TEXTS.label.replace("{name}", TEXTS.names[currentMode]);
      button.dataset.mode = currentMode;
      button.setAttribute("aria-label", label);
      button.title = label;
    };

    button.addEventListener("click", () => {
      currentMode = MODES[(MODES.indexOf(currentMode) + 1) % MODES.length];
      applyMode(currentMode);
      saveMode(currentMode);
      updateButton();
    });

    updateButton();
  });
})();
