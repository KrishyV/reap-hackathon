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
  // ---------- Inline form errors ----------
  // Field errors appear only after the user leaves a field (blur) or submits, never mid-typing.
  const CONTROL = ".field input, .field select, .field textarea";
  const PHONE = /^\+[1-9]\d{6,14}$/;
  const labelOf = el => {
    const l = el.closest(".field");
    const t = l && [...l.childNodes].find(n => n.nodeType === 3 && n.textContent.trim());
    return t ? t.textContent.trim() : "This field";
  };
  const messageFor = el => {
    const v = el.validity;
    if (v.valid) return "";
    if (v.valueMissing) return `${labelOf(el)} is required`;
    if (el.type === "email") return "Enter a valid email, e.g. ada@example.com";
    if (el.name === "phone") return "Include the country code, e.g. +65 9123 4567";
    if (/country/.test(el.name)) return "Use a 2-letter country code, e.g. SG";
    return el.validationMessage;
  };
  const syncCustom = el => {
    if (el.name === "phone" && el.type === "tel") {
      const n = el.value.replace(/[\s\-().]/g, "");
      el.setCustomValidity(n && !PHONE.test(n) ? "phone" : "");
    }
  };
  const showError = (el, msg) => {
    const field = el.closest(".field");
    if (!field) return false;
    let err = field.querySelector(".field-error");
    if (!err) {
      err = document.createElement("span");
      err.className = "field-error";
      err.id = `err-${el.name}-${Math.random().toString(36).slice(2, 7)}`;
      field.append(err);
    }
    err.textContent = msg;
    el.setAttribute("aria-invalid", "true");
    el.setAttribute("aria-describedby", err.id);
    return true;
  };
  const clearError = el => {
    const err = el.closest(".field")?.querySelector(".field-error");
    if (err) err.remove();
    el.removeAttribute("aria-invalid");
    el.removeAttribute("aria-describedby");
  };
  const reveal = el => {
    const d = el.closest("details");
    if (d) d.open = true;
    el.focus({ preventScroll: true });
    el.scrollIntoView({ block: "center", behavior: matchMedia("(prefers-reduced-motion: reduce)").matches ? "auto" : "smooth" });
  };

  document.addEventListener("input", e => {
    const el = e.target;
    if (!el.matches?.(CONTROL)) return;
    el.dataset.dirty = "1";
    syncCustom(el);
    clearError(el);
  });
  document.addEventListener("change", e => { if (e.target.matches?.(".field select")) clearError(e.target); });
  document.addEventListener("focusout", e => {
    const el = e.target;
    if (!el.matches?.(CONTROL) || !el.dataset.dirty) return;
    syncCustom(el);
    const msg = messageFor(el);
    msg ? showError(el, msg) : clearError(el);
  });
  // On submit the browser fires "invalid" per bad field: swap its bubble for our inline error.
  let focusQueued = false;
  document.addEventListener("invalid", e => {
    const el = e.target;
    if (!el.matches?.(CONTROL)) return;
    e.preventDefault();
    showError(el, messageFor(el));
    if (!focusQueued) {
      focusQueued = true;
      setTimeout(() => { focusQueued = false; const first = (el.form || document).querySelector('[aria-invalid="true"]'); if (first) reveal(first); });
    }
  }, true);
  const prime = () => document.querySelectorAll(CONTROL).forEach(syncCustom);
  document.readyState === "loading" ? document.addEventListener("DOMContentLoaded", prime) : prime();
  document.addEventListener("focusin", e => { if (e.target.matches?.(CONTROL)) syncCustom(e.target); });

  // Server messages -> the field they're about, so they render under that input.
  const SERVER_FIELDS = [
    [/^name\b/i, "first_name"], [/email/i, "email"], [/^phone/i, "phone"], [/^address/i, "address_line1"],
    [/^city/i, "city"], [/^postal/i, "postal_code"], [/ship-to country/i, "ship_country"], [/^country/i, "country"],
    [/^budget/i, "budget"], [/tell the agent/i, "goal"]
  ];
  const formError = (form, submitter, msg) => {
    const host = submitter || [...form.elements].find(el => el.type === "submit");
    let err = form.__err;
    if (!err) {
      err = form.__err = document.createElement("p");
      err.className = "form-error";
      err.setAttribute("role", "alert");
    }
    err.textContent = msg;
    host ? host.after(err) : form.append(err);
  };
  const serverError = (form, submitter, msg) => {
    const hit = SERVER_FIELDS.find(([re]) => re.test(msg));
    const el = hit && form.elements[hit[1]];
    if (el instanceof Element && el.matches(CONTROL) && showError(el, msg)) return reveal(el);
    formError(form, submitter, msg);
  };

  const errorText = (body, status) => {
    const text = /<[a-z!]/i.test(body)
      ? (new DOMParser().parseFromString(body, "text/html").body.textContent || "").replace(/\s+/g, " ").trim()
      : body.trim();
    return text && text.length < 400 ? text : `Something went wrong (HTTP ${status}). Please try again.`;
  };

  // Submit same-origin POST forms with fetch so server validation errors (4xx) show inline
  // and the user keeps their input. Opt out with data-native.
  document.addEventListener("submit", async e => {
    const form = e.target;
    if (e.defaultPrevented || !(form instanceof HTMLFormElement) || "native" in form.dataset) return;
    if ((form.getAttribute("method") || "get").toLowerCase() !== "post") return;
    const url = new URL(form.action, location.href);
    if (url.origin !== location.origin) return;
    e.preventDefault();
    form.__err?.remove();
    let res, body;
    try {
      res = await fetch(url, {
        method: "POST", credentials: "same-origin",
        headers: { Accept: "text/html", "Content-Type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams(new FormData(form, e.submitter))
      });
      if (res.ok) { location.assign(res.url); return; }
      body = await res.text();
    } catch (_) {
      body = "Couldn't reach the server. Check your connection and try again.";
    }
    const status = res ? res.status : 0;
    form.dispatchEvent(new CustomEvent("db:submit-failed", { detail: { status } }));
    serverError(form, e.submitter, errorText(body, status));
  });

  window.DB = { hue };
})();
