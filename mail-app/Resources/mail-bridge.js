// Mail bridge: the only code that talks to Mail. Run with
//   osascript -l JavaScript mail-bridge.js '<json>'
// where <json> is {"command": "...", ...}. Prints one JSON object: {"ok":true,"result":...} or
// {"ok":false,"error":{"number":n,"message":"..."}}.
//
// Input and output are ASCII with \u escapes, so text survives whatever encoding osascript picks,
// and input is parsed as data, never spliced into a script. In Gmail a mailbox is a label. In any
// other account (iCloud, Exchange, IMAP) it is a folder, and an email is in exactly one of them.
// Reading never changes a message. Everything else is on the owner's explicit action.
'use strict';

ObjC.import('Foundation');

const Mail = Application('Mail');

const MAX_MESSAGES = 200;
const MAX_DEPTH = 8;
const GMAIL_HOST = /(^|\.)(gmail|googlemail)\.com$/i;
const GMAIL_ADDRESS = /@(gmail|googlemail)\.com$/i;
const SELF_TEST_PREFIX = 'catrec-selftest-';

function fail(number, message) {
  const e = new Error(message);
  e.errorNumber = number;
  e.ownMessage = true;
  return e;
}

// These commands' output may be shared while debugging, and Mail's own error texts can quote
// mailbox names, so they report error numbers and this script's fixed messages only.
const CHECKS = ['diagnose', 'selftestLocal', 'selftestGmail', 'selftestAccount'];

const NOT_FOUND = -1728; // Apple Events "can't get"

function ascii(value) {
  return JSON.stringify(value).replace(
    /[\u007f-￿]/g,
    (c) => '\\u' + ('0000' + c.charCodeAt(0).toString(16)).slice(-4),
  );
}

function attempt(fn, fallback) {
  try {
    return fn();
  } catch (_) {
    return fallback;
  }
}

function exists(specifier) {
  return attempt(
    () => specifier.exists(),
    attempt(() => {
      specifier.name();
      return true;
    }, false),
  );
}

/** Waits for a condition: IMAP changes reach Mail's object model a moment after the command. */
function until(condition, seconds) {
  for (let waited = 0; waited < seconds; waited += 0.25) {
    if (condition()) return true;
    delay(0.25);
  }
  return condition();
}

// Accounts

/**
 * Every enabled account. `kind` is 'gmail' where mailboxes are labels, and 'folders' elsewhere.
 * Some account types do not have every property (Exchange has no server name), so a property that
 * cannot be read for all accounts at once is read one account at a time.
 */
function mailAccounts() {
  const all = Mail.accounts;
  const names = all.name();
  const column = (property) => {
    const together = attempt(() => all[property](), null);
    if (together && together.length === names.length) return together;
    return names.map((name) => attempt(() => all.byName(name)[property](), undefined));
  };
  const hosts = column('serverName');
  const enabled = column('enabled');
  const addresses = column('emailAddresses');
  return names
    .map((name, i) => ({ name, host: hosts[i] || '', enabled: enabled[i], addresses: addresses[i] || [] }))
    .filter((a) => a.enabled !== false)
    .map((a) => ({
      name: a.name,
      addresses: a.addresses,
      kind:
        GMAIL_HOST.test(a.host) || a.addresses.some((address) => GMAIL_ADDRESS.test(address))
          ? 'gmail'
          : 'folders',
    }));
}

function kindOf(name) {
  const found = mailAccounts().find((a) => a.name === name);
  if (!found) throw fail(NOT_FOUND, 'that account is not in Mail');
  return found.kind;
}

function accountNamed(name) {
  kindOf(name);
  return Mail.accounts.byName(name);
}

// Mail's own Inbox, Sent, Drafts, Junk, Trash and Outbox each hold one mailbox per account. That
// says which of an account's folders are these, whatever they are called there: the names differ
// by provider and by language. They sit at the account's top level, so their name is their path.

function specialName(collection, accountName) {
  const boxes = attempt(() => collection().mailboxes(), []) || [];
  for (const box of boxes) {
    if (attempt(() => box.account().name(), null) === accountName) return attempt(() => box.name(), null);
  }
  return null;
}

function inboxName(accountName) {
  return specialName(() => Mail.inbox, accountName);
}

function systemNames(accountName) {
  const collections = [
    () => Mail.inbox,
    () => Mail.sentMailbox,
    () => Mail.draftsMailbox,
    () => Mail.junkMailbox,
    () => Mail.trashMailbox,
    () => Mail.outbox,
  ];
  const names = collections.map((c) => specialName(c, accountName)).filter((name) => name);
  return names.filter((name, i) => names.indexOf(name) === i);
}

function labelsOf(accountName) {
  return {
    mailboxes: allPaths(Mail.accounts.byName(accountName)),
    system: systemNames(accountName),
    inbox: inboxName(accountName),
  };
}

// Mailboxes. Mail lists every mailbox of an account at its top level, nested ones under their
// short name, and lists them again under their parent. Gmail's system folders are the children of a
// "[Gmail]" parent that is itself not listed, and their names follow Gmail's language. So the parent
// chain, not the name, says where a mailbox is.

function isAccount(object) {
  // Accounts have an id and mailboxes do not.
  return attempt(() => (object.id(), true), false);
}

function pathOf(mailbox) {
  const parts = [mailbox.name()];
  let current = mailbox;
  for (let i = 0; i < MAX_DEPTH; i++) {
    const parent = attempt(() => current.container(), null);
    if (!parent || isAccount(parent)) break;
    const name = attempt(() => parent.name(), null);
    if (!name) break;
    parts.unshift(name);
    current = parent;
  }
  return parts.join('/');
}

/**
 * All paths in a few requests. Asking one mailbox at a time takes seconds. The parent chain is
 * followed by name; a parent whose short name is not unique falls back to asking its mailbox.
 */
function allPaths(account) {
  const names = account.mailboxes.name();
  const parents = account.mailboxes.container.name();
  const parentOf = new Map();
  const ambiguous = new Set();
  names.forEach((name, i) => {
    if (parentOf.has(name) && parentOf.get(name) !== parents[i]) ambiguous.add(name);
    parentOf.set(name, parents[i]);
  });
  const paths = names.map((name, i) => {
    const parts = [name];
    let up = parents[i];
    for (let depth = 0; up && depth < MAX_DEPTH; depth++) {
      if (ambiguous.has(up)) return pathOf(account.mailboxes[i]);
      parts.unshift(up);
      up = parentOf.get(up);
    }
    return parts.join('/');
  });
  return paths.filter((path, i) => paths.indexOf(path) === i);
}

/** The top-level mailbox with this name. A nested one can have the same short name. */
function topLevel(account, name) {
  const names = account.mailboxes.name();
  for (let i = 0; i < names.length; i++) {
    if (names[i] !== name) continue;
    const candidate = account.mailboxes[i];
    if (attempt(() => isAccount(candidate.container()), false)) return candidate;
  }
  return null;
}

function resolve(account, path) {
  const segments = path.split('/');
  let current = topLevel(account, segments[0]);
  if (current) {
    for (const segment of segments.slice(1)) {
      const next = current.mailboxes.byName(segment);
      if (!exists(next)) {
        current = null;
        break;
      }
      current = next;
    }
    if (current) return current;
  }
  // System folders: their parent is not listed, so find them through the flat listing.
  const short = segments[segments.length - 1];
  const names = account.mailboxes.name();
  for (let i = 0; i < names.length; i++) {
    if (names[i] === short && pathOf(account.mailboxes[i]) === path) return account.mailboxes[i];
  }
  return null;
}

function requireMailbox(account, path) {
  const mailbox = resolve(account, path);
  if (!mailbox) throw fail(NOT_FOUND, 'that label is not in the account');
  return mailbox;
}

function createMailbox(account, path) {
  if (resolve(account, path)) return { created: false };
  // Reports differ on which form works for which account type, so try both and verify the result.
  const attempts = [
    () => account.mailboxes.push(Mail.Mailbox({ name: path })),
    () => Mail.make({ new: 'mailbox', withProperties: { name: path }, at: account }),
  ];
  let last = null;
  for (const create of attempts) {
    try {
      create();
    } catch (e) {
      last = e;
      continue;
    }
    if (until(() => resolve(account, path) !== null, 10)) return { created: true };
  }
  throw last || fail(NOT_FOUND, 'Mail did not create the label');
}

// Mail's scripting cannot delete a mailbox (it fails with -10000, on any account). So deleting goes
// through Mail's own command, after making sure that Mail is showing the right mailbox. Mail then
// asks for confirmation, naming the mailbox. The caller waits for the mailbox to disappear.

function appleScriptText(text) {
  return '"' + text.replace(/[\u0000-\u001f]/g, ' ').replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"';
}

function showMailbox(account, path) {
  let reference = 'account ' + appleScriptText(account.name());
  for (const segment of path.split('/')) {
    reference = 'mailbox ' + appleScriptText(segment) + ' of ' + reference;
  }
  // JXA cannot set this property, so this one step is AppleScript. All names are escaped above.
  const source = [
    'tell application "Mail"',
    'if (count of message viewers) is 0 then make new message viewer',
    'set selected mailboxes of message viewer 1 to {' + reference + '}',
    'end tell',
  ].join('\n');
  $.NSAppleScript.alloc.initWithSource($(source)).executeAndReturnError(Ref());
  return until(() => {
    const selected = attempt(() => Mail.messageViewers[0].selectedMailboxes(), []) || [];
    return selected.length === 1 && pathOf(selected[0]) === path;
  }, 3);
}

/**
 * Clicks a command in Mail's menus. Returns null once clicked, or why it was not:
 * - 'notAllowed': macOS does not let this app use other apps' menus (Accessibility). A switch that
 *   looks on can belong to an earlier build: the app is signed ad hoc, so each install is new.
 * - 'systemEventsNotAllowed': this app may not control System Events (Automation).
 * - 'commandUnavailable': Mail has no such command, or it is greyed out right now.
 */
function clickMenuCommand(titles) {
  try {
    const items = Application('System Events').processes.byName('Mail').menuBars[0].menuBarItems;
    const count = items.length;
    for (let i = 0; i < count; i++) {
      const entries = attempt(() => items[i].menus[0].menuItems, null);
      const names = entries ? attempt(() => entries.name(), []) : [];
      const index = names.findIndex((name) => titles.indexOf(name) >= 0);
      if (index < 0) continue;
      if (!entries[index].enabled()) return 'commandUnavailable';
      entries[index].click();
      return null;
    }
    return 'commandUnavailable';
  } catch (e) {
    return errorNumber(e) === NOT_AUTHORIZED ? 'systemEventsNotAllowed' : 'notAllowed';
  }
}

// Messages

const NOT_AUTHORIZED = -1743;

function errorNumber(e) {
  if (e.errorNumber !== undefined) return e.errorNumber;
  const match = /\((-\d+)\)/.exec(String(e.message));
  return match ? Number(match[1]) : 0;
}

/** A self-test step: runs `fn` and records in `steps` whether it passed, failed or threw. */
function stepper(steps) {
  return (name, fn) => {
    try {
      steps[name] = fn() ? 'pass' : 'fail';
    } catch (e) {
      steps[name] = 'error ' + errorNumber(e);
    }
    return steps[name] === 'pass';
  };
}

/** Mail can report an error instead of an empty list when nothing is selected. */
function currentSelection() {
  try {
    return Mail.selection();
  } catch (e) {
    if (errorNumber(e) === NOT_AUTHORIZED) throw e;
    return [];
  }
}

const SYSTEM_PATH = /^\[(gmail|google mail)\]\//i;

/** Paths of the mailboxes the owner is looking at in Mail's front window, in this account. */
function viewedPaths(accountName) {
  const selected = attempt(() => Mail.messageViewers[0].selectedMailboxes(), []) || [];
  return selected
    .filter((mailbox) => attempt(() => mailbox.account().name() === accountName, false))
    .map(pathOf);
}

/**
 * Mail keeps each Gmail email in All Mail and shows it in the Inbox and its labels too, so a
 * selected email reports All Mail as its mailbox. Filing has to act on the copy the owner is looking
 * at, else it could never take an email out of the Inbox. That copy is found by its Message-ID: first
 * in the mailbox shown in Mail, then in the Inbox.
 */
function messageRef(message, viewedByAccount, inboxes) {
  const mailbox = message.mailbox();
  // A mailbox under On My Mac has no account.
  const account = attempt(() => mailbox.account().name(), '') || '';
  const messageId = attempt(() => message.messageId(), '') || '';
  const ref = { id: message.id(), mailbox: pathOf(mailbox), account, date: message.dateReceived().getTime(), messageId };
  return Object.assign(ref, { inInbox: isInInbox(placed(ref, messageId, viewedByAccount), inboxes) });
}

function isInInbox(ref, inboxes) {
  if (ref.mailbox.toUpperCase() === 'INBOX') return true;
  if (!ref.account) return false;
  if (!inboxes.has(ref.account)) inboxes.set(ref.account, inboxName(ref.account));
  return inboxes.get(ref.account) === ref.mailbox;
}

function placed(ref, messageId, viewedByAccount) {
  const account = ref.account;
  if (!SYSTEM_PATH.test(ref.mailbox) || !messageId) return ref;
  if (!viewedByAccount.has(account)) viewedByAccount.set(account, viewedPaths(account));
  const places = viewedByAccount
    .get(account)
    .filter((path) => !SYSTEM_PATH.test(path))
    .concat(['INBOX']);
  const owner = Mail.accounts.byName(account);
  for (const path of places) {
    const box = resolve(owner, path);
    const hits = box ? attempt(() => box.messages.whose({ messageId })(), []) || [] : [];
    if (hits.length) return Object.assign(ref, { id: hits[0].id(), mailbox: path });
  }
  return ref;
}

function readEmail(message) {
  const to = attempt(() => message.toRecipients(), []) || [];
  return {
    from: attempt(() => message.sender(), '') || '',
    to: to.slice(0, 100).map((r) => {
      const address = attempt(() => r.address(), '') || '';
      const name = attempt(() => r.name(), '') || '';
      return name && name !== address ? name + ' <' + address + '>' : address;
    }),
    subject: attempt(() => message.subject(), '') || '',
    body: attempt(() => message.content(), '') || '',
  };
}

/**
 * Gmail: adds the label. Mail's scripted move only adds the label there too, and marking the old
 * copy deleted makes Mail crash (it tries to move it to Trash), so taking an email out of the Inbox
 * is left to Mail's own Archive command: see `archive`.
 *
 * Folder accounts: an item with mode 'move' is moved to the folder, and any other is copied there.
 */
function fileMessages(account, targetPath, items, kind) {
  const target = requireMailbox(account, targetPath);
  let filed = 0;
  for (const item of items) {
    if (item.mailbox === targetPath) continue; // already there
    const message = requireMailbox(account, item.mailbox).messages.byId(item.id);
    if (kind === 'folders' && item.mode === 'move') {
      moveMessage(message, target);
    } else {
      Mail.duplicate(message, { to: target });
    }
    filed++;
  }
  return filed;
}

/** Mail takes a move either as a command or as setting the message's mailbox, depending on the account type. */
function moveMessage(message, target) {
  try {
    Mail.move(message, { to: target });
  } catch (e) {
    if (errorNumber(e) === NOT_AUTHORIZED) throw e;
    message.mailbox = target;
  }
}

function selectedMessageIds() {
  return currentSelection().map((m) => attempt(() => m.messageId(), null));
}

// The Trash. Mail's own Trash holds one mailbox per account, which is the reliable way to find
// it. Gmail's Trash is a system folder whose name follows Gmail's language, so its usual names are
// only the fallback. Without a Trash, nothing is ever deleted: Mail's Delete could then erase.

const TRASH_PATH =
  /^\[(gmail|google mail)\]\/(trash|bin|kuka|papierkorb|corbeille|papelera|cestino|prullenbak|lixeira|lixo|kosz|koš)$/i;

function trashOf(account) {
  const name = account.name();
  const boxes = attempt(() => Mail.trashMailbox.mailboxes(), []) || [];
  for (const box of boxes) {
    if (attempt(() => box.account().name(), null) === name) return box;
  }
  const path = allPaths(account).find((p) => TRASH_PATH.test(p));
  return path ? resolve(account, path) : null;
}

function holds(mailbox, messageId) {
  return (attempt(() => mailbox.messages.whose({ messageId })().length, 0) || 0) > 0;
}

/** The address part of a From header, lower case. The service compares senders the same way. */
function senderAddress(from) {
  const inBrackets = /<([^<>]+)>/.exec(from);
  const bare = /[^\s<>"]+@[^\s<>"]+/.exec(from);
  return ((inBrackets && inBrackets[1]) || (bare && bare[0]) || from).trim().toLowerCase();
}

const MAX_TRASH_MATCHES = 50;
const MAX_HELD_EMAILS = 10;
const MAX_HELD_MAILBOXES = 30;

/**
 * How many of these emails the mailbox holds: the same subject and sender address. Mail filters
 * by subject, which is quick, and the sender is compared here, as the service compares it.
 */
function heldCount(mailbox, emails) {
  const subjects = emails.map((e) => e.subject).filter((s, i, all) => all.indexOf(s) === i);
  if (!mailbox || !subjects.length) return 0;
  const condition =
    subjects.length === 1 ? { subject: subjects[0] } : { _or: subjects.map((subject) => ({ subject })) };
  const hits = mailbox.messages.whose(condition);
  const senders = attempt(() => hits.sender(), []) || [];
  const found = attempt(() => hits.subject(), []) || [];
  return emails.filter((e) =>
    found.some((subject, i) => subject === e.subject && senderAddress(String(senders[i] || '')) === e.address),
  ).length;
}

function sameSet(a, b) {
  return a.length === b.length && a.every((x) => b.indexOf(x) >= 0);
}

// Commands

const commands = {
  // Everything the window needs when it opens, in one process, so that it fills quickly.
  opening() {
    if (!Mail.running()) {
      return { selection: { running: false, total: 0, messages: [], latest: null }, accounts: [], labels: null };
    }
    const selected = currentSelection();
    const considered = selected.slice(0, MAX_MESSAGES);
    const viewed = new Map();
    const inboxes = new Map();
    const messages = considered.map((m) => messageRef(m, viewed, inboxes));
    let newest = 0;
    messages.forEach((m, i) => {
      if (m.date > messages[newest].date) newest = i;
    });
    const accounts = mailAccounts();
    const owner = messages.length ? accounts.find((a) => a.name === messages[0].account) : null;
    return {
      selection: {
        running: true,
        total: selected.length,
        messages,
        latest: considered.length ? readEmail(considered[newest]) : null,
      },
      accounts,
      labels: owner ? labelsOf(owner.name) : null,
    };
  },

  labels(input) {
    accountNamed(input.account);
    return labelsOf(input.account);
  },

  file(input) {
    const account = accountNamed(input.account);
    return { filed: fileMessages(account, input.target, input.items, kindOf(input.account)) };
  },

  create(input) {
    return createMailbox(accountNamed(input.account), input.path);
  },

  deleteBegin(input) {
    const account = accountNamed(input.account);
    requireMailbox(account, input.path);
    Mail.activate();
    if (!showMailbox(account, input.path)) {
      throw fail(NOT_FOUND, 'Mail could not show that label, so nothing was deleted');
    }
    delay(0.3);
    const problem = clickMenuCommand(input.titles || []);
    return { automatic: problem === null, problem };
  },

  // Takes the filed emails out of the Inbox with Mail's own Archive command, which in Gmail removes
  // the Inbox label. It acts on what is selected in Mail, so it only runs if that is exactly the
  // filed emails.
  archive(input) {
    const account = accountNamed(input.account);
    if (!sameSet(selectedMessageIds(), input.messageIds)) return { result: 'selectionChanged' };
    Mail.activate();
    delay(0.2);
    const problem = clickMenuCommand(input.titles || []);
    if (problem) return { result: problem };
    const inbox = resolve(account, 'INBOX');
    const left = () =>
      input.messageIds.filter(
        (messageId) => (attempt(() => inbox.messages.whose({ messageId })().length, 0) || 0) > 0,
      ).length;
    return { result: until(() => left() === 0, 10) ? 'archived' : 'stillThere' };
  },

  // Emails from the same sender in the account's Trash, newest first: sender and subject only.
  // They tell the recommender that the owner deletes emails like this one. Also says whether the
  // selected emails are in the Trash already. Reading never changes a message.
  trashSimilar(input) {
    const account = accountNamed(input.account);
    const trash = trashOf(account);
    if (!trash) return { found: false, inTrash: false, messages: [] };
    const selected = input.messageIds || [];
    const inTrash = selected.some((messageId) => holds(trash, messageId));
    const address = senderAddress(input.sender || '');
    if (address.indexOf('@') < 0) return { found: true, inTrash, messages: [] };
    const hits = trash.messages.whose({ sender: { _contains: address } });
    const senders = attempt(() => hits.sender(), []) || [];
    const subjects = attempt(() => hits.subject(), []) || [];
    const ids = attempt(() => hits.messageId(), []) || [];
    const dates = attempt(() => hits.dateReceived(), []) || [];
    const limit = Math.min(Math.max(Number(input.limit) || 20, 1), MAX_TRASH_MATCHES);
    const messages = senders
      .map((from, i) => ({
        from: String(from || ''),
        subject: String(subjects[i] || ''),
        messageId: ids[i],
        date: dates[i] ? new Date(dates[i]).getTime() : 0,
      }))
      .filter((m) => senderAddress(m.from) === address && selected.indexOf(m.messageId) < 0)
      .sort((a, b) => b.date - a.date)
      .slice(0, limit)
      .map((m) => ({ from: m.from, subject: m.subject }));
    return { found: true, inTrash, messages };
  },

  // Moves the selected emails to the Trash with Mail's own Delete command, as the owner would. It
  // acts on what is selected in Mail, so it only runs if that is exactly these emails. In the Trash
  // itself, Mail's Delete erases for good, so emails that are there already are refused.
  trash(input) {
    const account = accountNamed(input.account);
    const ids = input.messageIds || [];
    if (!ids.length || !sameSet(selectedMessageIds(), ids)) return { result: 'selectionChanged' };
    const trash = trashOf(account);
    if (!trash) return { result: 'noTrash' };
    if (ids.some((messageId) => holds(trash, messageId))) return { result: 'alreadyInTrash' };
    Mail.activate();
    delay(0.2);
    const problem = clickMenuCommand(input.titles || []);
    if (problem) return { result: problem };
    const arrived = until(() => ids.every((messageId) => holds(trash, messageId)), 15);
    return { result: arrived ? 'trashed' : 'notInTrash' };
  },

  // For each mailbox, how many of these emails it holds. It tells a renamed label from a new one,
  // by the emails learned for the old name. Reading never changes a message.
  holding(input) {
    const account = accountNamed(input.account);
    const emails = (input.emails || [])
      .slice(0, MAX_HELD_EMAILS)
      .map((e) => ({ address: senderAddress(String(e.from || '')), subject: String(e.subject || '') }))
      .filter((e) => e.subject && e.address.indexOf('@') >= 0)
      // An email learned twice is still one email: it must not count twice.
      .filter((e, i, all) => all.findIndex((o) => o.address === e.address && o.subject === e.subject) === i);
    const paths = (input.mailboxes || []).slice(0, MAX_HELD_MAILBOXES);
    return { counts: paths.map((path) => (emails.length ? heldCount(resolve(account, path), emails) : 0)) };
  },

  exists(input) {
    return { exists: resolve(accountNamed(input.account), input.path) !== null };
  },

  count(input) {
    return { count: requireMailbox(accountNamed(input.account), input.path).messages.length };
  },

  // Counts and booleans only: this output may be shared while debugging, so no names or text.
  diagnose() {
    const running = Mail.running();
    const usable = running ? mailAccounts() : [];
    const report = {
      mailRunning: running,
      accounts: running ? Mail.accounts.name().length : 0,
      gmailAccounts: usable.filter((a) => a.kind === 'gmail').length,
      folderAccounts: usable.filter((a) => a.kind === 'folders').length,
      selected: running ? currentSelection().length : 0,
      perAccount: usable.map((a) => {
        const account = Mail.accounts.byName(a.name);
        const started = Date.now();
        const all = allPaths(account);
        const system = all.filter((n) => /^\[(gmail|google mail)\]/i.test(n));
        const throughMail = (attempt(() => Mail.trashMailbox.mailboxes(), []) || []).some(
          (box) => attempt(() => box.account().name(), null) === a.name,
        );
        const trash = trashOf(account);
        const inbox = inboxName(a.name);
        return {
          gmail: a.kind === 'gmail',
          inboxFound: inbox !== null && topLevel(account, inbox) !== null,
          systemFolders: systemNames(a.name).length,
          trashFound: trash !== null,
          trashFoundThroughMail: throughMail,
          trashMessages: trash ? attempt(() => trash.messages.length, -1) : 0,
          listed: account.mailboxes.name().length,
          paths: all.length,
          nested: all.filter((n) => n.indexOf('/') >= 0).length - system.length,
          deeperThanTwo: all.filter((n) => n.split('/').length > 2).length,
          systemPaths: system.length,
          longestSegment: all
            .map((n) => Math.max.apply(null, n.split('/').map((p) => p.length)))
            .reduce((x, y) => Math.max(x, y), 0),
          milliseconds: Date.now() - started,
        };
      }),
    };
    return report;
  },

  // Real Mail, synthetic data, under "On My Mac". Reports pass or fail only. Mail's scripting cannot
  // delete mailboxes, so this leaves "catrec-selftest" and an "Import" mailbox behind. Later runs
  // reuse them.
  selftestLocal(input) {
    const steps = {};
    const parent = 'catrec-selftest';
    const fabricated = { messageId: { _beginsWith: 'catrec-selftest-' } };
    const named = (name) => {
      const names = Mail.mailboxes.name();
      const i = names.indexOf(name);
      return i >= 0 ? Mail.mailboxes[i] : null;
    };
    const child = () => {
      const top = named(parent);
      return top && exists(top.mailboxes.byName('child')) ? top.mailboxes.byName('child') : null;
    };
    const holding = (mailbox) =>
      mailbox ? attempt(() => mailbox.messages.whose(fabricated)(), []) || [] : [];
    const findMessage = () => {
      const count = Mail.mailboxes.name().length;
      for (let i = 0; i < count; i++) {
        const hits = holding(Mail.mailboxes[i]);
        if (hits.length) return hits[0];
      }
      return null;
    };
    const step = stepper(steps);

    step('createMailbox', () => {
      if (!named(parent)) Mail.mailboxes.push(Mail.Mailbox({ name: parent }));
      return until(() => named(parent) !== null, 5);
    });
    step('createNestedMailbox', () => {
      if (!child()) Mail.mailboxes.push(Mail.Mailbox({ name: parent + '/child' }));
      return until(() => child() !== null, 5);
    });
    step('pathComesFromParents', () => pathOf(child()) === parent + '/child');

    let message = null;
    const found = step('fabricatedMessage', () => {
      message = findMessage();
      if (message) return true;
      Mail.importMailMailbox({ at: Path(input.mbox) });
      return until(() => (message = findMessage()) !== null, 30);
    });
    if (found) {
      step('readMessage', () => {
        const email = readEmail(message);
        return (
          email.subject === 'Self-test subject' &&
          email.body.indexOf('Self-test body') >= 0 &&
          email.from.indexOf('example.test') >= 0
        );
      });
      // On My Mac mailboxes have no account, so this checks everything else a reference needs.
      step('readReference', () => {
        return message.id() > 0 && message.dateReceived().getTime() > 0 && pathOf(message.mailbox()).length > 0;
      });
      step('copyMessage', () => {
        const before = holding(named(parent)).length;
        Mail.duplicate(message, { to: named(parent) });
        return until(() => holding(named(parent)).length > before, 10);
      });
      // How a renamed label is recognised: by subject and sender, with two subjects to ask for.
      step('findBySubjectAndSender', () => {
        const address = senderAddress(String(message.sender()));
        const emails = [
          { address, subject: 'Self-test subject' },
          { address, subject: 'Self-test subject that no message has' },
        ];
        return heldCount(named(parent), emails) === 1;
      });
    }
    step('showMailboxInMail', () => {
      const viewers = Mail.messageViewers.length;
      if (!viewers) return false;
      const source = 'tell application "Mail" to set selected mailboxes of message viewer 1 to {mailbox ' +
        appleScriptText(parent) + '}';
      $.NSAppleScript.alloc.initWithSource($(source)).executeAndReturnError(Ref());
      return until(() => {
        const selected = Mail.messageViewers[0].selectedMailboxes();
        return selected.length === 1 && selected[0].name() === parent;
      }, 3);
    });
    return { steps };
  },

  // Real account, run only by the owner, on the one email selected in the Inbox. Adds temporary
  // labels to it, archives it with Mail's own command and puts it back in the Inbox. Reports pass or
  // fail only. Mail's scripting cannot delete labels, so the labels stay for the owner to delete from
  // the window, which also tests that an email survives its label being deleted.
  selftestGmail(input) {
    const steps = {};
    const selected = currentSelection();
    if (selected.length !== 1) throw fail(NOT_FOUND, 'select exactly one email in Mail first');
    const message = selected[0];
    const ref = messageRef(message, new Map(), new Map());
    const messageId = ref.messageId;
    const account = accountNamed(ref.account);
    if (!ref.inInbox) throw fail(NOT_FOUND, 'select an email in the Inbox');
    if (kindOf(ref.account) === 'folders') return selftestFolders(account, ref, messageId);
    steps.foundInboxCopy = 'pass';
    const first = SELF_TEST_PREFIX + 'labelled';
    const nested = first + '/child';
    const inMailbox = (path) => {
      const mailbox = resolve(account, path);
      return mailbox ? attempt(() => mailbox.messages.whose({ messageId })().length, 0) : 0;
    };
    const step = stepper(steps);
    step('readSelection', () => messageId.length > 0);
    step('createLabel', () => {
      createMailbox(account, first);
      return resolve(account, first) !== null;
    });
    step('createNestedLabel', () => {
      createMailbox(account, nested);
      return resolve(account, nested) !== null;
    });
    step('nestedLabelHasFullPath', () => allPaths(account).indexOf(nested) >= 0);
    step('notDoubledUnderItsParent', () => allPaths(account).indexOf(first + '/' + first + '/child') < 0);
    step('systemFoldersAreRecognised', () => allPaths(account).some((n) => SYSTEM_PATH.test(n)));
    step('labelThroughFiling', () => {
      fileMessages(account, nested, [{ id: ref.id, mailbox: ref.mailbox }]);
      return until(() => inMailbox(nested) > 0, 30);
    });
    step('staysInInboxUntilArchived', () => inMailbox(ref.mailbox) > 0);
    const archived = commands.archive({ account: ref.account, messageIds: [messageId], titles: input.titles });
    steps.archive = archived.result === 'archived' ? 'pass' : archived.result;
    if (archived.result === 'archived') {
      step('keepsLabelAfterArchive', () => inMailbox(nested) > 0);
      step('backToInbox', () => {
        const copy = resolve(account, nested).messages.whose({ messageId })()[0];
        Mail.duplicate(copy, { to: resolve(account, 'INBOX') });
        return until(() => inMailbox('INBOX') > 0, 30);
      });
    }
    step('inInboxAtTheEnd', () => inMailbox('INBOX') > 0);
    return { steps };
  },
};

commands.selftestAccount = commands.selftestGmail;

// The same check for an account with folders: moves the selected Inbox email into a temporary
// folder and back. The folders stay for the owner to delete, empty.
function selftestFolders(account, ref, messageId) {
  const steps = { foundInboxCopy: 'pass' };
  const first = SELF_TEST_PREFIX + 'folder';
  const nested = first + '/child';
  const copies = (path) => {
    const mailbox = resolve(account, path);
    return mailbox ? attempt(() => mailbox.messages.whose({ messageId })(), []) || [] : [];
  };
  const step = stepper(steps);
  step('readSelection', () => messageId.length > 0);
  step('inboxIsKnown', () => inboxName(ref.account) === ref.mailbox);
  step('systemFoldersAreRecognised', () => systemNames(ref.account).length > 1);
  step('createFolder', () => {
    createMailbox(account, first);
    return resolve(account, first) !== null;
  });
  step('createNestedFolder', () => {
    createMailbox(account, nested);
    return resolve(account, nested) !== null;
  });
  step('nestedFolderHasFullPath', () => allPaths(account).indexOf(nested) >= 0);
  const moved = step('moveThroughFiling', () => {
    fileMessages(account, nested, [{ id: ref.id, mailbox: ref.mailbox, mode: 'move' }], 'folders');
    return until(() => copies(nested).length > 0, 30);
  });
  step('leftTheInbox', () => until(() => copies(ref.mailbox).length === 0, 30));
  if (moved) {
    step('backToInbox', () => {
      moveMessage(copies(nested)[0], resolve(account, ref.mailbox));
      return until(() => copies(ref.mailbox).length > 0, 30);
    });
    step('leftTheFolder', () => until(() => copies(nested).length === 0, 30));
  }
  step('inInboxAtTheEnd', () => copies(ref.mailbox).length > 0);
  return { steps };
}

function run(argv) {
  let input = {};
  try {
    input = JSON.parse(argv[0] || '{}');
    if (!Object.prototype.hasOwnProperty.call(commands, input.command)) {
      throw fail(-1, 'unknown command');
    }
    return ascii({ ok: true, result: commands[input.command](input) });
  } catch (e) {
    return ascii({
      ok: false,
      error: {
        number: errorNumber(e),
        message: CHECKS.indexOf(input.command) >= 0 && !e.ownMessage ? '' : String(e.message),
      },
    });
  }
}
