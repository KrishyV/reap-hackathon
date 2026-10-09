// Shared helpers: monogram fallback for broken merchant/product images.
(() => {
  const hue = s => { let h = 0; for (const c of String(s)) h = (h * 31 + c.codePointAt(0)) % 360; return h; };
  const toTile = img => {
    const label = img.dataset.fallback || img.alt || "?";
    const tile = document.createElement("span");
    tile.className = `${img.className} mono`;
    tile.style.setProperty("--h", hue(label));
    tile.textContent = Array.from(label.trim())[0] || "?";
    if (img.alt) { tile.setAttribute("role", "img"); tile.setAttribute("aria-label", img.alt); } else tile.setAttribute("aria-hidden", "true");
    img.replaceWith(tile);
  };
  document.addEventListener("error", e => {
    if (e.target instanceof HTMLImageElement && "fallback" in e.target.dataset) toTile(e.target);
  }, true);
  const sweep = () => document.querySelectorAll("img[data-fallback]").forEach(img => {
    if (img.complete && img.naturalWidth === 0) toTile(img);
  });
  document.readyState === "loading" ? document.addEventListener("DOMContentLoaded", sweep) : sweep();
  window.DB = { hue };
})();
