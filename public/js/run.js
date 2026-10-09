(() => {
  const root = document.querySelector(".run[data-run]");
  if (!root) return;
  const id = root.dataset.run;
  const $ = (sel, el = document) => el.querySelector(sel);
  const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  const hue = s => (window.DB ? window.DB.hue(s) : 20);
  const initial = s => Array.from(String(s || "?").trim())[0] || "?";
  const icon = (name, cls = "") => `<svg class="${cls}" aria-hidden="true"><use href="#i-${name}"/></svg>`;
  const reduced = matchMedia("(prefers-reduced-motion: reduce)").matches;

  // ---------- Money ----------
  const SYM = { USD: "$", GBP: "£", EUR: "€", JPY: "¥", SGD: "S$", AUD: "A$", CAD: "C$", HKD: "HK$", NZD: "NZ$", CNY: "CN¥", KRW: "₩", INR: "₹", THB: "฿", CHF: "CHF ", MYR: "RM", PHP: "₱", IDR: "Rp", VND: "₫" };
  const ZERO_DP = new Set(["JPY", "KRW", "VND", "IDR"]);
  const parse = s => {
    const m = String(s ?? "").trim().match(/^(?:([A-Z]{3})\s*|\$)?(-?[\d,]*\.?\d+)$/);
    return m ? { cur: m[1] || "USD", cents: Math.round(parseFloat(m[2].replace(/,/g, "")) * 100) } : null;
  };
  const fmt = (cents, cur = "USD") => {
    const dp = ZERO_DP.has(cur) ? 0 : 2;
    const v = (Math.abs(cents) / 100).toLocaleString("en-US", { minimumFractionDigits: dp, maximumFractionDigits: dp });
    return `${cents < 0 ? "−" : ""}${SYM[cur] ?? `${cur} `}${v}`;
  };
  const money = s => { const p = parse(s); return p ? fmt(p.cents, p.cur) : String(s ?? ""); };
  const cents = s => parse(s)?.cents ?? 0;
  const priceHtml = o => o.original_price
    ? `${esc(money(o.original_price))} <span class="fx">≈ ${esc(money(o.unit_price))}</span>`
    : esc(money(o.unit_price));

  const safeUrl = u => (/^https?:\/\//i.test(String(u || "")) ? String(u) : "");
  const pic = (url, label, cls) => safeUrl(url)
    ? `<img class="${cls}" src="${esc(safeUrl(url))}" alt="" loading="lazy" decoding="async" referrerpolicy="no-referrer" data-fallback="${esc(label)}">`
    : `<span class="${cls} mono" style="--h:${hue(label)}" aria-hidden="true">${esc(initial(label))}</span>`;

  const PRIO = { 1: "Essential", 2: "Recommended", 3: "Nice to have" };
  const prioLabel = p => PRIO[p] || (p ? `Priority ${Number(p) || ""}` : "");
  const DROP = { over_budget: "Didn't fit the budget", no_available_option: "No in-stock option found" };
  const humanize = s => String(s ?? "").replace(/_/g, " ").toLowerCase().replace(/^./, c => c.toUpperCase());

  // ---------- Header: status, stepper, now line ----------
  const STATUS = {
    planning: ["Planning", "hot live"], awaiting_review: ["Ready for your approval", "warn"],
    purchasing: ["Buying", "hot live"], done: ["Done", "ok"], failed: ["Failed", "bad"]
  };
  function renderHeader(run) {
    const [label, cls] = STATUS[run.status] || [humanize(run.status), ""];
    $("#status").textContent = label;
    $("#status-pill").className = `pill ${cls}`;
    $("#autopilot-pill").hidden = !run.autopilot;

    const planned = run.log.some(l => /^Plan:/.test(l.msg));
    let at, err = false;
    switch (run.status) {
      case "planning": at = planned ? 1 : 0; break;
      case "awaiting_review": at = 2; break;
      case "purchasing": at = run.card ? 4 : 3; break;
      case "done": at = 6; break;
      default: err = true; at = run.orders.length ? 4 : run.card ? 3 : run.basket ? 2 : planned ? 1 : 0;
    }
    [...$("#stepper").children].forEach((li, i) => {
      li.className = i < at ? "done" : i === at ? (err ? "error" : "active") : "";
      if (i === at && !err) li.setAttribute("aria-current", "step"); else li.removeAttribute("aria-current");
    });

    const now = $("#now");
    const last = run.log[run.log.length - 1]?.msg;
    let text = last || "Waking up the agent…";
    if (run.status === "awaiting_review") text = "Basket ready. Check it over and tap Approve.";
    if (run.status === "done") text = run.receipt?.frozen ? "All done. The card is frozen and can't be charged again." : (last || "All done.");
    if (run.status === "failed") text = run.error ? `Stopped: ${run.error}` : (last || "Something went wrong.");
    now.className = `now ${run.status === "failed" ? "bad" : ["done", "awaiting_review"].includes(run.status) ? "idle" : ""}`;
    if ($("#now-text").textContent !== text) $("#now-text").textContent = text;
  }

  // ---------- Timeline (append-only so entries animate once) ----------
  const KIND_ICON = { plan: "spark", search: "search", basket: "bag", card: "card", freeze: "snow", ok: "check", bad: "alert" };
  const kindOf = m =>
    /^(error|warning)|failed|declined/i.test(m) ? "bad"
      : /froze/i.test(m) ? "freeze"
        : /order placed|all done/i.test(m) ? "ok"
          : /card|issued|loaded|held /i.test(m) ? "card"
            : /proposed basket|review the basket|autopilot/i.test(m) ? "basket"
              : /compared|search|found|candidates|merchants? priced/i.test(m) ? "search"
                : /^plan|thinking/i.test(m) ? "plan" : "";
  let logShown = 0;
  function renderLog(run) {
    const ol = $("#log");
    if (run.log.length < logShown) { ol.replaceChildren(); logShown = 0; }
    if (run.log.length === logShown) return;
    const nearBottom = ol.scrollHeight - ol.scrollTop - ol.clientHeight < 40;
    const frag = document.createDocumentFragment();
    run.log.slice(logShown).forEach(l => {
      const k = kindOf(l.msg);
      const li = document.createElement("li");
      li.className = k ? `k-${k}` : "";
      li.innerHTML = `<span class="tdot">${icon(KIND_ICON[k] || "dot")}</span><span><time>${esc(l.at)}</time><span class="tmsg">${esc(l.msg)}</span></span>`;
      frag.append(li);
    });
    ol.append(frag);
    logShown = run.log.length;
    $("#log-count").textContent = logShown;
    if (nearBottom || logShown < 6) ol.scrollTop = ol.scrollHeight;
  }

  // ---------- Stage modes ----------
  const stage = $("#stage");
  const slot = $("#summary-slot");
  let mode = null;
  const setMode = m => {
    if (mode === m) return false;
    mode = m;
    stage.replaceChildren(); slot.replaceChildren();
    $("#mbar")?.remove(); document.body.classList.remove("has-mbar");
    $("#grid").classList.toggle("review-mode", m === "review");
    return true;
  };

  function renderPlanning(run) {
    if (!setMode("planning")) return;
    const budget = esc(money(run.budget));
    stage.innerHTML = `
      <section class="glass planning" aria-busy="true" aria-label="The agent is planning">
        <div class="steamer">
          <svg viewBox="0 0 64 64" aria-hidden="true"><g class="bob"><use href="#dumpling"/></g></svg>
          <div>
            <h2>Cooking up your basket…</h2>
            <p>${run.autopilot
              ? `Autopilot is on: if the basket fits ${budget}, the agent buys it straight away.`
              : `Planning the list, searching real catalogs and ranking options. Nothing is bought until you approve.`}</p>
          </div>
        </div>
        <div class="skel-grid">${Array.from({ length: 4 }, () => `<div class="skel"><div class="shim img"></div><div class="lines"><div class="shim"></div><div class="shim"></div><div class="shim"></div></div></div>`).join("")}</div>
      </section>`;
  }

  // ---------- Item cards (review + read-only) ----------
  const sel = p => p.opts[p.sel];
  const lineCents = p => cents(sel(p).unit_price) * (p.quantity || 1);

  function face(p, readonly) {
    const o = sel(p);
    const q = p.quantity || 1;
    return `
      <div class="item-media">
        ${pic(o.image_url, o.name, "")}
        ${p.priority ? `<span class="prio p${Number(p.priority) || 0}">${esc(prioLabel(p.priority))}</span>` : ""}
        ${readonly ? "" : `<span class="gone" aria-hidden="true"><span>Removed</span></span>`}
      </div>
      <div class="item-body">
        <span class="item-need">For: ${esc(p.need)}</span>
        <h4 class="item-name">${esc(o.name)}</h4>
        <span class="item-merchant">${esc(o.merchant)}</span>
        <div class="item-price">
          <span class="unit">${q > 1 ? `${q} × ` : ""}${priceHtml(o)}</span>
          <span class="line">${esc(fmt(lineCents(p)))}</span>
        </div>
        ${(o.reason || p.why) ? `<p class="why">${icon("spark")}<span>${esc(o.reason || p.why)}</span></p>` : ""}
      </div>`;
  }

  function optionsHtml(p) {
    const base = cents(p.opts[0].unit_price);
    return p.opts.map((o, i) => {
      const d = cents(o.unit_price) - base;
      return `
        <label class="opt">
          <input type="radio" name="option_${esc(p.key)}" value="${esc(o.product_id)}" data-idx="${i}" ${i === p.sel ? "checked" : ""}>
          ${pic(o.image_url, o.name, "thumb")}
          <span class="opt-text">
            <span class="opt-name">${esc(o.name)}</span>
            <span class="opt-meta">${esc(o.merchant)}${i === 0 ? " · Agent's pick" : ""}</span>
          </span>
          <span class="opt-price">
            ${o.original_price ? `${esc(money(o.original_price))}<span class="fx">≈ ${esc(money(o.unit_price))}</span>` : esc(money(o.unit_price))}
            ${i > 0 && d !== 0 ? `<span class="delta ${d > 0 ? "up" : "down"}">${d > 0 ? "+" : "−"}${esc(fmt(Math.abs(d)))}</span>` : ""}
          </span>
          <span class="tick">${icon("check")}</span>
        </label>`;
    }).join("");
  }

  function itemCard(p, readonly) {
    const el = document.createElement("article");
    el.className = "item";
    el.dataset.key = p.key;
    const domId = `alts-${String(p.key).replace(/[^\w-]/g, "_")}`;
    el.innerHTML = face(p, readonly) + (readonly ? "" : `
      <div class="item-foot">
        ${p.opts.length > 1
          ? `<button type="button" class="swap-btn" aria-expanded="false" aria-controls="${esc(domId)}" aria-label="Swap ${esc(p.need)}: ${p.opts.length - 1} alternative${p.opts.length > 2 ? "s" : ""}">${icon("swap")}Swap <span class="swap-n">${p.opts.length - 1}</span></button>`
          : `<span class="swap-none">Best match</span>`}
        <label class="keep-ctl">
          <span class="k-on">Keep</span><span class="k-off">Removed</span>
          <span class="switch"><input type="checkbox" name="keep[]" value="${esc(p.key)}" checked aria-label="Keep ${esc(p.need)} in the basket"><span class="track" aria-hidden="true"></span></span>
        </label>
      </div>
      <div class="alts" id="${esc(domId)}" role="radiogroup" aria-label="Options for ${esc(p.need)}" hidden>
        <p class="alts-title">Choose an option</p>
        ${optionsHtml(p)}
      </div>`);
    return el;
  }

  function refreshFace(el, p) {
    const tmp = document.createElement("div");
    tmp.innerHTML = face(p, false);
    el.querySelector(".item-media").replaceWith(tmp.querySelector(".item-media"));
    el.querySelector(".item-body").replaceWith(tmp.querySelector(".item-body"));
  }

  // Groups cards by the merchant of their currently selected option, in pick order.
  function layoutGroups(container, picks, cardFor, readonly) {
    const order = [];
    picks.forEach(p => { const m = sel(p).merchant || "Merchant"; if (!order.includes(m)) order.push(m); });
    const existing = new Map([...container.children].map(g => [g.dataset.merchant, g]));
    const groupsWanted = [];
    order.forEach(m => {
      let g = existing.get(m);
      if (!g) {
        g = document.createElement("section");
        g.className = "group";
        g.dataset.merchant = m;
        g.innerHTML = `<header class="group-head"><span class="mono" style="--h:${hue(m)}" aria-hidden="true">${esc(initial(m))}</span>
          <div><h3>${esc(m)}</h3><small class="gmeta"></small></div><span class="gsum"></span></header><div class="items"></div>`;
      }
      groupsWanted.push(g);
      existing.delete(m);
      const list = g.querySelector(".items");
      const mine = picks.filter(p => (sel(p).merchant || "Merchant") === m);
      syncChildren(list, mine.map(cardFor));
      const kept = mine.filter(p => readonly || p.keep);
      g.querySelector(".gmeta").textContent = kept.length
        ? `${kept.length} item${kept.length === 1 ? "" : "s"} · ships as one order`
        : "All removed · won't be ordered";
      g.querySelector(".gsum").textContent = kept.length ? fmt(kept.reduce((a, p) => a + lineCents(p), 0)) : "—";
    });
    existing.forEach(g => g.remove());
    syncChildren(container, groupsWanted);
  }

  // Reorders children only when needed so focused controls keep focus.
  function syncChildren(parent, wanted) {
    const same = parent.children.length === wanted.length && wanted.every((c, i) => parent.children[i] === c);
    if (!same) parent.replaceChildren(...wanted);
  }

  // ---------- Review & approve ----------
  let review = null;

  function renderReview(run) {
    if (!setMode("review")) return;
    const budgetC = cents(run.budget);
    const picks = run.basket.picks.map(p => ({ ...p, opts: [p.option, ...(p.alternatives || [])], sel: 0, keep: true }));
    const cards = new Map(picks.map(p => [p.key, itemCard(p, false)]));
    const enrolled = root.dataset.enrolled === "yes";
    const drops = run.basket.drops || [];
    const merchants0 = new Set(picks.map(p => p.option.merchant)).size;

    const form = document.createElement("form");
    form.method = "post";
    form.action = `/runs/${encodeURIComponent(id)}/purchase`;
    form.id = "review-form";
    form.className = "review";
    form.innerHTML = `
      <div class="section-head">
        <h2 class="section-title">Review your basket <span class="pill" id="h-count">${picks.length} item${picks.length === 1 ? "" : "s"} · ${merchants0} merchant${merchants0 === 1 ? "" : "s"}</span></h2>
        <span class="muted" style="font-size:14px">Swap to compare · toggle to remove</span>
      </div>
      ${enrolled ? "" : `<div class="banner" role="note">${icon("card")}<span><b>One-time:</b> connect the payment card before buying.</span><a href="/setup">Connect card →</a></div>`}
      <div class="groups" id="groups"></div>`;
    const ship = $("#ship-tpl").content.cloneNode(true);
    ship.querySelector('[name="country"]').value = root.dataset.country || "US";
    form.append(ship);
    stage.append(form);

    const budgetStr = esc(money(run.budget));
    slot.innerHTML = `
      <section class="glass summary" aria-labelledby="sum-h">
        <h2 id="sum-h">Order summary <span class="pill ok" id="s-fit">Fits budget</span></h2>
        <dl class="sumrows">
          <dt>Items (<span id="s-count">0</span>)</dt><dd id="s-sub">$0.00</dd>
          <dt>Merchants · shipments</dt><dd id="s-merch">0</dd>
          <dt>Shipping, tax &amp; FX</dt><dd class="muted" style="font-weight:600">Added at quote</dd>
          <dt class="grand">Budget · max charge</dt><dd class="grand">${budgetStr}</dd>
        </dl>
        <div class="meter" id="meter">
          <div class="meter-top"><span>Items use <b id="m-pct">0%</b> of budget</span><span id="m-of"></span></div>
          <div class="track-bar" role="img" id="m-bar" aria-label=""><span class="fill"></span></div>
          <p class="headroom">${icon("shield")}<span id="m-head"></span></p>
        </div>
        <div class="approve">
          <button type="submit" form="review-form" class="btn btn-jade approve-btn"><span class="spinner" aria-hidden="true"></span><span class="lbl"></span> <span class="amt"></span></button>
          <p class="blocker" hidden></p>
          <p class="confirm">${icon("shield")}<span>A single-use card loaded with ${budgetStr} will be issued, then frozen after checkout.</span></p>
        </div>
        <p class="note">Shipping, tax and FX fees are added when each merchant quotes. The total never exceeds your budget: if a quote would, the agent drops the lowest-priority item first.</p>
        ${drops.length ? `<div class="drops"><h3>Couldn't fit</h3><ul>${drops.map(d => `<li><b>${esc(d.need)}</b><span>${esc(DROP[d.reason] || humanize(d.reason))}</span></li>`).join("")}</ul></div>` : ""}
      </section>`;

    const bar = document.createElement("div");
    bar.className = "mbar";
    bar.id = "mbar";
    bar.innerHTML = `
      <div class="mmeter" aria-hidden="true"><span class="fill"></span></div>
      <button type="submit" form="review-form" class="btn btn-jade approve-btn"><span class="spinner" aria-hidden="true"></span><span class="lbl"></span> <span class="amt"></span></button>
      <p class="blocker" hidden></p>
      <p class="mfine"><b id="mb-head"></b> · A single-use card loaded with ${budgetStr} will be issued, then frozen after checkout.</p>`;
    root.append(bar);
    document.body.classList.add("has-mbar");

    const groups = $("#groups", form);
    review = { picks, cards, budgetC, enrolled, groups };
    layoutGroups(groups, picks, p => cards.get(p.key), false);
    updateTotals();

    form.addEventListener("change", e => {
      const t = e.target;
      const card = t.closest(".item");
      if (!card) return;
      const p = picks.find(x => x.key === card.dataset.key);
      if (t.name === "keep[]") {
        p.keep = t.checked;
        card.classList.toggle("off", !p.keep);
        if (!p.keep) { const alts = card.querySelector(".alts"); alts.hidden = true; card.classList.remove("open"); card.querySelector(".swap-btn")?.setAttribute("aria-expanded", "false"); }
        layoutGroups(groups, picks, x => cards.get(x.key), false);
      } else if (t.type === "radio") {
        const before = sel(p).merchant;
        p.sel = Number(t.dataset.idx);
        refreshFace(card, p);
        layoutGroups(groups, picks, x => cards.get(x.key), false);
        if (sel(p).merchant !== before) {
          t.focus({ preventScroll: true });
          card.scrollIntoView({ block: "nearest", behavior: matchMedia("(prefers-reduced-motion: reduce)").matches ? "auto" : "smooth" });
          card.classList.remove("moved"); void card.offsetWidth; card.classList.add("moved");
        }
      }
      updateTotals();
    });
    form.addEventListener("click", e => {
      const btn = e.target.closest(".swap-btn");
      if (!btn) return;
      const alts = document.getElementById(btn.getAttribute("aria-controls"));
      alts.hidden = !alts.hidden;
      btn.setAttribute("aria-expanded", String(!alts.hidden));
      btn.closest(".item").classList.toggle("open", !alts.hidden);
    });

    const shipBox = $("#ship", form);
    form.addEventListener("invalid", e => { if (shipBox.contains(e.target)) shipBox.open = true; }, true);
    document.querySelectorAll(".approve-btn").forEach(b => b.addEventListener("click", () => {
      if (!form.checkValidity()) shipBox.open = true;
    }));
    form.addEventListener("submit", e => {
      if (!review.enrolled || !picks.some(p => p.keep)) { e.preventDefault(); return; }
      const c = form.querySelector('[name="country"]');
      c.value = c.value.trim().toUpperCase();
      document.querySelectorAll(".approve-btn").forEach(b => {
        b.classList.add("is-loading");
        b.querySelector(".lbl").textContent = "Issuing card & buying…";
        b.querySelector(".amt").textContent = "";
        setTimeout(() => { b.disabled = true; }, 0);
      });
    });
    // Back/forward cache: restore buttons.
    window.addEventListener("pageshow", ev => { if (ev.persisted) location.reload(); });

    if (!$("#timeline-card").dataset.autoclosed) { $("#timeline-card").open = false; $("#timeline-card").dataset.autoclosed = "1"; }
  }

  function updateTotals() {
    const { picks, budgetC, enrolled } = review;
    const kept = picks.filter(p => p.keep);
    const sub = kept.reduce((a, p) => a + lineCents(p), 0);
    const merchants = new Set(kept.map(p => sel(p).merchant)).size;
    const pct = budgetC ? sub / budgetC : 0;
    const over = sub > budgetC;
    $("#s-count").textContent = kept.length;
    $("#h-count").textContent = `${kept.length === picks.length ? "" : `${kept.length} of `}${picks.length} item${picks.length === 1 ? "" : "s"} · ${merchants} merchant${merchants === 1 ? "" : "s"}`;
    $("#s-sub").textContent = fmt(sub);
    $("#s-merch").textContent = merchants;
    $("#m-pct").textContent = `${Math.round(pct * 100)}%`;
    $("#m-of").textContent = `${fmt(sub)} / ${fmt(budgetC)}`;
    $("#m-bar").setAttribute("aria-label", `Items use ${Math.round(pct * 100)}% of the ${fmt(budgetC)} budget`);
    $("#m-bar .fill").style.setProperty("--p", Math.min(pct, 1).toFixed(4));
    $("#meter").classList.toggle("over", over);
    const mh = $("#mb-head");
    if (mh) mh.textContent = over ? `Over by ${fmt(sub - budgetC)}, will trim` : `${fmt(budgetC - sub)} headroom`;
    const mm = $("#mbar .mmeter");
    if (mm) { mm.classList.toggle("over", over); mm.querySelector(".fill").style.setProperty("--p", Math.min(pct, 1).toFixed(4)); }
    $("#m-head").textContent = over
      ? `Over by ${fmt(sub - budgetC)}. The agent will drop lowest-priority items to fit.`
      : `${fmt(budgetC - sub)} headroom for shipping, tax & FX`;
    const fit = $("#s-fit");
    fit.className = `pill ${over ? "warn" : "ok"}`;
    fit.textContent = over ? "Will trim to fit" : "Fits budget";

    let blocker = "";
    if (!enrolled) blocker = 'Connect the payment card first: <a href="/setup">Card setup →</a>';
    else if (!kept.length) blocker = "Select at least one item to buy.";
    document.querySelectorAll(".approve-btn").forEach(b => {
      b.disabled = !!blocker;
      b.querySelector(".lbl").textContent = kept.length ? `Approve & buy ${kept.length} item${kept.length === 1 ? "" : "s"}` : "Nothing selected";
      b.querySelector(".amt").textContent = kept.length ? `· ${fmt(sub)}` : "";
      const bl = b.parentElement.querySelector(".blocker");
      bl.hidden = !blocker;
      bl.innerHTML = blocker;
    });
  }

  // ---------- Purchase / done ----------
  const OS = {
    QUOTING: ["Getting a quote", "live", 0], QUOTED: ["Quoted", "live", 1], HELD: ["Funds held", "live", 2],
    CHECKING_OUT: ["Checking out", "live", 2], PENDING: ["Processing", "live", 2], PROCESSING: ["Processing", "live", 2],
    AWAITING_APPROVAL: ["Needs your approval", "warn", 2], REQUIRES_ACTION: ["Needs your approval", "warn", 2], PENDING_APPROVAL: ["Needs your approval", "warn", 2],
    COMPLETED: ["Order placed", "ok", 4],
    FAILED: ["Failed", "bad", -1], DECLINED: ["Declined by card", "bad", -1], SKIPPED: ["Skipped", "warn", -1],
    CANCELLED: ["Cancelled", "bad", -1], CANCELED: ["Cancelled", "bad", -1], EXPIRED: ["Expired", "bad", -1], REJECTED: ["Rejected", "bad", -1]
  };
  const PILL = { live: "hot live", warn: "warn", ok: "ok", bad: "bad" };

  function orderHtml(o) {
    const st = String(o.status || "").toUpperCase();
    const [label, tone, step0] = OS[st] || [humanize(st) || "Working", "live", 2];
    let step = step0, errAt = -1;
    if (step0 === -1) { errAt = st === "SKIPPED" ? 0 : st === "DECLINED" ? 1 : o.order_id ? 3 : o.quoted_total ? 2 : 0; step = errAt; }
    const steps = ["Quote", "Hold", "Checkout", "Placed"].map((s, i) => {
      const c = i === errAt ? "error" : i < step ? "done" : i === step && step < 4 ? (tone === "warn" ? "active" : "active") : "";
      return `<li class="${c}">${s}</li>`;
    }).join("");
    const items = o.items || [];
    const fxCur = o.fx?.from || parse(o.quoted_total)?.cur;
    const approve = safeUrl(o.approval_url);
    const needsApproval = approve && !["COMPLETED", "FAILED", "DECLINED", "SKIPPED", "CANCELLED", "CANCELED", "EXPIRED"].includes(st);
    return `
      <article class="glass order s-${tone === "live" ? "live" : tone}">
        <header class="order-head">
          <span class="mono" style="--h:${hue(o.merchant)}" aria-hidden="true">${esc(initial(o.merchant))}</span>
          <div><h3>${esc(o.merchant)}</h3><small>${items.length} item${items.length === 1 ? "" : "s"}</small></div>
          <span class="pill ${PILL[tone]}"><span class="led" aria-hidden="true"></span>${esc(label)}</span>
        </header>
        <ol class="ostep" aria-label="Order progress">${steps}</ol>
        <ul class="oitems">${items.map(i => `<li><span>${esc(i.name)} <span class="q">×${Number(i.quantity) || 1}</span></span>
          <span>${i.original_price ? `${esc(money(i.original_price))}<span class="fx">≈ ${esc(money(i.unit_price))}</span>` : esc(money(i.unit_price))}</span></li>`).join("")}</ul>
        ${(o.dropped || []).length ? `<p class="odrop">Dropped to fit the budget: ${o.dropped.map(esc).join(", ")}</p>` : ""}
        ${o.quoted_total ? `<dl class="qt">
          <dt>Items</dt><dd>${esc(money(o.subtotal))}</dd>
          <dt>Shipping</dt><dd>${esc(money(o.shipping))}</dd>
          <dt>Tax</dt><dd>${esc(money(o.tax))}</dd>
          <dt class="tot">Quoted total</dt><dd class="tot">${esc(money(o.quoted_total))}</dd>
          ${o.fx && o.charge_estimate ? `<dt>Held on card (USD)</dt><dd>${esc(money(o.charge_estimate))}</dd>` : ""}
        </dl>` : ""}
        ${o.fx ? `<p class="fxline">${icon("globe")}<span>1 ${esc(fxCur || o.fx.from)} = ${esc(o.fx.rate)} ${esc(o.fx.to || "USD")} · ${esc(o.fx.source)}${o.fx.as_of ? `, ${esc(o.fx.as_of)}` : ""} · +${(Number(o.fx.markup_bps) || 0) / 100}% card FX fee · +${(Number(o.fx.buffer_bps) || 0) / 100}% buffer</span></p>` : ""}
        ${needsApproval ? `<a class="btn" target="_blank" rel="noopener noreferrer" href="${esc(approve)}">Approve on Reap ${icon("arrow")}</a>` : ""}
        ${o.order_id ? `<p class="placed"><span class="pill ok">${icon("check", "")} ${esc(o.order_id)}</span><span>Charged <b>${esc(money(o.final_amount))}</b>${o.fx && o.final_native ? ` <span class="muted">(merchant charged ${esc(money(o.final_native))})</span>` : ""}</span></p>` : ""}
        ${o.error ? `<p class="oerr">${esc(o.error)}</p>` : ""}
      </article>`;
  }

  function cardHtml(run) {
    const c = run.card;
    const frozen = !!run.receipt?.frozen;
    return `
      <div class="vcard ${frozen ? "frozen" : ""}" id="vcard" role="img" aria-label="Prepaid virtual card ending ${esc(c.last4)}, loaded with ${esc(money(c.budget))}, ${frozen ? "frozen" : "active"}">
        <div class="vcard-top">
          <span class="vcard-brand"><svg aria-hidden="true"><use href="#dumpling"/></svg>Dumpling Bros</span>
          <span class="vcard-state"><span class="led"></span><span class="st">${frozen ? "Frozen" : "Active"}</span></span>
        </div>
        <div class="vcard-mid"><span class="vcard-chip"></span>${icon("nfc", "vcard-nfc")}</div>
        <div class="vcard-pan">•••• •••• •••• ${esc(c.last4)}</div>
        <div class="vcard-bottom">
          <div><small>Loaded</small><b>${esc(money(c.budget))}</b></div>
          <div><small>Type</small><b style="font-size:13px">Single-use</b></div>
          <span class="vcard-net">REAP</span>
        </div>
        <div class="frost" aria-hidden="true"></div>
        <div class="frost-badge" aria-hidden="true"><span>${icon("snow")} FROZEN</span></div>
      </div>`;
  }

  let cardFrozen = null;
  function renderCard(run, zone) {
    const budget = esc(money(run.budget));
    if (!run.card) {
      if (zone.dataset.state === "pending") return;
      zone.dataset.state = "pending";
      zone.innerHTML = `
        <div class="vcard pending"><span class="spinner" aria-hidden="true"></span><span>Issuing a single-use card<br>loaded with <b>${budget}</b>…</span></div>
        <div class="cardinfo"><h2>Issuing your card</h2><p>One prepaid Reap virtual card per request, loaded with exactly the budget. It physically can't be charged a cent more.</p></div>`;
      return;
    }
    const frozen = !!run.receipt?.frozen;
    if (zone.dataset.state !== "card") {
      zone.dataset.state = "card";
      zone.innerHTML = cardHtml({ ...run, receipt: { frozen: false } }) + `
        <div class="cardinfo">
          <h2 id="card-title">Prepaid card · Active</h2>
          <p id="card-copy">Loaded with exactly ${budget}. Locked to this request and frozen as soon as checkout finishes.</p>
          <div class="facts"><span class="pill">${icon("shield")} Max ${budget}</span><span class="pill">Single use</span><span class="pill ice">${icon("snow")} Auto-freeze</span></div>
          <div class="actions">
            <button type="button" class="btn btn-ghost" id="reveal">${icon("eye")} Reveal card</button>
            <span class="reveal-note" id="reveal-note" aria-live="polite"></span>
          </div>
        </div>`;
      $("#reveal", zone).addEventListener("click", reveal);
      cardFrozen = false;
    }
    if (frozen !== cardFrozen) {
      cardFrozen = frozen;
      const v = $("#vcard", zone);
      // Small delay so the frost transition is visible when it happens live.
      setTimeout(() => {
        v.classList.toggle("frozen", frozen);
        $(".st", v).textContent = frozen ? "Frozen" : "Active";
        v.setAttribute("aria-label", v.getAttribute("aria-label").replace(/(active|frozen)$/, frozen ? "frozen" : "active"));
        $("#card-title", zone).textContent = frozen ? "Prepaid card · Frozen ❄" : "Prepaid card · Active";
        $("#card-copy", zone).textContent = frozen
          ? "Checkout finished, so the card was frozen. Any unspent balance can never be charged."
          : `Loaded with exactly ${money(run.budget)}. Locked to this request and frozen as soon as checkout finishes.`;
      }, 150);
    }
  }

  function receiptHtml(run) {
    const r = run.receipt;
    const spent = cents(r.spent), budget = cents(r.budget) || cents(run.budget);
    const ok = r.completed > 0;
    const confetti = ok && !reduced ? `<div class="confetti" aria-hidden="true">${Array.from({ length: 28 }, (_, i) => {
      const colors = ["var(--accent)", "var(--accent-2)", "var(--jade-2)", "var(--ice)", "var(--amber)"];
      return `<i style="left:${(i * 37) % 100}%;background:${colors[i % 5]};animation-delay:${((i * 53) % 900) / 1000}s"></i>`;
    }).join("")}</div>` : "";
    return `
      <section class="glass receipt ${ok ? "win" : ""}" aria-labelledby="r-h" tabindex="-1" id="receipt">
        ${confetti}
        <div class="ring">
          <svg viewBox="0 0 120 120" aria-hidden="true"><circle class="bg" cx="60" cy="60" r="54"/><circle class="fg" id="ring-fg" cx="60" cy="60" r="54"/></svg>
          <div class="ring-label"><b>${esc(money(r.spent))}</b><small>of ${esc(money(r.budget))}</small></div>
        </div>
        <h2 id="r-h">${ok ? `Bought it. ${esc(money(r.spent))} of ${esc(money(r.budget))}` : "No orders went through"}</h2>
        <p class="sub">${Number(r.completed) || 0} of ${Number(r.orders) || 0} order${r.orders === 1 ? "" : "s"} placed. ${esc(money(r.unspent))} never left the card${r.frozen ? ", which is now frozen and can't be charged again" : ""}.</p>
        <div class="rgrid">
          <div class="ok"><small>Spent</small><b>${esc(money(r.spent))}</b></div>
          <div><small>Unspent</small><b>${esc(money(r.unspent))}</b></div>
          <div><small>Orders placed</small><b>${Number(r.completed) || 0} / ${Number(r.orders) || 0}</b></div>
          <div class="${r.frozen ? "ice" : ""}"><small>Card</small><b>${r.frozen ? "Frozen ❄" : "Not frozen"}</b></div>
        </div>
        ${(r.anomalies || []).length ? `<div class="banner bad anoms" role="alert">${icon("alert")}<span>${r.anomalies.map(esc).join("<br>")}</span></div>` : ""}
        <div class="actions">
          <a class="btn" href="/">Shop for something else ${icon("arrow")}</a>
          <a class="btn btn-ghost" href="/orders">View orders</a>
        </div>
      </section>`;
    // spent/budget drives the ring after insertion
  }

  const sig = new Map();
  function patch(container, key, html, where = "append") {
    let el = container.querySelector(`[data-k="${CSS.escape(key)}"]`);
    if (el && sig.get(key) === html) return el;
    sig.set(key, html);
    const tmp = document.createElement("div");
    tmp.innerHTML = html.trim();
    const node = tmp.firstElementChild;
    node.dataset.k = key;
    if (el) el.replaceWith(node); else container[where](node);
    return node;
  }

  function renderBasketReadonly(run, container) {
    if (!run.basket?.picks?.length) return;
    const key = run.basket.picks.map(p => `${p.key}:${p.option.product_id}`).join("|");
    if (container.dataset.sig === key) return;
    container.dataset.sig = key;
    const picks = run.basket.picks.map(p => ({ ...p, opts: [p.option], sel: 0, keep: true }));
    const merchants = new Set(picks.map(p => p.option.merchant)).size;
    container.innerHTML = `
      <div class="section-head"><h2 class="section-title">In this basket <span class="pill">${picks.length} item${picks.length === 1 ? "" : "s"} · ${merchants} merchant${merchants === 1 ? "" : "s"}</span></h2>
        <span class="muted" style="font-size:14px">Items ${esc(money(run.basket.total))} of ${esc(money(run.budget))}</span></div>
      <div class="groups ro"></div>
      ${(run.basket.drops || []).length ? `<div class="drops" style="margin-top:14px"><h3>Couldn't fit</h3><ul>${run.basket.drops.map(d => `<li><b>${esc(d.need)}</b><span>${esc(DROP[d.reason] || humanize(d.reason))}</span></li>`).join("")}</ul></div>` : ""}`;
    layoutGroups($(".groups", container), picks, p => itemCard(p, true), true);
  }

  function renderPurchase(run) {
    if (setMode("purchase")) {
      stage.innerHTML = `
        <div id="p-fail"></div>
        <div id="p-receipt"></div>
        <section class="glass cardzone" id="p-card" aria-label="Prepaid card"></section>
        <section id="p-orders-wrap" hidden><div class="section-head"><h2 class="section-title">Checkout · per merchant</h2></div><div class="orders" id="p-orders"></div></section>
        <section id="p-basket"></section>`;
      $("#timeline-card").open = true;
    }
    if (run.status === "failed") {
      $("#p-fail").innerHTML = failHtml(run);
      $("#p-card").hidden = !run.card;
    }
    if (run.status !== "failed" || run.card) renderCard(run, $("#p-card"));
    const orders = run.orders || [];
    $("#p-orders-wrap").hidden = !orders.length;
    orders.forEach(o => patch($("#p-orders"), `o:${o.merchant}`, orderHtml(o)));
    if (run.receipt && !$("#receipt")) {
      $("#p-receipt").innerHTML = receiptHtml(run);
      const r = run.receipt;
      const ratio = Math.max(0, Math.min(1, cents(r.spent) / (cents(r.budget) || 1)));
      requestAnimationFrame(() => requestAnimationFrame(() => { $("#ring-fg").style.strokeDashoffset = String(339.3 * (1 - ratio)); }));
      if (run.status === "done") $("#receipt").scrollIntoView({ behavior: reduced ? "auto" : "smooth", block: "start" });
    }
    renderBasketReadonly(run, $("#p-basket"));
  }

  const failHtml = run => `
    <section class="glass failbox" role="alert">
      <h2>${icon("alert", "")} The run stopped</h2>
      <p>${esc(run.error || "Something went wrong.")}</p>
      ${run.card ? `<p class="muted">The prepaid card is ${run.receipt?.frozen ? "frozen" : "being frozen"}, so nothing more can be charged.</p>` : `<p class="muted">No card was issued and nothing was charged.</p>`}
      <a class="btn" href="/">Try again ${icon("arrow")}</a>
    </section>`;

  function renderFailed(run) {
    if (run.card || (run.orders || []).length) return renderPurchase(run);
    if (!setMode("failed")) return;
    stage.innerHTML = failHtml(run) + `<section id="p-basket"></section>`;
    renderBasketReadonly(run, $("#p-basket"));
  }

  function renderEmpty(run) {
    if (!setMode("empty")) return;
    stage.innerHTML = `
      <section class="glass failbox">
        <h2>Nothing fit this time</h2>
        <p>The agent couldn't find options within ${esc(money(run.budget))}${(run.basket?.drops || []).length ? `: ${run.basket.drops.map(d => esc(d.need)).join(", ")}` : ""}.</p>
        <a class="btn" href="/">Try a different request ${icon("arrow")}</a>
      </section>`;
  }

  async function reveal() {
    const btn = $("#reveal");
    const note = $("#reveal-note");
    const win = window.open("", "_blank"); // opened synchronously so popup blockers allow it
    btn.disabled = true;
    note.textContent = "Fetching a secure link…";
    try {
      const res = await fetch(`/runs/${encodeURIComponent(id)}/reveal`, { method: "POST" });
      if (!res.ok) throw new Error((await res.text()) || `HTTP ${res.status}`);
      const { url } = await res.json();
      if (!safeUrl(url)) throw new Error("No reveal link returned");
      if (win) { win.opener = null; win.location.href = url; note.textContent = "Opened in a new tab."; }
      else {
        const a = Object.assign(document.createElement("a"), { href: url, target: "_blank", rel: "noopener noreferrer", textContent: "Open card details ↗" });
        note.replaceChildren(a);
      }
    } catch (e) {
      win?.close();
      note.textContent = `Couldn't reveal: ${e.message}`;
    } finally {
      btn.disabled = false;
    }
  }

  function render(run) {
    run.log ||= []; run.orders ||= [];
    renderHeader(run);
    renderLog(run);
    const reviewing = run.status === "awaiting_review";
    if (run.status === "planning") renderPlanning(run);
    else if (reviewing && run.basket?.picks?.length) renderReview(run);
    else if (reviewing) renderEmpty(run);
    else if (run.status === "failed") renderFailed(run);
    else renderPurchase(run);
    return !["done", "failed"].includes(run.status);
  }

  async function tick() {
    try {
      const res = await fetch(`/runs/${encodeURIComponent(id)}.json`, { headers: { accept: "application/json" } });
      if (res.ok && !render(await res.json())) return;
    } catch (e) { /* keep polling */ }
    setTimeout(tick, 1500);
  }
  tick();
})();
