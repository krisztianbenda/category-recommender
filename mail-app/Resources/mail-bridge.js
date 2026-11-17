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
// A batch: one recommendation per email (specs/004-batch-recommendations). The 50 newest of at most
// the first 1,000 selected, in Mail's order.
const MAX_BATCH = 50;
const MAX_BATCH_SCAN = 1000;
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
const CHECKS = [
  'diagnose',
  'selftestLocal',
  'selftestGmail',
  'selftestAccount',
  'selftestRecover',
  'selftestLocate',
  'selftestSelection',
];

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

/** `inbox` is the account's Inbox name when the caller has it already. */
function systemNames(accountName, inbox = inboxName(accountName)) {
  const collections = [
    () => Mail.sentMailbox,
    () => Mail.draftsMailbox,
    () => Mail.junkMailbox,
    () => Mail.trashMailbox,
    () => Mail.outbox,
  ];
  const names = [inbox].concat(collections.map((c) => specialName(c, accountName))).filter((name) => name);
  return names.filter((name, i) => names.indexOf(name) === i);
}

function labelsOf(accountName) {
  const inbox = inboxName(accountName);
  return {
    mailboxes: allPaths(Mail.accounts.byName(accountName)),
    system: systemNames(accountName, inbox),
    inbox,
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

/**
 * Adds a parent's name in front of a path. Gmail names a nested mailbox by its short name. Other
 * accounts name it by its whole path, "Parent/Child", which then has the parent in it already.
 */
function prepend(parts, parentName) {
  if (parts[0].indexOf(parentName + '/') !== 0) parts.unshift(parentName);
}

function pathOf(mailbox) {
  const parts = [mailbox.name()];
  let current = mailbox;
  for (let i = 0; i < MAX_DEPTH; i++) {
    const parent = attempt(() => current.container(), null);
    if (!parent || isAccount(parent)) break;
    const name = attempt(() => parent.name(), null);
    if (!name) break;
    prepend(parts, name);
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
      prepend(parts, up);
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
  // Gmail's system folders: their parent is not listed, so find them through the flat listing.
  // So are nested folders of accounts that name them by their whole path.
  const short = segments[segments.length - 1];
  const names = account.mailboxes.name();
  for (let i = 0; i < names.length; i++) {
    if ((names[i] === short || names[i] === path) && pathOf(account.mailboxes[i]) === path) {
      return account.mailboxes[i];
    }
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

function mailboxReference(accountName, path) {
  let reference = 'account ' + appleScriptText(accountName);
  for (const segment of path.split('/')) {
    reference = 'mailbox ' + appleScriptText(segment) + ' of ' + reference;
  }
  return reference;
}

function showMailbox(account, path) {
  const owner = 'account ' + appleScriptText(account.name());
  // Accounts that name a nested mailbox by its whole path take that path as one name.
  const references = [mailboxReference(account.name(), path), 'mailbox ' + appleScriptText(path) + ' of ' + owner];
  const shown = () => {
    const selected = attempt(() => Mail.messageViewers[0].selectedMailboxes(), []) || [];
    return selected.length === 1 && pathOf(selected[0]) === path;
  };
  for (const reference of references.filter((r, i) => references.indexOf(r) === i)) {
    // JXA cannot set this property, so this one step is AppleScript. All names are escaped above.
    const source = [
      'tell application "Mail"',
      'if (count of message viewers) is 0 then make new message viewer',
      'set selected mailboxes of message viewer 1 to {' + reference + '}',
      'end tell',
    ].join('\n');
    $.NSAppleScript.alloc.initWithSource($(source)).executeAndReturnError(Ref());
    if (until(shown, 3)) return true;
  }
  return false;
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

/**
 * Clicks a command of Mail's menus that acts on Mail's selection, only when that selection is
 * exactly `ids`; with `input.select` (a batch), it selects them first. Returns why it did not
 * click, or null once clicked.
 */
/** Adds Mail's error numbers from selecting, when there were any. */
function withSelectErrors(input, result) {
  return input.selectErrors && input.selectErrors.length ? Object.assign(result, { selectErrors: input.selectErrors }) : result;
}

function clickOnExactly(input, ids) {
  if (input.select) {
    const { selected, errors } = selectForAction(input);
    input.selectErrors = errors.filter((n) => n !== 1).filter((n, i, all) => all.indexOf(n) === i);
    if (!selected) return 'selectionChanged';
  }
  if (!sameSet(selectedMessageIds(), ids)) return 'selectionChanged';
  Mail.activate();
  delay(0.2);
  return clickMenuCommand(input.titles || []);
}

// Selecting emails. Mail's Archive and Delete act on Mail's selection, and a batch acts on some of
// the selected emails, so the bridge selects exactly an action's emails first. JXA cannot set a
// viewer's selection, so that one step is AppleScript, built from escaped names and integer ids.
// Reading the selection back is the gate: a command never runs unless Mail selected exactly these.

/**
 * Runs AppleScript in this process. Returns 0, or Mail's error number. Only the number: Mail's error
 * text can quote mailbox names.
 */
function runAppleScript(source) {
  return runAppleScriptValue(source).error;
}

/**
 * Runs AppleScript in this process. Returns { error, value }: error is 0 or Mail's error number,
 * value the script's result as an integer, when it is one. Nil from NSAppleScript is a failure,
 * even when its error details cannot be read.
 */
function runAppleScriptValue(source) {
  const error = Ref();
  const result = $.NSAppleScript.alloc.initWithSource($(source)).executeAndReturnError(error);
  const isNil = (x) => !x || (typeof x.isNil === 'function' && x.isNil());
  if (!isNil(result)) {
    return { error: 0, value: attempt(() => Number(result.int32Value), null) };
  }
  const number = attempt(() => {
    const value = error[0].objectForKey('NSAppleScriptErrorNumber');
    return isNil(value) ? -1 : Number(value.intValue);
  }, -1);
  return { error: number || -1, value: null };
}

// Ways of naming one email to Mail, tried in order. Not `message id N`: in Mail's dictionary
// `message id` is the Message-ID property, so that form does not compile.
const MESSAGE_FORMS = {
  // By its mailbox, segment by segment, and its numeric id.
  nested: (account, ref) =>
    '(first message of (' + mailboxReference(account, ref.mailbox) + ') whose id is ' + Math.floor(Number(ref.id)) + ')',
  // By the mailbox's whole path as one name, as some accounts name nested mailboxes.
  wholePath: (account, ref) =>
    '(first message of (mailbox ' + appleScriptText(ref.mailbox) + ' of account ' + appleScriptText(account) +
    ') whose id is ' + Math.floor(Number(ref.id)) + ')',
  // By its Message-ID within the mailbox.
  messageId: (account, ref) =>
    '(first message of (' + mailboxReference(account, ref.mailbox) + ') whose message id is ' +
    appleScriptText(String(ref.messageId || '')) + ')',
};

/**
 * Asks Mail to select exactly these emails, named one way. Returns 0 once the selection read back
 * is exactly `messageIds`, else Mail's error number, or 1 when Mail answered but selected something
 * else.
 */
function selectExactly(accountName, refs, messageIds, form) {
  if (!refs.length || refs.length !== messageIds.length) return 1;
  const name = MESSAGE_FORMS[form || 'nested'];
  const source = [
    'tell application "Mail"',
    'if (count of message viewers) is 0 then make new message viewer',
    'set selected messages of message viewer 1 to {' + refs.map((r) => name(accountName, r)).join(', ') + '}',
    'end tell',
  ].join('\n');
  const error = runAppleScript(source);
  if (error) return error;
  return until(() => sameSet(selectedMessageIds(), messageIds), 2) ? 0 : 1;
}

/** Forms selectForAction tries, in order. */
const SELECT_FORMS = Object.keys(MESSAGE_FORMS);

/**
 * Selects `input.select` in Mail: the messages Mail was showing, then the copies filing uses, each
 * named every way Mail may take, then again after showing the mailbox the owner was viewing.
 * Returns { selected, errors }: errors are the numbers of the attempts that failed, for the window.
 */
function selectForAction(input) {
  const emails = input.select || [];
  const ids = input.messageIds || [];
  const errors = [];
  const refs = (key) =>
    emails.map((e) => e[key] && Object.assign({ messageId: e.messageId }, e[key])).filter((r) => r && r.mailbox);
  const tryAll = () => {
    for (const key of ['view', 'placement']) {
      for (const form of SELECT_FORMS) {
        const result = selectExactly(input.account, refs(key), ids, form);
        if (result === 0) return true;
        errors.push(result);
      }
    }
    return false;
  };
  if (tryAll()) return { selected: true, errors };
  const viewed = (input.viewed || [])[0];
  const selected = Boolean(viewed && showMailbox(accountNamed(input.account), viewed) && tryAll());
  return { selected, errors };
}

/** A batch's email as `opening` lists it: what Mail shows, with no text and no search for copies. */
function lightRef(message, date) {
  const mailbox = message.mailbox();
  return {
    id: message.id(),
    mailbox: pathOf(mailbox),
    account: attempt(() => mailbox.account().name(), '') || '',
    date,
    messageId: attempt(() => message.messageId(), '') || '',
    from: attempt(() => message.sender(), '') || '',
    subject: attempt(() => message.subject(), '') || '',
  };
}

function batchOpening(selected) {
  const scanned = selected.slice(0, MAX_BATCH_SCAN);
  const dates = scanned.map((m) => attempt(() => m.dateReceived().getTime(), 0));
  const order = scanned
    .map((_, i) => i)
    .sort((a, b) => dates[b] - dates[a])
    .slice(0, MAX_BATCH);
  const messages = order.map((i) => lightRef(scanned[i], dates[i]));
  const accounts = mailAccounts();
  const owner = messages.length ? accounts.find((a) => a.name === messages[0].account) : null;
  return {
    selection: { running: true, total: selected.length, messages, latest: null },
    accounts,
    labels: owner ? labelsOf(owner.name) : null,
    viewed: owner ? viewedPaths(owner.name) : [],
  };
}

/** Finds the copy filing acts on, as `opening` does for one email, and reads the text. */
function readRef(account, input, viewedByAccount, inboxes) {
  const box = attempt(() => resolve(account, input.mailbox), null);
  const message = box
    ? attempt(() => {
        const m = box.messages.byId(input.id);
        m.id();
        return m;
      }, null)
    : null;
  if (!message) return { messageId: input.messageId, found: false };
  const messageId = input.messageId || attempt(() => message.messageId(), '') || '';
  const ref = { id: input.id, mailbox: input.mailbox, account: account.name(), messageId };
  const where = placed(ref, messageId, viewedByAccount);
  return {
    messageId,
    found: true,
    placement: { id: where.id, mailbox: where.mailbox, inInbox: isInInbox(where, inboxes) },
    email: readEmail(message),
  };
}

/** Emails from this sender address in the Trash, newest first, leaving out `excluded`. */
function trashMatches(trash, address, excluded, limit) {
  if (address.indexOf('@') < 0) return [];
  const hits = trash.messages.whose({ sender: { _contains: address } });
  const senders = attempt(() => hits.sender(), []) || [];
  const subjects = attempt(() => hits.subject(), []) || [];
  const ids = attempt(() => hits.messageId(), []) || [];
  const dates = attempt(() => hits.dateReceived(), []) || [];
  return senders
    .map((from, i) => ({
      from: String(from || ''),
      subject: String(subjects[i] || ''),
      messageId: ids[i],
      date: dates[i] ? new Date(dates[i]).getTime() : 0,
    }))
    .filter((m) => senderAddress(m.from) === address && excluded.indexOf(m.messageId) < 0)
    .sort((a, b) => b.date - a.date)
    .slice(0, limit)
    .map((m) => ({ from: m.from, subject: m.subject }));
}

// Commands

const commands = {
  // Everything the window needs when it opens, in one process, so that it fills quickly.
  opening() {
    if (!Mail.running()) {
      return { selection: { running: false, total: 0, messages: [], latest: null }, accounts: [], labels: null };
    }
    const selected = currentSelection();
    if (selected.length > 1) return batchOpening(selected);
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

  // Places and reads some emails of a batch. Reading never changes a message.
  read(input) {
    const account = accountNamed(input.account);
    const viewedByAccount = new Map([[input.account, input.viewed || []]]);
    const inboxes = new Map();
    return { items: (input.refs || []).map((ref) => readRef(account, ref, viewedByAccount, inboxes)) };
  },

  file(input) {
    const kind = kindOf(input.account);
    const account = Mail.accounts.byName(input.account);
    return { filed: fileMessages(account, input.target, input.items, kind) };
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
  // filed emails. With `select` (a batch), it first selects exactly them.
  archive(input) {
    const account = accountNamed(input.account);
    const ids = input.messageIds || [];
    if (!ids.length) return { result: 'selectionChanged' };
    const problem = clickOnExactly(input, ids);
    if (problem) return withSelectErrors(input, { result: problem });
    const inbox = resolve(account, 'INBOX');
    const left = () =>
      ids.filter((messageId) => (attempt(() => inbox.messages.whose({ messageId })().length, 0) || 0) > 0);
    if (until(() => left().length === 0, 10 + ids.length)) return { result: 'archived' };
    return { result: 'stillThere', left: left() };
  },

  // Emails from the same sender in the account's Trash, newest first: sender and subject only.
  // They tell the recommender that the owner deletes emails like this one. Also says whether the
  // selected emails are in the Trash already. Reading never changes a message. With `senders` (a
  // batch), it answers for each sender address, and says which of the emails are in the Trash.
  trashSimilar(input) {
    const account = accountNamed(input.account);
    const batch = Array.isArray(input.senders);
    const trash = trashOf(account);
    const selected = input.messageIds || [];
    const limit = Math.min(Math.max(Number(input.limit) || 20, 1), MAX_TRASH_MATCHES);
    if (!batch) {
      if (!trash) return { found: false, inTrash: false, messages: [] };
      const inTrash = selected.some((messageId) => holds(trash, messageId));
      return { found: true, inTrash, messages: trashMatches(trash, senderAddress(input.sender || ''), selected, limit) };
    }
    if (!trash) return { found: false, inTrash: false, inTrashIds: [], bySender: {}, messages: [] };
    const inTrashIds = selected.filter((messageId) => holds(trash, messageId));
    const bySender = {};
    for (const sender of input.senders) {
      const address = senderAddress(sender || '');
      if (!Object.prototype.hasOwnProperty.call(bySender, address)) {
        bySender[address] = trashMatches(trash, address, selected, limit);
      }
    }
    return { found: true, inTrash: inTrashIds.length > 0, inTrashIds, bySender, messages: [] };
  },

  // Moves the selected emails to the Trash with Mail's own Delete command, as the owner would. It
  // acts on what is selected in Mail, so it only runs if that is exactly these emails. With `select`
  // (a batch), it first selects exactly them. In the Trash itself, Mail's Delete erases for good, so
  // emails that are there already are refused, before anything is selected.
  trash(input) {
    const account = accountNamed(input.account);
    const ids = input.messageIds || [];
    if (!ids.length) return { result: 'selectionChanged' };
    const trash = trashOf(account);
    if (!trash) return { result: 'noTrash' };
    if (ids.some((messageId) => holds(trash, messageId))) return { result: 'alreadyInTrash' };
    const problem = clickOnExactly(input, ids);
    if (problem) return withSelectErrors(input, { result: problem });
    const missing = () => ids.filter((messageId) => !holds(trash, messageId));
    if (until(() => missing().length === 0, 15 + ids.length)) return { result: 'trashed' };
    return { result: 'notInTrash', left: missing() };
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
    // A batch selects some emails in Mail before Archive or Delete (specs/004-batch-recommendations).
    step('selectSubset', () => {
      let box = message ? message.mailbox() : null;
      if (!box) return false;
      if (holding(box).length < 3 && input.mbox) {
        Mail.importMailMailbox({ at: Path(input.mbox) });
        until(() => (findMessage() !== null && holding(findMessage().mailbox()).length >= 3), 30);
        box = findMessage().mailbox();
      }
      const all = holding(box);
      if (all.length < 3) return false;
      const name = box.name();
      const show = 'tell application "Mail" to set selected mailboxes of message viewer 1 to {mailbox ' +
        appleScriptText(name) + '}';
      $.NSAppleScript.alloc.initWithSource($(show)).executeAndReturnError(Ref());
      delay(1);
      const two = all.slice(0, 2);
      const wanted = two.map((m) => m.messageId());
      const select = 'tell application "Mail" to set selected messages of message viewer 1 to {' +
        two
          .map((m) => '(first message of mailbox ' + appleScriptText(name) + ' whose id is ' + Math.floor(Number(m.id())) + ')')
          .join(', ') +
        '}';
      $.NSAppleScript.alloc.initWithSource($(select)).executeAndReturnError(Ref());
      return until(() => sameSet(selectedMessageIds(), wanted), 3);
    });
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

// Real account, run only by the owner, with three or more emails selected in the Inbox. Checks that
// Mail lets the app select some of them, as a batch does before Archive or Delete, then restores
// the selection. It changes no email, and reports booleans and pass or fail only.
commands.selftestSelection = function selftestSelection() {
  const selected = currentSelection();
  if (selected.length < 3) throw fail(NOT_FOUND, 'select three or more emails in the Inbox first');
  const first = messageRef(selected[0], new Map(), new Map());
  const account = first.account;
  if (!account) throw fail(NOT_FOUND, 'select emails in an account, not under On My Mac');
  const ids = selected.map((m) => attempt(() => m.messageId(), '') || '');
  const original = selected.map((m) => ({ id: m.id(), mailbox: pathOf(m.mailbox()) }));
  const viewedByAccount = new Map();
  const two = selected.slice(0, 2);
  const wanted = ids.slice(0, 2);
  const view = two.map((m) => ({ id: m.id(), mailbox: pathOf(m.mailbox()) }));
  const placement = two.map((m) => {
    const ref = messageRef(m, viewedByAccount, new Map());
    return { id: ref.id, mailbox: ref.mailbox };
  });
  const steps = {};
  // Whether a failing AppleScript is noticed at all.
  steps.errorsSeen = runAppleScript('error "check" number 4242') !== 0 ? 'pass' : 'fail';
  const viewers = runAppleScriptValue('tell application "Mail" to count message viewers');
  steps.viewers = viewers.error ? 'error ' + viewers.error : viewers.value;
  // Whether AppleScript sees the same selection as the app.
  const seen = runAppleScriptValue('tell application "Mail" to count (selected messages of message viewer 1)');
  steps.sameViewer = seen.error ? 'error ' + seen.error : seen.value === selected.length ? 'pass' : 'fail';
  // Narrowing the selection to emails Mail itself hands over, with no naming at all.
  const narrowed = runAppleScript(
    'tell application "Mail" to set selected messages of message viewer 1 to items 1 thru 2 of (get selected messages of message viewer 1)',
  );
  steps.narrowItself = narrowed
    ? 'error ' + narrowed
    : until(() => selectedMessageIds().length === 2, 2) ? 'pass' : 'fail';
  for (const form of SELECT_FORMS) {
    const pick = (refs) => selectExactly(account, refs.map((r, i) => Object.assign({ messageId: wanted[i] }, r)), wanted, form);
    const label = form.charAt(0).toUpperCase() + form.slice(1);
    const v = pick(view);
    steps['selectView' + label] = v === 0 ? 'pass' : v === 1 ? 'fail' : 'error ' + v;
    const p = pick(placement);
    steps['selectPlacement' + label] = p === 0 ? 'pass' : p === 1 ? 'fail' : 'error ' + p;
  }
  const back = original.map((o, i) => Object.assign({ messageId: ids[i] }, o));
  const restored = SELECT_FORMS.some((form) => selectExactly(account, back, ids, form) === 0);
  steps.restored = restored ? 'pass' : 'fail';
  return { steps };
};

// The same check for an account with folders. The owner's email never moves: a copy of it goes to
// a temporary folder, and that copy is what gets moved, into a folder under it. A move once took an
// owner's email out of the Inbox and Mail never showed it again, so the original is left alone.
// The folders stay, holding the copy, for the owner to delete.
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
  // Counted before and after, so that copies left by an earlier run on the same email pass nothing.
  const inFirst = copies(first).length;
  const inNested = copies(nested).length;
  const copied = step('copyThroughFiling', () => {
    fileMessages(account, first, [{ id: ref.id, mailbox: ref.mailbox, mode: 'copy' }], 'folders');
    return until(() => copies(first).length > inFirst, 60);
  });
  if (copied) {
    step('moveThroughFiling', () => {
      const copy = copies(first)[0];
      fileMessages(account, nested, [{ id: copy.id(), mailbox: first, mode: 'move' }], 'folders');
      return until(() => copies(nested).length > inNested, 60);
    });
    step('leftTheFolder', () => until(() => copies(first).length === inFirst, 60));
  }
  step('originalStayedInInbox', () => copies(ref.mailbox).length > 0);
  // The self-test's own folders, as Mail lists them: fixed names, nothing of the owner's.
  const own = (name) => String(name).indexOf(SELF_TEST_PREFIX) === 0;
  const listed = account.mailboxes.name().filter(own);
  return { steps, listed, paths: allPaths(account).filter(own) };
}

// Puts back what a self-test of a folder account left in its own folders: every email in a folder
// whose name starts with the self-test's prefix goes to that account's Inbox, unless the Inbox has
// it already, as it has the originals of the copies the self-test now makes. Only the self-test
// puts emails there. Reports counts only.
commands.selftestRecover = function () {
  const report = [];
  for (const entry of mailAccounts().filter((a) => a.kind === 'folders')) {
    const account = Mail.accounts.byName(entry.name);
    const inboxPath = inboxName(entry.name);
    const inbox = inboxPath ? topLevel(account, inboxPath) : null;
    const names = account.mailboxes.name();
    const folders = [];
    names.forEach((name, i) => {
      if (String(name).indexOf(SELF_TEST_PREFIX) === 0) folders.push(account.mailboxes[i]);
    });
    const held = () =>
      folders.map((folder) => attempt(() => folder.messages.length, -1)).reduce((x, y) => Math.max(x, y), 0);
    const one = { folders: folders.length, inboxFound: inbox !== null, found: held(), moved: 0, inInbox: 0, errors: [] };
    if (inbox) {
      const seen = new Set();
      for (const folder of folders) {
        const messages = attempt(() => folder.messages(), []) || [];
        for (const message of messages) {
          const key = attempt(() => message.messageId(), null) || 'id-' + attempt(() => message.id(), 0);
          if (seen.has(key)) continue;
          seen.add(key);
          const messageId = attempt(() => message.messageId(), null);
          if (messageId && holds(inbox, messageId)) {
            one.inInbox++;
            continue;
          }
          try {
            moveMessage(message, inbox);
            one.moved++;
          } catch (e) {
            one.errors.push(errorNumber(e));
          }
        }
      }
      one.left = until(() => held() <= one.inInbox, 30) ? 0 : held();
    }
    report.push(one);
  }
  return { accounts: report };
};

// Where an email that a self-test moved could be: asks Mail to check the folder accounts again,
// then counts the emails in each of the self-test's folders, and in Mail's own "Recovered Messages"
// under On My Mac, where Mail puts what it could not store in an account. Counts only.
commands.selftestLocate = function () {
  const count = (box) => {
    try {
      return box.messages.length;
    } catch (e) {
      return 'error ' + errorNumber(e);
    }
  };
  const accounts = mailAccounts()
    .filter((a) => a.kind === 'folders')
    .map((entry) => {
      const account = Mail.accounts.byName(entry.name);
      const synchronized = attempt(() => (Mail.synchronize({ with: account }), true), false);
      const indexes = [];
      account.mailboxes.name().forEach((name, i) => {
        if (String(name).indexOf(SELF_TEST_PREFIX) === 0) indexes.push(i);
      });
      const counts = () => indexes.map((i) => count(account.mailboxes[i]));
      const before = counts();
      until(() => counts().some((n) => n > 0), 25);
      const inboxPath = inboxName(entry.name);
      const inbox = inboxPath ? topLevel(account, inboxPath) : null;
      return {
        synchronized,
        selfTestFolders: indexes.length,
        nested: indexes.map((i) => account.mailboxes.name()[i].indexOf('/') > 0),
        before,
        after: counts(),
        inbox: inbox ? count(inbox) : null,
      };
    });
  const localNames = attempt(() => Mail.mailboxes.name(), []) || [];
  const recovered = [];
  localNames.forEach((name, i) => {
    if (/recovered|helyre|wiederher|r\u00e9cup|recuper/i.test(String(name))) recovered.push(count(Mail.mailboxes[i]));
  });
  return { accounts, localMailboxes: localNames.length, recoveredMailboxes: recovered };
};

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
