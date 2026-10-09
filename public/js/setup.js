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
  // Observed in sandbox: Reap marks a finished enrollment ACTIVE only when its link window (expiresAt) closes,
  // so after Prava reports success we count down to that moment and keep polling instead of reloading.
  const doneKey = `prava-done:${root.dataset.id || ""}`;
  let pravaDone = sessionStorage.getItem(doneKey) === "1";
  const eta = document.getElementById("confirm-eta");
  const mmss = s => `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
  const tick = () => {
    if (!cd || !expires) return;
    const s = Math.max(0, Math.round((expires - Date.now()) / 1000));
    if (pravaDone) {
      cd.textContent = "";
      if (eta) eta.textContent = s ? `in about ${mmss(s)}` : "any moment now";
      return;
    }
    cd.textContent = s ? `Link valid for ${mmss(s)}` : "Link expired";
    if (!s) location.reload();
  };

  // Open Reap's card page in a popup so the user never leaves this app. Reap only accepts https
  // return URLs, so when the card turns ACTIVE we close the popup ourselves instead of relying on returnUrl.
  let cardWin = null;
  const waitNote = document.getElementById("popup-wait");
  if (open) {
    open.addEventListener("click", e => {
      const w = Math.min(520, screen.availWidth), h = Math.min(860, screen.availHeight);
      const left = Math.max(0, (screen.availWidth - w) / 2), top = Math.max(0, (screen.availHeight - h) / 2);
      cardWin = window.open(open.href, "reap-card", `popup,width=${w},height=${h},left=${left},top=${top}`);
      if (!cardWin) return; // popup blocked: fall back to the normal new-tab link
      e.preventDefault();
      cardWin.focus();
      if (waitNote) waitNote.hidden = false;
      const watch = setInterval(() => {
        if (!cardWin || !cardWin.closed) return;
        clearInterval(watch);
        poll(true);
      }, 1000);
    });
  }

  // In a popup, Prava reports the result to window.opener (PRAVA_ENROLLMENT_COMPLETE, then PRAVA_REDIRECT)
  // and closes itself instead of navigating, so its window closing is not a failure on its own.
  const doneNote = document.getElementById("popup-done");
  const showDone = () => {
    if (waitNote) waitNote.hidden = true;
    const miss = document.getElementById("popup-incomplete");
    if (miss) miss.hidden = true;
    if (doneNote) doneNote.hidden = false;
    document.querySelectorAll("[data-hide-when-done]").forEach(n => n.hidden = true);
    const lp = document.getElementById("live-pill");
    if (lp) lp.lastChild.textContent = "Confirming with Reap";
    tick();
  };
  if (pravaDone) showDone();
  tick(); setInterval(tick, 1000);
  window.addEventListener("message", e => {
    let host = "";
    try { host = new URL(e.origin).hostname; } catch { return; }
    if (!(host === "prava.space" || host.endsWith(".prava.space"))) return;
    const d = e.data || {};
    if (d.type !== "PRAVA_EVENT") return;
    const ok = d.event === "PRAVA_REDIRECT" ||
      (d.event === "PRAVA_ENROLLMENT_COMPLETE" && (d.payload?.status === "completed" || d.payload?.outcome === "fully_enrolled"));
    fetch("/setup/event", { method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify({ event: d.event, payload: d.payload || null }) }).catch(() => {});
    if (!ok) return;
    pravaDone = true;
    sessionStorage.setItem(doneKey, "1");
    showDone();
    poll();
  });

  const pill = document.getElementById("live-pill");
  let busy = false;
  const poll = async (popupClosed = false) => {
    if (busy) return;
    busy = true;
    try {
      const r = await fetch("/setup/status.json", { headers: { accept: "application/json" }, cache: "no-store" });
      if (r.ok) {
        const s = await r.json();
        if (s.status && s.status !== "REQUIRES_ACTION" && s.status !== "NONE") {
          if (cardWin && !cardWin.closed) cardWin.close();
          if (pill && s.status === "ACTIVE") { pill.className = "pill ok"; pill.lastChild.textContent = "Card added"; }
          setTimeout(() => location.reload(), 400);
        } else if (popupClosed && !pravaDone) {
          if (waitNote) waitNote.hidden = true;
          const miss = document.getElementById("popup-incomplete");
          if (miss) miss.hidden = false;
        }
      }
    } catch { /* offline: try again next tick */ } finally { busy = false; }
  };
  setInterval(poll, 3000);
  document.addEventListener("visibilitychange", () => { if (!document.hidden) poll(); });
  window.addEventListener("focus", poll);
})();
