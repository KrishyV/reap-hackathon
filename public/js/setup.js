// Card setup: copy helpers, desktop-Safari preflight, link countdown, and live status polling.
(() => {
  const root = document.getElementById("card-setup");
  if (!root) return;

  document.addEventListener("click", async e => {
    const el = e.target.closest("[data-copy]");
    if (!el) return;
    try {
      await navigator.clipboard.writeText(el.dataset.copy);
      el.classList.add("copied");
      setTimeout(() => el.classList.remove("copied"), 1200);
    } catch { window.prompt("Copy:", el.dataset.copy); }
  });

  // Visa's passkey frame fails on macOS Safari (cross-site frame restrictions); iPhone/iPad are not matched here.
  const ua = navigator.userAgent;
  const desktopSafari = /Safari\//.test(ua) && /Version\//.test(ua) && !/Chrome|Chromium|CriOS|FxiOS|EdgiOS|Edg\/|OPR|Android|Mobile/.test(ua) && (navigator.maxTouchPoints || 0) < 2;
  const open = document.getElementById("open-card");
  if (desktopSafari && open) {
    document.querySelectorAll(".safari-only").forEach(n => n.hidden = false);
    open.classList.add("btn-ghost");
    open.firstChild.textContent = "Try in Safari anyway ";
  }

  const status = root.dataset.status;
  if (status !== "REQUIRES_ACTION") return;

  const cd = document.getElementById("countdown");
  const expires = Date.parse(root.dataset.expires || "");
  const tick = () => {
    if (!cd || !expires) return;
    const s = Math.max(0, Math.round((expires - Date.now()) / 1000));
    cd.textContent = s ? `Link valid for ${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}` : "Link expired";
    if (!s) location.reload();
  };
  tick(); setInterval(tick, 1000);

  const pill = document.getElementById("live-pill");
  let busy = false;
  const poll = async () => {
    if (busy) return;
    busy = true;
    try {
      const r = await fetch("/setup/status.json", { headers: { accept: "application/json" }, cache: "no-store" });
      if (r.ok) {
        const s = await r.json();
        if (s.status && s.status !== "REQUIRES_ACTION" && s.status !== "NONE") {
          if (pill && s.status === "ACTIVE") { pill.className = "pill ok"; pill.lastChild.textContent = "Card added"; }
          setTimeout(() => location.reload(), 400);
        }
      }
    } catch { /* offline: try again next tick */ } finally { busy = false; }
  };
  setInterval(poll, 3000);
  document.addEventListener("visibilitychange", () => { if (!document.hidden) poll(); });
  window.addEventListener("focus", poll);
})();
