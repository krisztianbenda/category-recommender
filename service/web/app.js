// @ts-check
// Suggestion screen. The email stays in page memory only (no localStorage), so feedback can
// re-send it for the server's content-hash check (research R7).
import { api, el, errorMessage } from "./api.js";

const $ = (/** @type {string} */ id) => /** @type {HTMLElement} */ (document.getElementById(id));
const form = /** @type {HTMLFormElement} */ ($("suggest-form"));
const setSelect = /** @type {HTMLSelectElement} */ (form.elements.namedItem("setId"));

/** @type {{ email: any, suggestion: any, candidates: string[] } | null} */
let current = null;

function source() {
  return /** @type {RadioNodeList} */ (form.elements.namedItem("source")).value;
}

function syncSource() {
  $("list-field").hidden = source() !== "list";
  $("set-field").hidden = source() !== "set";
}
form.addEventListener("change", syncSource);

async function loadSets() {
  const res = await api("GET", "/v1/category-sets");
  if (res.status !== 200) return;
  const selected = setSelect.value;
  setSelect.replaceChildren(
    ...res.body.map((/** @type {any} */ s) =>
      el("option", { value: s.id }, [`${s.name} (${s.categoryCount})`]),
    ),
  );
  if (res.body.some((/** @type {any} */ s) => s.id === selected)) setSelect.value = selected;
}

function field(/** @type {string} */ name) {
  return /** @type {HTMLInputElement} */ (form.elements.namedItem(name)).value;
}

form.addEventListener("submit", async (ev) => {
  ev.preventDefault();
  const button = /** @type {HTMLButtonElement} */ (form.querySelector("button[type=submit]"));
  $("form-error").textContent = "";
  const email = { from: field("from"), subject: field("subject"), body: field("body") };
  // Deleting is one of the decisions this page offers, so it may be suggested.
  /** @type {any} */
  const body = { email, allowDelete: true };
  let candidates = [];
  if (source() === "list") {
    candidates = field("categories")
      .split("\n")
      .map((s) => s.trim())
      .filter(Boolean);
    body.categories = candidates;
  } else {
    body.categorySetId = setSelect.value;
  }
  button.disabled = true;
  button.textContent = "Thinking…";
  try {
    const res = await api("POST", "/v1/suggestions", body);
    if (res.status !== 200) {
      $("form-error").textContent = errorMessage(res);
      return;
    }
    current = { email, suggestion: res.body, candidates };
    render();
  } finally {
    button.disabled = false;
    button.textContent = "Suggest";
  }
});

/** @param {any} s */
function similarText(s) {
  if (!s.similarPastDecisions) return "No similar past decisions yet.";
  const deleted = s.similarDeleted ? `, ${s.similarDeleted} of them deleted` : "";
  return `Based on ${s.similarPastDecisions} similar past decisions${deleted}.`;
}

function render() {
  if (!current) return;
  const s = current.suggestion;
  const toDelete = s.action === "delete";
  $("result").hidden = false;
  $("r-category").textContent = toDelete ? "Delete this email" : s.category;
  $("r-new").hidden = toDelete || !s.isNew;
  $("r-delete").hidden = !toDelete;
  const conf = $("r-confidence");
  conf.textContent = `${s.confidence} confidence`;
  conf.className = `badge ${s.confidence}`;
  $("r-reason").textContent = s.reason;
  $("r-truncated").hidden = !s.truncated;
  $("r-similar").textContent = similarText(s);
  // When deleting is suggested, the label it would otherwise go to leads the alternatives.
  $("new-category").hidden = toDelete || !s.isNew;
  if (s.isNew) {
    /** @type {HTMLInputElement} */ ($("new-name")).value = s.newCategory.name;
    $("new-parent").textContent = s.newCategory.parent ?? "(top level)";
  }
  $("confirm").textContent = toDelete ? "Delete" : s.isNew ? "Accept new category" : "Confirm";
  $("delete-instead").hidden = toDelete;
  const keep = toDelete
    ? [
        s.isNew
          ? {
              label: `New: ${s.category}`,
              decision: { decision: "accept_new", newCategory: s.newCategory },
            }
          : { label: s.category, decision: { decision: "choose", category: s.category } },
      ]
    : [];
  const others = s.runnersUp.map((/** @type {any} */ r) => ({
    label: r.path,
    decision: { decision: "choose", category: r.path },
  }));
  $("r-runners").replaceChildren(
    ...[...keep, ...others].map(({ label, decision }) => {
      const b = el("button", { type: "button", class: "secondary" }, [label]);
      b.addEventListener("click", () => sendFeedback(decision));
      return el("li", {}, [b]);
    }),
  );
  $("feedback-status").textContent = "";
}

$("delete-instead").addEventListener("click", () => sendFeedback({ decision: "delete" }));

$("confirm").addEventListener("click", () => {
  if (!current) return;
  const s = current.suggestion;
  if (s.action === "delete") {
    sendFeedback({ decision: "confirm" });
  } else if (s.isNew) {
    const name = /** @type {HTMLInputElement} */ ($("new-name")).value.trim();
    sendFeedback({ decision: "accept_new", newCategory: { parent: s.newCategory.parent, name } });
  } else {
    sendFeedback({ decision: "confirm" });
  }
});

/** @param {Record<string, unknown>} decision */
async function sendFeedback(decision) {
  if (!current) return;
  const status = $("feedback-status");
  const res = await api("POST", `/v1/suggestions/${current.suggestion.suggestionId}/feedback`, {
    email: current.email,
    ...decision,
  });
  if (res.status === 201) {
    status.textContent = "Saved. Thanks, this will improve future suggestions.";
    current = null;
    loadStats();
    loadSets();
  } else if (res.status === 410) {
    status.textContent = "Suggestion expired — please request again.";
  } else {
    status.textContent = errorMessage(res);
  }
}

async function loadStats() {
  const res = await api("GET", "/v1/stats/accuracy?window=100");
  if (res.status !== 200 || res.body.decisions === 0) return;
  const s = res.body;
  const pct = (/** @type {number | null} */ x) => (x === null ? "–" : `${Math.round(x * 100)}%`);
  $("stats-text").textContent =
    `Last ${s.decisions} decisions: ${pct(s.acceptedWithoutCorrection)} accepted without correction ` +
    `(high ${pct(s.byConfidence.high)}, medium ${pct(s.byConfidence.medium)}, low ${pct(s.byConfidence.low)}). ` +
    `New categories proposed: ${s.newProposals.made}, accepted: ${s.newProposals.accepted}. ` +
    `Deletions suggested: ${s.deleteSuggestions.made}, accepted: ${s.deleteSuggestions.accepted}.`;
}

document.addEventListener("viewshown", (ev) => {
  if (/** @type {CustomEvent} */ (ev).detail !== "suggest") return;
  loadSets();
  loadStats();
});

syncSource();
loadSets();
loadStats();
