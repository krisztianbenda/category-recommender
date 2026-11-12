// Runs the bridge against a fake Mail with synthetic data. Real Mail is covered by the app's
// --self-test-local mode.
import assert from "node:assert/strict";
import fs from "node:fs";
import { test } from "node:test";
import vm from "node:vm";

const source = fs.readFileSync(new URL("../Resources/mail-bridge.js", import.meta.url), "utf8");

class FakeMailbox {
  constructor(name, account, parent = null) {
    this._name = name;
    this._account = account;
    this._parent = parent;
    this._children = [];
    this.messagesList = [];
  }
  name() {
    return this._name;
  }
  account() {
    return this._account;
  }
  container() {
    return this._parent ?? this._account;
  }
  exists() {
    return true;
  }
  get mailboxes() {
    return mailboxCollection(this);
  }
  get messages() {
    // Like Mail: a specifier to call for the messages, which also answers length, byId and whose.
    const list = this.messagesList;
    const messages = () => list.slice();
    Object.defineProperty(messages, "length", { get: () => list.length });
    messages.byId = (id) => list.find((m) => m.id() === id);
    messages.whose = (condition) => whose(list, condition);
    return messages;
  }
}

/** Like Mail's `whose`: a specifier to call for the messages, or to ask for one property of all. */
function whose(list, condition) {
  const test = (actual, wanted) => {
    if (wanted && typeof wanted === "object") {
      if ("_contains" in wanted) return String(actual).toLowerCase().includes(String(wanted._contains).toLowerCase());
      if ("_beginsWith" in wanted) return String(actual).startsWith(wanted._beginsWith);
    }
    return actual === wanted;
  };
  const meets = (m, c) =>
    Object.entries(c).every(([k, v]) => (k === "_or" ? v.some((alternative) => meets(m, alternative)) : test(m[k](), v)));
  const matching = () => list.filter((m) => meets(m, condition));
  const specifier = () => matching();
  for (const property of ["sender", "subject", "messageId", "dateReceived"]) {
    specifier[property] = () => matching().map((m) => m[property]());
  }
  return specifier;
}

const missing = { exists: () => false, name: () => { throw new Error("gone"); } };

function mailboxCollection(owner) {
  const items = owner instanceof FakeAccount ? allMailboxes(owner) : owner._children;
  const collection = () => items;
  Object.defineProperty(collection, "name", { value: () => items.map((m) => m.name()) });
  collection.byName = (name) => items.find((m) => m.name() === name) ?? missing;
  withContainerNames(collection, items);
  collection.push = (m) => {
    if (m._name === owner._failCreate) throw new Error("cannot create");
    // Like Mail: a path as the name creates the mailbox under its parent.
    const account = owner.account?.() ?? owner;
    let parent = owner;
    const parts = m._name.split("/");
    for (const part of parts.slice(0, -1)) {
      parent = parent._children.find((c) => c.name() === part) ?? parent;
    }
    const parentMailbox = parent instanceof FakeMailbox ? parent : null;
    parent._children.push(new FakeMailbox(parts.at(-1), account, parentMailbox));
  };
  return new Proxy(collection, {
    get(target, prop) {
      if (typeof prop === "string" && /^\d+$/.test(prop)) return items[Number(prop)];
      return target[prop];
    },
  });
}

/** Like Mail: an account lists every mailbox, nested ones under their short name. */
function allMailboxes(owner) {
  const out = [];
  const walk = (m) => {
    for (const child of m._children) {
      if (!child._hidden) out.push(child);
      walk(child);
    }
  };
  walk(owner);
  return out;
}

/** Like Mail: asking every mailbox for its parent's name gives null at the top level. */
function withContainerNames(collection, items) {
  Object.defineProperty(collection, "container", {
    value: { name: () => items.map((m) => (m._parent ? m._parent.name() : null)) },
  });
}

class FakeAccount {
  constructor(name, { host = "imap.gmail.com", addresses = ["owner@gmail.com"], enabled = true } = {}) {
    this._name = name;
    this._host = host;
    this._addresses = addresses;
    this._enabled = enabled;
    this._children = [];
  }
  name() {
    return this._name;
  }
  id() {
    return "account-id";
  }
  serverName() {
    return this._host;
  }
  emailAddresses() {
    return this._addresses;
  }
  enabled() {
    return this._enabled;
  }
  get mailboxes() {
    return mailboxCollection(this);
  }
}

function fakeMessage(
  id,
  mailbox,
  { date = 1000, subject = "Sunday lunch", body = "See you at noon", messageId, sender = "Dad <dad@example.test>" } = {},
) {
  const message = {
    id: () => id,
    mailbox: () => mailbox,
    dateReceived: () => new Date(date),
    sender: () => sender,
    subject: () => subject,
    content: () => body,
    messageId: () => messageId ?? `mid-${id}`,
    toRecipients: () => [{ address: () => "owner@example.test", name: () => "Owner" }],
  };
  mailbox.messagesList.push(message);
  return message;
}

function setup() {
  const gmail = new FakeAccount("Google");
  const icloud = new FakeAccount("iCloud", { host: "imap.mail.me.example", addresses: ["me@icloud.example"] });
  const inbox = new FakeMailbox("INBOX", gmail);
  const family = new FakeMailbox("Family", gmail);
  const baby = new FakeMailbox("Baby", gmail, family);
  family._children.push(baby);
  const gadgets = new FakeMailbox("Gadgets", gmail);
  // Like Mail: the system folders' parent is not listed, and their names follow Gmail's language.
  const gmailParent = new FakeMailbox("[Gmail]", gmail);
  gmailParent._hidden = true;
  const allMail = new FakeMailbox("Összes levél", gmail, gmailParent);
  const trash = new FakeMailbox("Kuka", gmail, gmailParent);
  gmailParent._children.push(allMail, trash);
  gmail._children.push(inbox, family, gadgets, gmailParent);
  const calls = [];
  const selectedMailboxes = [];
  const accounts = [icloud, gmail];
  const accountsCollection = () => accounts;
  Object.defineProperty(accountsCollection, "name", { value: () => accounts.map((a) => a.name()) });
  accountsCollection.serverName = () => accounts.map((a) => a.serverName());
  accountsCollection.enabled = () => accounts.map((a) => a.enabled());
  accountsCollection.emailAddresses = () => accounts.map((a) => a.emailAddresses());
  accountsCollection.byName = (name) => accounts.find((a) => a.name() === name);
  const icloudTrash = new FakeMailbox("Deleted Messages", icloud);
  icloud._children.push(icloudTrash);
  const trashMailboxes = [icloudTrash, trash];
  const mail = {
    running: () => true,
    accounts: accountsCollection,
    // Mail's own Trash, with one mailbox per account.
    trashMailbox: { mailboxes: () => trashMailboxes },
    selection: () => [],
    Mailbox: ({ name }) => new FakeMailbox(name, null),
    move(message, { to }) {
      calls.push(["move", message.id(), to.name()]);
    },
    duplicate(message, { to }) {
      calls.push(["duplicate", message.id(), to.name()]);
    },
    delete() {
      throw Object.assign(new Error("AppleEvent handler failed."), { errorNumber: -10000 });
    },
    activate() {
      calls.push(["activate"]);
    },
    messageViewers: [{ selectedMailboxes: () => selectedMailboxes }],
  };
  // denied: the error number System Events gives, as when Accessibility (-1719) or Automation
  // (-1743) is not allowed.
  const menu = { titles: ["New Mailbox\u2026", "Delete Mailbox\u2026"], enabled: true, clicks: 0, denied: false };
  const systemEvents = {
    processes: {
      byName: () => {
        if (menu.denied) {
          const number = menu.denied === true ? -1719 : menu.denied;
          throw Object.assign(new Error("not allowed assistive access"), { errorNumber: number });
        }
        const entries = menu.titles.map(() => ({
          enabled: () => menu.enabled,
          click: () => {
            menu.clicks += 1;
            menu.onClick?.();
          },
        }));
        entries.name = () => menu.titles;
        return { menuBars: [{ menuBarItems: [{ menus: [{ menuItems: entries }] }] }] };
      },
    },
  };
  const script = { source: null, selects: null };
  const dollar = (x) => x;
  dollar.NSAppleScript = {
    alloc: {
      initWithSource: (text) => ({
        executeAndReturnError: () => {
          script.source = text;
          selectedMailboxes.length = 0;
          if (script.selects) selectedMailboxes.push(script.selects);
        },
      }),
    },
  };
  const context = vm.createContext({
    Application: (name) => (name === "System Events" ? systemEvents : mail),
    delay: () => {},
    ObjC: { import: () => {} },
    Ref: () => [],
    $: dollar,
    JSON,
    Math,
    Object,
    String,
    Error,
    Number,
    Map,
    Set,
    Date,
  });
  vm.runInContext(source, context);
  const call = (input) => JSON.parse(context.run([JSON.stringify(input)]));
  return {
    mail, gmail, icloud, inbox, family, baby, gadgets, allMail, trash, trashMailboxes, calls, call, menu, script,
    selectedMailboxes,
  };
}

test("selection reads the newest message and refers to all of them", () => {
  const { mail, inbox, call } = setup();
  const older = fakeMessage(1, inbox, { date: 1000, subject: "Older" });
  const newer = fakeMessage(2, inbox, { date: 2000, subject: "Newer" });
  mail.selection = () => [older, newer];
  const { selection, labels } = call({ command: "opening" }).result;
  assert.equal(selection.total, 2);
  assert.deepEqual(selection.messages.map((m) => m.id), [1, 2]);
  assert.equal(selection.messages[0].account, "Google");
  assert.equal(selection.latest.subject, "Newer");
  assert.deepEqual(selection.latest.to, ["Owner <owner@example.test>"]);
  assert.ok(labels.mailboxes.includes("Family/Baby"));
});

test("a Gmail email is filed from the copy in the Inbox, not from All Mail", () => {
  const { mail, inbox, allMail, call } = setup();
  const stored = fakeMessage(50, allMail, { messageId: "mid-shared" });
  fakeMessage(51, inbox, { messageId: "mid-shared" });
  mail.selection = () => [stored];
  const ref = call({ command: "opening" }).result.selection.messages[0];
  assert.deepEqual([ref.id, ref.mailbox], [51, "INBOX"]);
});

test("the copy in the mailbox being viewed wins over the Inbox", () => {
  const { mail, inbox, family, allMail, selectedMailboxes, call } = setup();
  const stored = fakeMessage(60, allMail, { messageId: "mid-viewed" });
  fakeMessage(61, inbox, { messageId: "mid-viewed" });
  fakeMessage(62, family, { messageId: "mid-viewed" });
  selectedMailboxes.push(family);
  mail.selection = () => [stored];
  const ref = call({ command: "opening" }).result.selection.messages[0];
  assert.deepEqual([ref.id, ref.mailbox], [62, "Family"]);
});

test("an email only in All Mail stays referenced there, so it only gets the label", () => {
  const { mail, allMail, call } = setup();
  const stored = fakeMessage(70, allMail, { messageId: "mid-archived" });
  mail.selection = () => [stored];
  const ref = call({ command: "opening" }).result.selection.messages[0];
  assert.deepEqual([ref.id, ref.mailbox], [70, "[Gmail]/Összes levél"]);
});

test("selection does not launch Mail", () => {
  const { mail, call } = setup();
  mail.running = () => false;
  mail.selection = () => assert.fail("must not touch Mail");
  assert.equal(call({ command: "opening" }).result.selection.running, false);
});

test("selection treats an error as nothing selected, unless Mail access is denied", () => {
  const { mail, call } = setup();
  mail.selection = () => {
    throw Object.assign(new Error("Can't get selection."), { errorNumber: -1728 });
  };
  assert.equal(call({ command: "opening" }).result.selection.total, 0);
  mail.selection = () => {
    throw new Error("Error: Not authorized to send Apple events to Mail. (-1743)");
  };
  const out = call({ command: "opening" });
  assert.equal(out.ok, false);
  assert.equal(out.error.number, -1743);
});

const accountKinds = (call) =>
  call({ command: "opening" }).result.accounts.map((a) => [a.name, a.kind]);

test("every enabled account is offered, with whether it has labels or folders", () => {
  const { gmail, call } = setup();
  assert.deepEqual(accountKinds(call), [
    ["iCloud", "folders"],
    ["Google", "gmail"],
  ]);
  gmail._enabled = false;
  assert.deepEqual(call({ command: "opening" }).result.accounts.map((a) => a.name), ["iCloud"]);
});

test("an account without a server name, like Exchange, is still offered", () => {
  const { mail, icloud, call } = setup();
  icloud.serverName = () => {
    throw new Error("no such property");
  };
  mail.accounts.serverName = () => {
    throw new Error("no such property");
  };
  assert.deepEqual(accountKinds(call), [
    ["iCloud", "folders"],
    ["Google", "gmail"],
  ]);
});

test("recognises Gmail by address when the host is not Gmail's", () => {
  const { icloud, call } = setup();
  icloud._addresses = ["owner@googlemail.com"];
  assert.deepEqual(call({ command: "opening" }).result.accounts.map((a) => a.kind), ["gmail", "gmail"]);
});

/** An Exchange-like account, whose own folders have names no list could know. */
function withFolders(context) {
  const { mail, icloud, trashMailboxes } = context;
  const inbox = new FakeMailbox("Beérkezett", icloud);
  const sent = new FakeMailbox("Elküldött", icloud);
  const bills = new FakeMailbox("Bills", icloud);
  const projects = new FakeMailbox("Projects", icloud, inbox);
  inbox._children.push(projects);
  icloud._children.push(inbox, sent, bills);
  mail.inbox = { mailboxes: () => [inbox, context.inbox] };
  mail.sentMailbox = { mailboxes: () => [sent] };
  return { inbox, sent, bills, projects, trash: trashMailboxes[0] };
}

test("a folder account's folders are read, with which of them are its own Inbox, Sent and Trash", () => {
  const context = setup();
  const { inbox } = withFolders(context);
  context.mail.selection = () => [fakeMessage(1, inbox)];
  const { result } = context.call({ command: "opening" });
  assert.deepEqual(result.labels, {
    mailboxes: ["Deleted Messages", "Beérkezett", "Beérkezett/Projects", "Elküldött", "Bills"],
    system: ["Beérkezett", "Elküldött", "Deleted Messages"],
    inbox: "Beérkezett",
  });
  assert.equal(result.selection.messages[0].inInbox, true);
  assert.deepEqual(context.call({ command: "labels", account: "iCloud" }).result, result.labels);
});

test("says whether each selected email is in its account's Inbox", () => {
  const context = setup();
  const { bills } = withFolders(context);
  context.mail.selection = () => [fakeMessage(1, bills), fakeMessage(2, context.inbox), fakeMessage(3, context.family)];
  const { messages } = context.call({ command: "opening" }).result.selection;
  assert.deepEqual(messages.map((m) => m.inInbox), [false, true, false]);
});

test("an email under On My Mac has no account, and gets no labels", () => {
  const { mail, call } = setup();
  const local = new FakeMailbox("Old stuff", null);
  local.account = () => {
    throw new Error("no account");
  };
  local.container = () => {
    throw new Error("no container");
  };
  mail.selection = () => [fakeMessage(1, local)];
  const { result } = call({ command: "opening" });
  assert.equal(result.selection.messages[0].account, "");
  assert.equal(result.labels, null);
});

test("in a folder account, filing moves the email, or copies it when asked to", () => {
  const context = setup();
  const { inbox } = withFolders(context);
  fakeMessage(1, inbox);
  fakeMessage(2, inbox);
  const { result } = context.call({
    command: "file",
    account: "iCloud",
    target: "Bills",
    items: [
      { id: 1, mailbox: "Beérkezett", mode: "move" },
      { id: 2, mailbox: "Beérkezett", mode: "copy" },
    ],
  });
  assert.equal(result.filed, 2);
  assert.deepEqual(context.calls, [
    ["move", 1, "Bills"],
    ["duplicate", 2, "Bills"],
  ]);
});

test("an account that names nested folders by their whole path gets the same paths", () => {
  const context = setup();
  const { bills, inbox } = withFolders(context);
  const year = new FakeMailbox("Bills/2026", context.icloud, bills);
  const month = new FakeMailbox("Bills/2026/May", context.icloud, year);
  year._children.push(month);
  bills._children.push(year);
  const flat = new FakeMailbox("Trips/Lisbon", context.icloud); // listed without a parent
  context.icloud._children.push(flat);
  const { mailboxes } = context.call({ command: "labels", account: "iCloud" }).result;
  assert.deepEqual(mailboxes.filter((m) => /Bills|Trips/.test(m)), [
    "Bills", "Bills/2026", "Bills/2026/May", "Trips/Lisbon",
  ]);
  fakeMessage(1, inbox);
  for (const target of ["Bills/2026/May", "Trips/Lisbon"]) {
    const out = context.call({
      command: "file", account: "iCloud", target, items: [{ id: 1, mailbox: "Beérkezett", mode: "move" }],
    });
    assert.equal(out.ok, true);
  }
  assert.deepEqual(context.calls, [["move", 1, "Bills/2026/May"], ["move", 1, "Trips/Lisbon"]]);
  assert.deepEqual(context.call({ command: "create", account: "iCloud", path: "Bills/2026" }).result, { created: false });
  context.mail.selection = () => [fakeMessage(2, month)];
  assert.equal(context.call({ command: "opening" }).result.selection.messages[0].mailbox, "Bills/2026/May");
});

test("a self-test step does not pass on a copy an earlier run left behind", () => {
  const context = setup();
  const { inbox } = withFolders(context);
  const message = fakeMessage(1, inbox, { messageId: "mid-a" });
  context.mail.selection = () => [message];
  context.call({ command: "create", account: "iCloud", path: "catrec-selftest-folder" });
  context.call({ command: "create", account: "iCloud", path: "catrec-selftest-folder/child" });
  const folder = context.icloud.mailboxes().find((m) => m.name() === "catrec-selftest-folder");
  const child = folder._children[0];
  child.messagesList.push({ ...message, id: () => 800 }); // left by an earlier run
  context.mail.duplicate = () => {}; // Mail does nothing this time
  const { result } = context.call({ command: "selftestAccount", stamp: 1 });
  assert.equal(result.steps.copyThroughFiling, "fail");
  assert.ok(!("moveThroughFiling" in result.steps));
});

test("recovery leaves a self-test copy alone when its original is in the Inbox", () => {
  const context = setup();
  const { inbox } = withFolders(context);
  const message = fakeMessage(1, inbox, { messageId: "mid-a" });
  context.mail.inbox = { mailboxes: () => [inbox] };
  const folder = new FakeMailbox("catrec-selftest-folder", context.icloud);
  context.icloud._children.push(folder);
  folder.messagesList.push({ ...message, id: () => 800 });
  const lost = fakeMessage(2, folder, { messageId: "mid-lost" });
  const moved = [];
  context.mail.move = (m, { to }) => {
    moved.push(m);
    folder.messagesList.splice(folder.messagesList.indexOf(m), 1);
    to.messagesList.push(m);
  };
  const { result } = context.call({ command: "selftestRecover" });
  const icloud = result.accounts[0];
  assert.deepEqual([icloud.moved, icloud.inInbox, icloud.left], [1, 1, 0]);
  assert.deepEqual(moved, [lost]);
  assert.equal(inbox.messagesList.filter((m) => m.messageId() === "mid-a").length, 1);
});

test("a move that Mail refuses as a command is done by setting the email's folder", () => {
  const context = setup();
  const { inbox, bills } = withFolders(context);
  const message = fakeMessage(1, inbox);
  context.mail.move = () => {
    throw Object.assign(new Error("AppleEvent handler failed."), { errorNumber: -10000 });
  };
  const out = context.call({
    command: "file", account: "iCloud", target: "Bills", items: [{ id: 1, mailbox: "Beérkezett", mode: "move" }],
  });
  assert.equal(out.ok, true);
  assert.equal(message.mailbox, bills);
});

test("the self-test of a folder account moves a copy, and never the owner's email", () => {
  const context = setup();
  const { inbox } = withFolders(context);
  const message = fakeMessage(1, inbox, { messageId: "mid-a" });
  context.mail.selection = () => [message];
  const moved = [];
  context.mail.duplicate = (m, { to }) => {
    to.messagesList.push({ ...m, id: () => 900 + to.messagesList.length });
  };
  context.mail.move = (m, { to }) => {
    moved.push(m);
    for (const box of context.icloud.mailboxes()) {
      const at = box.messagesList.indexOf(m);
      if (at >= 0) box.messagesList.splice(at, 1);
    }
    to.messagesList.push(m);
  };
  const { result } = context.call({ command: "selftestAccount", stamp: 1 });
  assert.deepEqual([...new Set(Object.values(result.steps))], ["pass"]);
  assert.ok("copyThroughFiling" in result.steps && "moveThroughFiling" in result.steps);
  assert.ok(!moved.includes(message));
  assert.deepEqual(inbox.messagesList, [message]);
});

test("a nested label whose parent's short name is not unique still gets its own path", () => {
  const { gmail, family, call } = setup();
  const otherFamily = new FakeMailbox("Family", gmail, new FakeMailbox("Old", gmail));
  gmail._children.push(otherFamily._parent);
  otherFamily._parent._children.push(otherFamily);
  const kids = new FakeMailbox("Kids", gmail, family);
  family._children.push(kids);
  const { mailboxes } = call({ command: "labels", account: "Google" }).result;
  assert.ok(mailboxes.includes("Family/Kids"));
  assert.ok(mailboxes.includes("Old/Family"));
  assert.ok(mailboxes.includes("Family"));
});

test("labels get full paths from their parents, as Mail lists nested ones flat", () => {
  const { call } = setup();
  const { result } = call({ command: "labels", account: "Google" });
  assert.deepEqual(result.mailboxes, [
    "INBOX", "Family", "Family/Baby", "Gadgets", "[Gmail]/Összes levél", "[Gmail]/Kuka",
  ]);
});

test("deep labels get their whole path", () => {
  const { gmail, call } = setup();
  const work = new FakeMailbox("Work", gmail);
  const alpha = new FakeMailbox("Alpha", gmail, work);
  const beta = new FakeMailbox("Beta", gmail, alpha);
  alpha._children.push(beta);
  work._children.push(alpha);
  gmail._children.push(work);
  const { result } = call({ command: "labels", account: "Google" });
  assert.ok(result.mailboxes.includes("Work/Alpha/Beta"));
  assert.ok(!result.mailboxes.includes("Beta"));
});

test("a mailbox from a message gets its full path", () => {
  const { mail, baby, call } = setup();
  mail.selection = () => [fakeMessage(7, baby)];
  assert.equal(call({ command: "opening" }).result.selection.messages[0].mailbox, "Family/Baby");
});

test("a message in a Gmail system folder reports the system path, in any language", () => {
  const { mail, allMail, call } = setup();
  mail.selection = () => [fakeMessage(8, allMail)];
  assert.equal(call({ command: "opening" }).result.selection.messages[0].mailbox, "[Gmail]/Összes levél");
});

test("filing from a system folder finds it although its parent is not listed", () => {
  const { allMail, calls, call } = setup();
  fakeMessage(8, allMail);
  const out = call({
    command: "file",
    account: "Google",
    target: "Gadgets",
    items: [{ id: 8, mailbox: "[Gmail]/Összes levél", mode: "copy" }],
  });
  assert.equal(out.result.filed, 1);
  assert.deepEqual(calls, [["duplicate", 8, "Gadgets"]]);
});

test("a top-level label is not confused with a nested one of the same short name", () => {
  const { gmail, family, calls, inbox, call } = setup();
  const nestedBills = new FakeMailbox("Bills", gmail, family);
  family._children.push(nestedBills);
  const topBills = new FakeMailbox("Bills", gmail);
  gmail._children.push(topBills);
  fakeMessage(1, inbox);
  const filed = (target) =>
    call({ command: "file", account: "Google", target, items: [{ id: 1, mailbox: "INBOX", mode: "move" }] });
  assert.equal(filed("Bills").ok, true);
  assert.equal(filed("Family/Bills").ok, true);
  assert.deepEqual(calls.map((c) => c[2]), ["Bills", "Bills"]);
  const labels = call({ command: "labels", account: "Google" }).result.mailboxes;
  assert.ok(labels.includes("Bills") && labels.includes("Family/Bills"));
});

test("file moves or copies per item and skips the target itself", () => {
  const { inbox, family, gadgets, calls, call } = setup();
  fakeMessage(1, inbox);
  fakeMessage(2, family);
  fakeMessage(3, gadgets);
  const { result } = call({
    command: "file",
    account: "Google",
    target: "Gadgets",
    items: [
      { id: 1, mailbox: "INBOX", mode: "move" },
      { id: 2, mailbox: "Family", mode: "copy" },
      { id: 3, mailbox: "Gadgets", mode: "move" },
    ],
  });
  assert.equal(result.filed, 2);
  // Mail's scripted move only adds the label in Gmail, so filing copies; archive is separate.
  assert.deepEqual(calls, [
    ["duplicate", 1, "Gadgets"],
    ["duplicate", 2, "Gadgets"],
  ]);
});

test("filing into a missing label fails without touching the message", () => {
  const { inbox, calls, call } = setup();
  fakeMessage(1, inbox);
  const out = call({
    command: "file",
    account: "Google",
    target: "Nope",
    items: [{ id: 1, mailbox: "INBOX", mode: "move" }],
  });
  assert.equal(out.ok, false);
  assert.equal(out.error.number, -1728);
  assert.deepEqual(calls, []);
});

test("create reports an existing label instead of duplicating it", () => {
  const { gmail, call } = setup();
  const before = gmail._children.length;
  assert.equal(call({ command: "create", account: "Google", path: "Family" }).result.created, false);
  assert.equal(gmail._children.length, before);
});

test("create makes a label and verifies it", () => {
  const { call } = setup();
  assert.equal(call({ command: "create", account: "Google", path: "Trips" }).result.created, true);
  assert.ok(call({ command: "labels", account: "Google" }).result.mailboxes.includes("Trips"));
});

test("deleting shows the label in Mail, clicks Mail's own command, and leaves the confirmation to Mail", () => {
  const { gadgets, menu, script, gmail, call } = setup();
  script.selects = gadgets;
  const out = call({ command: "deleteBegin", account: "Google", path: "Gadgets", titles: ["Delete Mailbox\u2026"] });
  assert.equal(out.result.automatic, true);
  assert.equal(menu.clicks, 1);
  assert.match(script.source, /set selected mailboxes of message viewer 1 to \{mailbox "Gadgets" of account "Google"\}/);
  assert.ok(gmail._children.includes(gadgets), "Mail's own dialog decides, so nothing is gone yet");
});

test("deleting never clicks if Mail shows a different mailbox", () => {
  const { family, menu, script, call } = setup();
  script.selects = family;
  const out = call({ command: "deleteBegin", account: "Google", path: "Gadgets", titles: ["Delete Mailbox\u2026"] });
  assert.equal(out.ok, false);
  assert.match(out.error.message, /nothing was deleted/);
  assert.equal(menu.clicks, 0);
});

test("deleting falls back to asking the owner when the click is not possible, and says why", () => {
  const { gadgets, menu, script, call } = setup();
  script.selects = gadgets;
  const begin = (titles = ["Delete Mailbox\u2026"]) =>
    call({ command: "deleteBegin", account: "Google", path: "Gadgets", titles }).result;
  menu.denied = true;
  assert.deepEqual(begin(), { automatic: false, problem: "notAllowed" });
  menu.denied = -1743;
  assert.deepEqual(begin(), { automatic: false, problem: "systemEventsNotAllowed" });
  menu.denied = false;
  menu.enabled = false;
  assert.deepEqual(begin(), { automatic: false, problem: "commandUnavailable" });
  menu.enabled = true;
  assert.deepEqual(begin(["Törlés"]), { automatic: false, problem: "commandUnavailable" });
  assert.equal(menu.clicks, 0);
  assert.deepEqual(begin(), { automatic: true, problem: null });
});

test("label names cannot break out of the AppleScript text", () => {
  const { gmail, script, call } = setup();
  const odd = new FakeMailbox('Odd" & (do shell script "x") & "', gmail);
  gmail._children.push(odd);
  script.selects = odd;
  call({ command: "deleteBegin", account: "Google", path: odd.name(), titles: [] });
  assert.match(script.source, /mailbox "Odd\\" & \(do shell script \\"x\\"\) & \\"" of account/);
});

/** Mail's selection is one filed email, and its Message menu has Archive. */
function setupArchive() {
  const env = setup();
  const message = fakeMessage(1, env.inbox, { messageId: "mid-a" });
  env.mail.selection = () => [message];
  env.menu.titles = ["Archive"];
  return env;
}

test("archive clicks Mail's Archive only when Mail's selection is exactly the filed emails", () => {
  const { inbox, menu, call } = setupArchive();
  menu.onClick = () => inbox.messagesList.splice(0);
  const titles = ["Archive"];
  assert.equal(call({ command: "archive", account: "Google", messageIds: ["mid-a", "mid-b"], titles }).result.result, "selectionChanged");
  assert.equal(menu.clicks, 0);
  assert.equal(call({ command: "archive", account: "Google", messageIds: ["mid-a"], titles }).result.result, "archived");
  assert.equal(menu.clicks, 1);
});

test("archive reports when macOS does not allow it, and when Mail did not archive", () => {
  const { menu, call } = setupArchive();
  menu.denied = true;
  assert.equal(call({ command: "archive", account: "Google", messageIds: ["mid-a"], titles: ["Archive"] }).result.result, "notAllowed");
  menu.denied = -1743;
  assert.equal(call({ command: "archive", account: "Google", messageIds: ["mid-a"], titles: ["Archive"] }).result.result, "systemEventsNotAllowed");
  menu.denied = false;
  menu.enabled = false;
  assert.equal(call({ command: "archive", account: "Google", messageIds: ["mid-a"], titles: ["Archive"] }).result.result, "commandUnavailable");
  menu.enabled = true;
  assert.equal(call({ command: "archive", account: "Google", messageIds: ["mid-a"], titles: ["Archive"] }).result.result, "stillThere");
});

test("exists reports whether a label is still there", () => {
  const { gmail, gadgets, call } = setup();
  assert.equal(call({ command: "exists", account: "Google", path: "Gadgets" }).result.exists, true);
  gmail._children.splice(gmail._children.indexOf(gadgets), 1);
  assert.equal(call({ command: "exists", account: "Google", path: "Gadgets" }).result.exists, false);
});

test("output is ASCII, and non-ASCII text round-trips", () => {
  const { mail, inbox, gmail } = setup();
  mail.selection = () => [fakeMessage(1, inbox, { subject: "Számla – 2026 🧾" })];
  const context = vm.createContext({ Application: () => mail, delay: () => {}, ObjC: { import: () => {} }, JSON, Math, Object, String, Error, Number, Map, Set, Date });
  vm.runInContext(source, context);
  const raw = context.run([JSON.stringify({ command: "opening" })]);
  assert.match(raw, /^[\x00-\x7f]*$/);
  assert.equal(JSON.parse(raw).ok, true, raw);
  assert.equal(JSON.parse(raw).result.selection.latest.subject, "Számla – 2026 🧾");
  assert.ok(gmail);
});

test("non-ASCII input arrives intact when sent as \\u escapes", () => {
  const { gmail, call } = setup();
  gmail._children.push(new FakeMailbox("Család", gmail));
  const out = call({ command: "count", account: "Google", path: "Család" });
  assert.equal(out.result.count, 0);
});

test("unknown commands are refused, including inherited names", () => {
  const { call } = setup();
  assert.equal(call({ command: "constructor" }).ok, false);
  assert.equal(call({ command: "nope" }).ok, false);
});

test("checks never pass on Mail's error text, which can quote names", () => {
  const { mail, call } = setup();
  Object.defineProperty(mail.accounts, "name", {
    value: () => {
      throw Object.assign(new Error('Can\'t get mailbox "SECRET-LABEL".'), { errorNumber: -1728 });
    },
  });
  const check = call({ command: "diagnose" });
  assert.equal(check.ok, false);
  assert.equal(check.error.number, -1728);
  assert.ok(!JSON.stringify(check).includes("SECRET-LABEL"));
  // The window, on the owner's own screen, still gets the full text.
  assert.ok(call({ command: "labels", account: "Google" }).error.message.includes("SECRET-LABEL"));
});

test("a Gmail self-test refuses without exactly one selected email, and says why", () => {
  const { call } = setup();
  const out = call({ command: "selftestGmail", stamp: 1 });
  assert.equal(out.ok, false);
  assert.match(out.error.message, /exactly one/);
});

test("diagnose reports numbers only, never names or text", () => {
  const { mail, inbox, call } = setup();
  mail.selection = () => [fakeMessage(1, inbox, { subject: "SECRET-SUBJECT" })];
  const raw = JSON.stringify(call({ command: "diagnose" }));
  for (const secret of ["SECRET-SUBJECT", "Family", "Gadgets", "Google", "owner@"]) {
    assert.ok(!raw.includes(secret), `leaked ${secret}`);
  }
  const { result } = call({ command: "diagnose" });
  assert.equal(result.gmailAccounts, 1);
  assert.equal(result.folderAccounts, 1);
  assert.equal(result.selected, 1);
  const google = result.perAccount.find((a) => a.gmail);
  assert.equal(google.nested, 1);
  assert.equal(google.systemPaths, 2);
  assert.equal(google.trashFound, true);
  assert.equal(google.trashFoundThroughMail, true);
  assert.equal(google.trashMessages, 0);
  const other = result.perAccount.find((a) => !a.gmail);
  assert.equal(other.trashFound, true);
  assert.equal(other.inboxFound, false);
});

// The Trash

const deals = "Shop Deals <deals@shop.example.test>";

test("finds emails from the same sender in the account's Trash, newest first, sender and subject only", () => {
  const { mail, inbox, trash, call } = setup();
  const selected = fakeMessage(1, inbox, { sender: deals, subject: "Deals 3", messageId: "mid-now" });
  fakeMessage(10, trash, { sender: "deals@shop.example.test", subject: "Deals 1", date: 1000, body: "SECRET-BODY" });
  fakeMessage(11, trash, { sender: "Shop <DEALS@shop.example.test>", subject: "Deals 2", date: 2000 });
  fakeMessage(12, trash, { sender: "Other <xdeals@shop.example.test>", subject: "Not the same sender", date: 3000 });
  fakeMessage(13, trash, { sender: "Dad <dad@example.test>", subject: "Lunch", date: 4000 });
  mail.selection = () => [selected];
  const out = call({ command: "trashSimilar", account: "Google", sender: deals, messageIds: ["mid-now"] });
  assert.equal(out.ok, true, JSON.stringify(out));
  assert.deepEqual(out.result, {
    found: true,
    inTrash: false,
    messages: [
      { from: "Shop <DEALS@shop.example.test>", subject: "Deals 2" },
      { from: "deals@shop.example.test", subject: "Deals 1" },
    ],
  });
  assert.ok(!JSON.stringify(out).includes("SECRET-BODY"));
});

test("Trash matches are limited, and never include the selected email itself", () => {
  const { trash, call } = setup();
  for (let i = 0; i < 30; i++) fakeMessage(100 + i, trash, { sender: deals, subject: `Deals ${i}`, date: i });
  fakeMessage(200, trash, { sender: deals, subject: "This one", date: 99, messageId: "mid-selected" });
  const out = call({ command: "trashSimilar", account: "Google", sender: deals, messageIds: ["mid-selected"], limit: 5 });
  assert.equal(out.result.messages.length, 5);
  assert.equal(out.result.messages[0].subject, "Deals 29");
  assert.equal(out.result.inTrash, true);
});

test("the Trash is found by its usual name when Mail's own Trash does not list it", () => {
  const { trashMailboxes, trash, call } = setup();
  trashMailboxes.splice(0);
  fakeMessage(10, trash, { sender: deals, subject: "Deals 1" });
  const out = call({ command: "trashSimilar", account: "Google", sender: deals, messageIds: [] });
  assert.equal(out.result.found, true);
  assert.equal(out.result.messages.length, 1);
});

test("without a Trash, nothing is reported and nothing can be deleted", () => {
  const { mail, trashMailboxes, trash, inbox, menu, call } = setup();
  trashMailboxes.splice(0);
  trash._name = "Something else";
  assert.deepEqual(call({ command: "trashSimilar", account: "Google", sender: deals, messageIds: [] }).result, {
    found: false,
    inTrash: false,
    messages: [],
  });
  mail.selection = () => [fakeMessage(1, inbox, { messageId: "mid-a" })];
  menu.titles = ["Delete"];
  assert.equal(call({ command: "trash", account: "Google", messageIds: ["mid-a"], titles: ["Delete"] }).result.result, "noTrash");
  assert.equal(menu.clicks, 0);
});

test("a sender without an address finds nothing", () => {
  const { trash, call } = setup();
  fakeMessage(10, trash, { sender: "Nobody", subject: "x" });
  assert.deepEqual(call({ command: "trashSimilar", account: "Google", sender: "Nobody", messageIds: [] }).result.messages, []);
});

test("moving to the Trash clicks Mail's Delete only when Mail's selection is exactly those emails", () => {
  const { mail, inbox, trash, menu, call } = setup();
  const message = fakeMessage(1, inbox, { messageId: "mid-a" });
  mail.selection = () => [message];
  menu.titles = ["Delete"];
  menu.onClick = () => {
    inbox.messagesList.splice(0);
    fakeMessage(1, trash, { messageId: "mid-a" });
  };
  const titles = ["Delete"];
  assert.equal(call({ command: "trash", account: "Google", messageIds: ["mid-a", "mid-b"], titles }).result.result, "selectionChanged");
  assert.equal(call({ command: "trash", account: "Google", messageIds: [], titles }).result.result, "selectionChanged");
  assert.equal(menu.clicks, 0);
  assert.equal(call({ command: "trash", account: "Google", messageIds: ["mid-a"], titles }).result.result, "trashed");
  assert.equal(menu.clicks, 1);
});

test("an email already in the Trash is never deleted again, which would erase it", () => {
  const { mail, trash, menu, call } = setup();
  const message = fakeMessage(1, trash, { messageId: "mid-a" });
  mail.selection = () => [message];
  menu.titles = ["Delete"];
  assert.equal(call({ command: "trash", account: "Google", messageIds: ["mid-a"], titles: ["Delete"] }).result.result, "alreadyInTrash");
  assert.equal(menu.clicks, 0);
});

test("moving to the Trash reports when macOS does not allow it, and when the email did not arrive there", () => {
  const { mail, inbox, menu, call } = setup();
  mail.selection = () => [fakeMessage(1, inbox, { messageId: "mid-a" })];
  menu.titles = ["Delete"];
  menu.denied = true;
  assert.equal(call({ command: "trash", account: "Google", messageIds: ["mid-a"], titles: ["Delete"] }).result.result, "notAllowed");
  menu.denied = -1743;
  assert.equal(call({ command: "trash", account: "Google", messageIds: ["mid-a"], titles: ["Delete"] }).result.result, "systemEventsNotAllowed");
  menu.denied = false;
  assert.equal(call({ command: "trash", account: "Google", messageIds: ["mid-a"], titles: ["Nope"] }).result.result, "commandUnavailable");
  menu.onClick = () => inbox.messagesList.splice(0); // gone, but not to the Trash
  assert.equal(call({ command: "trash", account: "Google", messageIds: ["mid-a"], titles: ["Delete"] }).result.result, "notInTrash");
});

// Renamed labels: found by the emails learned for the old name

const learned = [
  { from: "Clinic <desk@clinic.example.test>", subject: "Check-up on Friday" },
  { from: "School <office@school.example.test>", subject: "Trip form" },
];

test("counts, per mailbox, the emails it holds by subject and sender address", () => {
  const { gmail, baby, gadgets, call } = setup();
  const renamed = new FakeMailbox("Newborn", gmail);
  gmail._children.push(renamed);
  fakeMessage(1, renamed, { sender: "desk@CLINIC.example.test", subject: "Check-up on Friday", body: "SECRET-BODY" });
  fakeMessage(2, renamed, { sender: "office@school.example.test", subject: "Trip form" });
  // The same subject from someone else, and the same sender with another subject, do not count.
  fakeMessage(3, baby, { sender: "Other <other@example.test>", subject: "Check-up on Friday" });
  fakeMessage(4, gadgets, { sender: "desk@clinic.example.test", subject: "Invoice" });
  const out = call({
    command: "holding", account: "Google", emails: learned, mailboxes: ["Newborn", "Family/Baby", "Gadgets", "Gone"],
  });
  assert.equal(out.ok, true, JSON.stringify(out));
  assert.deepEqual(out.result, { counts: [2, 0, 0, 0] });
  assert.ok(!JSON.stringify(out).includes("SECRET-BODY"));
});

test("holding with one email, or none that can be matched, asks Mail for little or nothing", () => {
  const { baby, call } = setup();
  fakeMessage(1, baby, { sender: "desk@clinic.example.test", subject: "Check-up on Friday" });
  const one = call({ command: "holding", account: "Google", emails: learned.slice(0, 1), mailboxes: ["Family/Baby"] });
  assert.deepEqual(one.result, { counts: [1] });
  const unusable = [{ from: "No address", subject: "Check-up on Friday" }, { from: "desk@clinic.example.test", subject: "" }];
  const none = call({ command: "holding", account: "Google", emails: unusable, mailboxes: ["Family/Baby"] });
  assert.deepEqual(none.result, { counts: [0] });
});
