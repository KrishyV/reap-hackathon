(() => {
  const form = document.getElementById("composer");
  if (!form) return;
  const goal = form.querySelector("#goal");
  const count = form.querySelector("#goal-count");
  const budget = form.querySelector("#budget");
  const label = form.querySelector("#go-label");
  const go = form.querySelector("#go");
  const budgetChips = [...form.querySelectorAll("[data-budget]")];
  const goalChips = [...form.querySelectorAll("[data-goal]")];

  const syncCount = () => { count.textContent = `${goal.value.length}/500`; };
  const syncBudget = () => {
    const v = budget.value.trim();
    let preset = false;
    budgetChips.forEach(c => { const on = c.dataset.budget === v; preset ||= on; c.setAttribute("aria-pressed", on); });
    budget.closest(".money-input").classList.toggle("is-set", !preset && v !== "");
    const n = Number(v);
    label.textContent = v && Number.isFinite(n) && n > 0
      ? `Find it for $${n.toLocaleString("en-US", { maximumFractionDigits: 2 })}` : "Find it";
  };
  const syncGoalChips = () => goalChips.forEach(c => c.setAttribute("aria-pressed", c.dataset.goal === goal.value));

  goalChips.forEach(c => c.addEventListener("click", () => {
    goal.value = c.dataset.goal; syncCount(); syncGoalChips();
    goal.focus({ preventScroll: true });
    goal.setSelectionRange(goal.value.length, goal.value.length);
  }));
  budgetChips.forEach(c => c.addEventListener("click", () => { budget.value = c.dataset.budget; syncBudget(); }));
  budget.addEventListener("input", syncBudget);
  goal.addEventListener("input", () => { syncCount(); syncGoalChips(); });
  goal.addEventListener("keydown", e => { if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) form.requestSubmit(); });

  const shipBtn = form.querySelector("#ship-change");
  const shipEdit = form.querySelector("#ship-edit");
  const shipView = form.querySelector("#ship-view");
  const ship = form.querySelector("#ship_country");
  const flag = cc => /^[A-Z]{2}$/.test(cc) ? String.fromCodePoint(...[...cc].map(c => c.codePointAt(0) + 127397)) : "🌐";
  shipBtn.addEventListener("click", () => {
    const open = shipEdit.hidden;
    shipEdit.hidden = !open; shipView.hidden = open;
    shipBtn.textContent = open ? "done" : "change";
    shipBtn.setAttribute("aria-expanded", open);
    if (open) { ship.focus(); ship.select(); }
  });
  ship.addEventListener("input", () => {
    const cc = ship.value.toUpperCase();
    shipView.replaceChildren(Object.assign(document.createElement("span"), { className: "flag", textContent: flag(cc) }), ` ${cc}`);
  });

  form.addEventListener("invalid", () => { if (!ship.checkValidity()) { shipEdit.hidden = false; shipView.hidden = true; } }, true);
  form.addEventListener("submit", () => {
    ship.value = ship.value.toUpperCase();
    go.classList.add("is-loading"); go.setAttribute("aria-busy", "true");
    label.textContent = "Sending the agent…";
  });
  form.addEventListener("db:submit-failed", () => { go.classList.remove("is-loading"); go.removeAttribute("aria-busy"); syncBudget(); });
  window.addEventListener("pageshow", () => { go.classList.remove("is-loading"); go.removeAttribute("aria-busy"); syncBudget(); });
  syncCount(); syncBudget();
})();
