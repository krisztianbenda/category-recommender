// @ts-check
// Tiny client for the catrec API. The browser presents the device certificate (mTLS).

/**
 * @param {string} method
 * @param {string} url
 * @param {unknown} [body]
 * @returns {Promise<{status: number, body: any}>}
 */
export async function api(method, url, body) {
  const res = await fetch(url, {
    method,
    headers: body === undefined ? {} : { "content-type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
    cache: "no-store",
  });
  const text = await res.text();
  return { status: res.status, body: text ? JSON.parse(text) : undefined };
}

/** @param {{body: any}} res */
export function errorMessage(res) {
  return res.body?.error?.message ?? `request failed (${res.status})`;
}

/**
 * Creates an element with text content only (never innerHTML: values may come from emails).
 * @param {string} tag
 * @param {Record<string, string>} [attrs]
 * @param {(Node | string)[]} [children]
 */
export function el(tag, attrs = {}, children = []) {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) node.setAttribute(k, v);
  for (const c of children) node.append(c);
  return node;
}
