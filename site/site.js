// Skripty webové stránky projektu: tlačítko Kopírovat u bloků s příkazy
// a tlačítko Poslat e-mail. Načítá se s atributem defer, takže běží až po
// načtení celého HTML.

// Tlačítka „Poslat e-mail“: adresa je v data-email obrácená a v base64, aby ji
// nenašli roboti. Složí se až po kliknutí a otevře poštovního klienta; na stránce
// se nezobrazí.
document.querySelectorAll(".email-btn").forEach((button) => {
  button.addEventListener("click", () => {
    const email = atob(button.dataset.email || "").split("").reverse().join("");
    if (email.includes("@")) {
      window.location.href = `mailto:${email}`;
    }
  });
});

// Texty tlačítka kopírování podle jazyka stránky (<html lang>): anglická verze
// (en/index.html) má "en", cokoli jiného zůstává česky (výchozí index.html)
const IS_ENGLISH = (document.documentElement.lang || "").toLowerCase().startsWith("en");
const COPY_TEXTS = IS_ENGLISH
  ? { copy: "Copy", copied: "Copied", failed: "Copy failed" }
  : { copy: "Kopírovat", copied: "Zkopírováno", failed: "Nelze kopírovat" };

// Ke každému bloku <pre><code> přidá tlačítko, které zkopíruje text příkazů
// do schránky a na chvíli ukáže potvrzení. Bez přístupu ke schránce (starý
// prohlížeč, nezabezpečená stránka) se tlačítko nepřidá a blok nemá vpravo
// vyhrazené místo (třída has-copy).
if (navigator.clipboard) {
  document.querySelectorAll("pre > code").forEach((code) => {
    const block = code.parentElement;
    const button = document.createElement("button");
    button.type = "button";
    button.className = "copy";
    button.textContent = COPY_TEXTS.copy;

    button.addEventListener("click", async () => {
      try {
        await navigator.clipboard.writeText(code.innerText.trim());
        button.textContent = COPY_TEXTS.copied;
      } catch {
        button.textContent = COPY_TEXTS.failed;
      }
      setTimeout(() => { button.textContent = COPY_TEXTS.copy; }, 1600);
    });

    block.classList.add("has-copy");
    block.appendChild(button);
  });
}
