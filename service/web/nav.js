// @ts-check
// Tab switching for the single page. Views are only hidden and shown, never reloaded, so anything
// typed survives a tab change. Each view's script refreshes its server data on "viewshown".
const VIEWS = ["suggest", "sets", "learned"];

function show() {
  const hash = location.hash.slice(1);
  const name = VIEWS.includes(hash) ? hash : "suggest";
  for (const v of VIEWS) {
    /** @type {HTMLElement} */ (document.getElementById(`view-${v}`)).hidden = v !== name;
  }
  for (const a of document.querySelectorAll("nav a")) {
    if (a.getAttribute("href") === `#${name}`) a.setAttribute("aria-current", "page");
    else a.removeAttribute("aria-current");
  }
  document.dispatchEvent(new CustomEvent("viewshown", { detail: name }));
}

window.addEventListener("hashchange", show);
show();
