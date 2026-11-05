// @ts-check
import { api, el, errorMessage } from "./api.js";

const $ = (/** @type {string} */ id) => /** @type {HTMLElement} */ (document.getElementById(id));
const picker = /** @type {HTMLSelectElement} */ ($("sets-picker"));
const status = $("sets-status");

/** @type {any} */
let current = null;

function report(/** @type {{status:number, body:any}} */ res, okStatus = [200, 201, 204]) {
  if (okStatus.includes(res.status)) {
    status.textContent = "";
    return true;
  }
  status.textContent = errorMessage(res);
  return false;
}

async function loadSets(selectId = picker.value) {
  const res = await api("GET", "/v1/category-sets");
  if (!report(res)) return;
  picker.replaceChildren(
    ...res.body.map((/** @type {any} */ s) =>
      el("option", { value: s.id }, [
        `${s.name}${s.isDefault ? " (default)" : ""} · ${s.categoryCount}`,
      ]),
    ),
  );
  if (selectId && res.body.some((/** @type {any} */ s) => s.id === selectId))
    picker.value = selectId;
  await loadSet();
}

async function loadSet() {
  if (!picker.value) return;
  const res = await api("GET", `/v1/category-sets/${picker.value}`);
  if (!report(res)) return;
  current = res.body;
  $("set-title").textContent = `Categories in “${current.name}”`;
  /** @type {HTMLButtonElement} */ ($("delete-set")).disabled = current.isDefault;
  renderTree();
}

function categoryRow(/** @type {any} */ c) {
  const label = el("span", { class: "grow" }, [
    `${c.path.split("/").at(-1)}  `,
    el("span", { class: "muted" }, [`${c.exampleCount} examples`]),
  ]);
  const rename = el("button", { type: "button", class: "secondary" }, ["Rename"]);
  rename.addEventListener("click", async () => {
    const name = prompt("New name", c.path.split("/").at(-1));
    if (!name) return;
    if (report(await api("PATCH", `/v1/categories/${c.id}`, { name })))
      document.addEventListener("viewshown", (ev) => {
        if (/** @type {CustomEvent} */ (ev).detail === "sets") loadSets();
      });

    loadSets();
  });
  const tops = current.categories.filter(
    (/** @type {any} */ x) => x.parentId === null && x.id !== c.id,
  );
  const move = el("select", { "aria-label": "Move under" }, [
    el("option", { value: "" }, ["(top level)"]),
    ...tops.map((/** @type {any} */ t) => el("option", { value: t.id }, [t.path])),
  ]);
  /** @type {HTMLSelectElement} */ (move).value = c.parentId ?? "";
  move.addEventListener("change", async () => {
    const parentId = /** @type {HTMLSelectElement} */ (move).value || null;
    report(await api("PATCH", `/v1/categories/${c.id}`, { parentId }));
    document.addEventListener("viewshown", (ev) => {
      if (/** @type {CustomEvent} */ (ev).detail === "sets") loadSets();
    });

    loadSets();
  });
  const del = el("button", { type: "button", class: "danger" }, ["Delete"]);
  del.addEventListener("click", async () => {
    const children = current.categories.filter((/** @type {any} */ x) => x.parentId === c.id);
    const msg = children.length
      ? `Delete “${c.path}”, its ${children.length} subcategories and everything learned for them?`
      : `Delete “${c.path}” and everything learned for it?`;
    if (!confirm(msg)) return;
    const q = children.length ? "?cascade=true" : "";
    if (report(await api("DELETE", `/v1/categories/${c.id}${q}`)))
      document.addEventListener("viewshown", (ev) => {
        if (/** @type {CustomEvent} */ (ev).detail === "sets") loadSets();
      });

    loadSets();
  });
  return el("div", { class: "row" }, [label, move, rename, del]);
}

function renderTree() {
  const tops = current.categories.filter((/** @type {any} */ c) => c.parentId === null);
  $("tree").replaceChildren(
    ...tops.map((/** @type {any} */ t) => {
      const kids = current.categories.filter((/** @type {any} */ c) => c.parentId === t.id);
      return el("li", {}, [
        categoryRow(t),
        el(
          "ul",
          {},
          kids.map((/** @type {any} */ k) => el("li", {}, [categoryRow(k)])),
        ),
      ]);
    }),
  );
}

picker.addEventListener("change", loadSet);

$("rename-set").addEventListener("click", async () => {
  if (!current) return;
  const name = prompt("New set name", current.name);
  if (name && report(await api("PATCH", `/v1/category-sets/${current.id}`, { name })))
    loadSets(current.id);
});

$("delete-set").addEventListener("click", async () => {
  if (!current || current.isDefault) return;
  if (!confirm(`Delete the set “${current.name}”, its categories and everything learned for them?`))
    return;
  if (report(await api("DELETE", `/v1/category-sets/${current.id}`))) loadSets("");
});

$("new-set").addEventListener("submit", async (ev) => {
  ev.preventDefault();
  const form = /** @type {HTMLFormElement} */ (ev.target);
  const data = new FormData(form);
  const categories = String(data.get("categories") ?? "")
    .split("\n")
    .map((s) => s.trim())
    .filter(Boolean);
  const res = await api("POST", "/v1/category-sets", {
    name: String(data.get("name")),
    categories,
  });
  if (report(res)) {
    form.reset();
    loadSets(res.body.id);
  }
});

$("add-category").addEventListener("submit", async (ev) => {
  ev.preventDefault();
  const form = /** @type {HTMLFormElement} */ (ev.target);
  const path = String(new FormData(form).get("path") ?? "").trim();
  if (!current || !path) return;
  if (report(await api("POST", `/v1/category-sets/${current.id}/categories`, { path }))) {
    form.reset();
    loadSets(current.id);
  }
});

document.addEventListener("viewshown", (ev) => {
  if (/** @type {CustomEvent} */ (ev).detail === "sets") loadSets();
});

loadSets();
