// @ts-check
import { api, el, errorMessage } from "./api.js";

const $ = (/** @type {string} */ id) => /** @type {HTMLElement} */ (document.getElementById(id));
const picker = /** @type {HTMLSelectElement} */ ($("set-picker"));
const status = $("status");

/** @type {string | null} */
let filterCategory = null;
/** @type {string | null} */
let cursor = null;

function fail(/** @type {{status:number, body:any}} */ res) {
  status.textContent = errorMessage(res);
}

async function loadSets() {
  const res = await api("GET", "/v1/category-sets");
  if (res.status !== 200) return fail(res);
  picker.replaceChildren(
    ...res.body.map((/** @type {any} */ s) => el("option", { value: s.id }, [s.name])),
  );
  await loadCounts();
}

async function loadCounts() {
  const res = await api("GET", `/v1/category-sets/${picker.value}`);
  if (res.status !== 200) return fail(res);
  $("counts").replaceChildren(
    ...res.body.categories.map((/** @type {any} */ c) => {
      const show = el("button", { type: "button", class: "secondary" }, ["Show"]);
      show.addEventListener("click", () => {
        filterCategory = c.id;
        $("list-title").textContent = `Examples in “${c.path}”`;
        loadExamples(true);
      });
      const clear = el("button", { type: "button", class: "danger" }, ["Delete examples"]);
      clear.addEventListener("click", async () => {
        if (!confirm(`Delete all ${c.exampleCount} learned examples of “${c.path}”?`)) return;
        const r = await api("DELETE", `/v1/categories/${c.id}/learning-examples`);
        if (r.status !== 204) return fail(r);
        loadCounts();
        loadExamples(true);
      });
      return el("tr", {}, [
        el("td", {}, [c.path]),
        el("td", {}, [String(c.exampleCount)]),
        el("td", {}, [el("div", { class: "row" }, [show, clear])]),
      ]);
    }),
  );
}

async function loadExamples(reset = false) {
  if (reset) {
    cursor = null;
    $("examples").replaceChildren();
  }
  const q = new URLSearchParams({ limit: "25" });
  if (filterCategory) q.set("categoryId", filterCategory);
  if (cursor) q.set("cursor", cursor);
  const res = await api("GET", `/v1/learning-examples?${q}`);
  if (res.status !== 200) return fail(res);
  for (const e of res.body.items) {
    const del = el("button", { type: "button", class: "danger" }, ["Delete"]);
    const row = el("tr", {}, [
      el("td", {}, [
        el("strong", {}, [e.subject || "(no subject)"]),
        el("br"),
        el("span", { class: "muted" }, [e.sender]),
        el("br"),
        e.snippet.slice(0, 160),
      ]),
      el("td", {}, [e.categoryPath, el("br"), el("span", { class: "muted" }, [e.outcome])]),
      el("td", {}, [del]),
    ]);
    del.addEventListener("click", async () => {
      const r = await api("DELETE", `/v1/learning-examples/${e.id}`);
      if (r.status !== 204) return fail(r);
      row.remove();
      loadCounts();
    });
    $("examples").append(row);
  }
  cursor = res.body.nextCursor;
  $("more").hidden = !cursor;
}

picker.addEventListener("change", () => {
  filterCategory = null;
  $("list-title").textContent = "Examples";
  loadCounts();
  loadExamples(true);
});
$("more").addEventListener("click", () => loadExamples());

$("delete-all").addEventListener("click", async () => {
  const typed = /** @type {HTMLInputElement} */ ($("confirm-text")).value;
  if (typed !== "DELETE ALL") {
    status.textContent = "Type DELETE ALL exactly to confirm.";
    return;
  }
  const res = await api("DELETE", "/v1/me/data", { confirm: typed });
  if (res.status !== 204) return fail(res);
  status.textContent = "All your data was deleted.";
  /** @type {HTMLInputElement} */ ($("confirm-text")).value = "";
  filterCategory = null;
  loadSets();
  loadExamples(true);
});

loadSets();
loadExamples(true);
