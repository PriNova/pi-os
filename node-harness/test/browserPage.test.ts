import assert from "node:assert/strict";
import { test } from "node:test";
import { runInNewContext } from "node:vm";
import { PAGE_SCRIPT } from "../src/browser/pageScript.js";

function page() {
  let doc: any;
  class Element {
    nodeType = 1; tagName: string; attributes: Record<string, string>; childNodes: any[] = [];
    parentElement: Element | null = null; isConnected = true; isContentEditable = false; readOnly = false; isDisabled = false;
    value = ""; textContent = ""; innerText = ""; labels: any[] = []; id = ""; clicked = 0; terminal = false;
    rect = { left: 10, top: 10, right: 210, bottom: 50, width: 200, height: 40 };
    constructor(tag: string, attributes: Record<string, string> = {}) { this.tagName = tag; this.attributes = attributes; }
    get type() { return this.attributes.type ?? "text"; }
    get href() { return this.attributes.href; }
    get target() { return this.attributes.target; }
    getAttribute(k: string) { return this.attributes[k] ?? null; }
    hasAttribute(k: string) { return k in this.attributes; }
    matches(selector: string) {
      if (selector === ':disabled') return this.isDisabled;
      if (selector.includes('input[type=password]')) return this.tagName === 'INPUT' && (this.type === 'password' || ['one-time-code', 'cc-number', 'cc-csc'].includes(this.attributes.autocomplete ?? ''));
      return false;
    }
    closest(selector: string): Element | null {
      if (selector === '.xterm,[data-terminal]') return this.terminal ? this : null;
      if (selector === 'a[href]') return this.tagName === 'A' && this.hasAttribute('href') ? this : this.parentElement?.closest(selector) ?? null;
      if (selector.startsWith('article') || selector.startsWith('article,')) return this.tagName === 'ARTICLE' ? this : this.parentElement?.closest(selector) ?? null;
      return null;
    }
    getBoundingClientRect() { return this.rect; }
    getRootNode() { return doc; }
    contains(other: Element) { return this === other || this.childNodes.some(e => e === other); }
    click() { this.clicked++; }
    focus() { doc.activeElement = this; }
    select() {}
    scrollBy() {}
  }
  class Input extends Element { constructor(attributes: Record<string, string>) { super('INPUT', attributes); } }
  class TextArea extends Element {}
  const body = new Element('BODY');
  const button = new Element('BUTTON', { 'aria-label': 'Like fixture' }); button.innerText = 'Like fixture';
  const input = new Input({ 'aria-label': 'Test note' });
  const password = new Input({ type: 'password', 'aria-label': 'Password' }); password.value = 'do-not-expose-this';
  const article = new Element('ARTICLE'); article.innerText = 'Pinned post by Author A';
  button.parentElement = article; article.childNodes = [button]; article.parentElement = body;
  input.parentElement = body; password.parentElement = body; body.childNodes = [article, input, password];
  let covered = false;
  doc = { body, scrollingElement: body, visibilityState: 'visible', activeElement: null, getElementById: () => null, elementFromPoint: () => covered ? body : button };
  const context: any = { document: doc, Element, HTMLElement: Element, HTMLInputElement: Input, HTMLTextAreaElement: TextArea,
    getComputedStyle: () => ({ display: 'block', visibility: 'visible', opacity: '1' }), innerWidth: 800, innerHeight: 600,
    location: { href: 'https://fixture.test/' }, URL };
  runInNewContext(PAGE_SCRIPT, context);
  return { helper: context.__piBrowser, button, input, password, article, body, doc, covered: (value: boolean) => { covered = value; } };
}
function buttonRef(snapshot: any) { return /^\[([^\]]+)\] button/m.exec(snapshot.text)![1]!; }

test("isolated helper omits password values, creates semantic refs and permits an ordinary Like", () => {
  const p = page(), snapshot = p.helper.snapshot('', 'test-');
  assert(!snapshot.text.includes('do-not-expose-this'));
  assert.match(snapshot.text, /credential field; value omitted; input blocked/);
  assert.match(snapshot.text, /Test note/);
  const ref = buttonRef(snapshot);
  assert.equal(p.helper.act(ref, 'click').ok, true); assert.equal(p.button.clicked, 1);
});

test("helper deletion checks run immediately before activation, including localized labels and identifiers", () => {
  for (const label of ['Delete', 'Delete file', 'Move to Trash', 'Empty Trash', 'Datei löschen', 'In den Papierkorb legen']) {
    const p = page(); p.button.attributes['aria-label'] = label;
    const ref = buttonRef(p.helper.snapshot('', 'x-'));
    assert.equal(p.helper.act(ref, 'click').error, 'file_deletion_blocked', label);
    assert.equal(p.helper.act(ref, 'press', 'Enter').error, 'file_deletion_blocked', label);
    assert.equal(p.button.clicked, 0);
  }
  const p = page(); p.button.id = 'delete-file-control';
  assert.equal(p.helper.act(buttonRef(p.helper.snapshot('', 'x-')), 'click').error, 'file_deletion_blocked');
});

test("recycled post contexts, stale refs, changed labels, disabled, covered and detached nodes do not click", () => {
  for (const change of [
    (p: ReturnType<typeof page>) => { p.article.innerText = 'Different post by Author B'; },
    (p: ReturnType<typeof page>) => { p.button.attributes['aria-label'] = 'Delete file'; },
    (p: ReturnType<typeof page>) => { p.button.isDisabled = true; },
    (p: ReturnType<typeof page>) => { p.button.isConnected = false; },
  ]) {
    const p = page(), ref = buttonRef(p.helper.snapshot('', 'old-')); change(p);
    assert.equal(p.helper.act(ref, 'click').error, 'browser_stale'); assert.equal(p.button.clicked, 0);
  }
  const p = page(), ref = buttonRef(p.helper.snapshot('', 'old-')); p.covered(true);
  assert.equal(p.helper.act(ref, 'click').error, 'browser_occluded'); assert.equal(p.button.clicked, 0);
  p.covered(false); p.helper.snapshot('', 'new-');
  assert.equal(p.helper.act(ref, 'click').error, 'browser_stale');
});

test("hidden tabs and security autocomplete fields fail before mutation", () => {
  const p = page(), ref = buttonRef(p.helper.snapshot('', 'x-'));
  p.doc.visibilityState = 'hidden';
  assert.equal(p.helper.act(ref, 'click').error, 'browser_target_changed'); assert.equal(p.button.clicked, 0);
  p.doc.visibilityState = 'visible'; p.input.attributes.autocomplete = 'section-account current-password';
  p.input.value = 'SECOND-PRIVATE-CANARY';
  const snapshot = p.helper.snapshot('', 'new-');
  assert(!snapshot.text.includes('SECOND-PRIVATE-CANARY')); assert.match(snapshot.text, /credential field; value omitted; input blocked/);
});

test("explicit username/password fields are default-blocked and can be enabled without exposing their values", () => {
  for (const attrs of [
    { 'aria-label': 'Username' }, { 'aria-label': 'Benutzername' }, { 'aria-label': 'Username or email' },
    { 'aria-label': 'Current password' }, { 'aria-label': 'Passwort' }, { autocomplete: 'username' },
    { autocomplete: 'section-account new-password' }, { name: 'login-username' }, { type: 'password' },
  ]) {
    const p = page(); Object.assign(p.input.attributes, attrs); p.input.value = 'PRIVATE-INPUT-CANARY';
    p.doc.elementFromPoint = () => p.input;
    const snapshot = p.helper.snapshot('', 'x-'); const ref = /^\[([^\]]+)\] textbox/m.exec(snapshot.text)![1]!;
    assert.match(snapshot.text, /input blocked/); assert(!snapshot.text.includes('PRIVATE-INPUT-CANARY'));
    assert.equal(p.helper.act(ref, 'fill').error, 'credential_input_blocked');
    assert.equal(p.helper.act(ref, 'fill', undefined, undefined, true).ok, true);
    assert.equal(p.helper.verifyFill(ref, 'PRIVATE-INPUT-CANARY', true), true);
    const enabled = p.helper.snapshot('', 'enabled-', true); assert.match(enabled.text, /input allowed/);
    assert(!enabled.text.includes('PRIVATE-INPUT-CANARY'));
    const newRef = /^\[([^\]]+)\] textbox/m.exec(enabled.text)![1]!;
    assert.equal(p.helper.act(newRef, 'fill', undefined, undefined, false).error, 'credential_input_blocked');
  }
});

test("ordinary fields, OTP/payment fields and Like remain available with a password field focused", () => {
  for (const attrs of [ {}, { 'aria-label': 'Email' }, { 'aria-label': 'Search password documentation' }, { autocomplete: 'one-time-code' }, { autocomplete: 'cc-number' } ]) {
    const p = page(); Object.assign(p.input.attributes, attrs); p.doc.activeElement = p.password;
    const snapshot = p.helper.snapshot('', 'x-'); const ref = /^\[([^\]]+)\] textbox/m.exec(snapshot.text)![1]!;
    assert.equal(p.helper.act(buttonRef(snapshot), 'click').ok, true);
    p.doc.elementFromPoint = () => p.input;
    assert.equal(p.helper.act(ref, 'fill').ok, true);
  }
  const p = page(); p.button.attributes['aria-label'] = 'Delete file';
  const ref = buttonRef(p.helper.snapshot('', 'x-', true));
  assert.equal(p.helper.act(ref, 'click', undefined, undefined, true).error, 'file_deletion_blocked');
});

test("browser links cannot escape through click OR keyboard activation", () => {
  for (const attrs of [{ href: 'javascript:alert(1)' }, { href: 'file:///tmp/x' }, { href: 'https://fixture.test/next', target: '_blank' }, { href: 'https://fixture.test/x', download: '' }]) {
    const p = page(); p.button.tagName = 'A'; Object.assign(p.button.attributes, attrs);
    const snapshot = p.helper.snapshot('', 'x-'); const ref = /^\[([^\]]+)\] link/m.exec(snapshot.text)![1]!;
    assert.equal(p.helper.act(ref, 'click').error, 'browser_unsupported_link');
    assert.equal(p.helper.act(ref, 'press', 'Enter').error, 'browser_unsupported_link');
    assert.equal(p.button.clicked, 0);
  }
});

test("terminal surfaces permit ordinary typing, not clearly destructive commands", () => {
  const p = page(); p.input.terminal = true; p.doc.elementFromPoint = () => p.input;
  const snapshot = p.helper.snapshot('', 'x-'), ref = /^\[([^\]]+)\] textbox/m.exec(snapshot.text)![1]!;
  assert.equal(p.helper.act(ref, 'fill', undefined, undefined, false, 'git status').ok, true);
  for (const command of ['rm example.txt', 'sudo rm -rf tmp', 'find . -delete', 'os.remove("example.txt")']) {
    assert.equal(p.helper.act(ref, 'fill', undefined, undefined, true, command).error, 'file_deletion_blocked');
  }
});

test("multiline fill rejects single-line fields before focus and permits multiline receivers", () => {
  const p = page(); p.doc.elementFromPoint = () => p.input;
  const snapshot = p.helper.snapshot('', 'x-'), ref = /^\[([^\]]+)\] textbox/m.exec(snapshot.text)![1]!;
  assert.equal(p.helper.act(ref, 'fill', undefined, undefined, false, 'first\nsecond').error, 'browser_unsupported_action');
  assert.equal(p.doc.activeElement, null);
  p.input.isContentEditable = true;
  const fresh = p.helper.snapshot('', 'new-'), newRef = /^\[([^\]]+)\] textbox/m.exec(fresh.text)![1]!;
  assert.equal(p.helper.inspect(newRef, 'fill', undefined, false, 'first\nsecond').ok, true);
});

test("ordinary text editing stays allowed but Delete outside an editable field is refused", () => {
  const p = page(), snapshot = p.helper.snapshot('', 'x-');
  const input = /^\[([^\]]+)\] textbox/m.exec(snapshot.text)![1]!;
  p.doc.elementFromPoint = () => p.input;
  assert.equal(p.helper.act(input, 'fill').ok, true); assert.equal(p.doc.activeElement, p.input);
  assert.equal(p.helper.inspect(input, 'press', 'Backspace').ok, true);
  assert.equal(p.helper.inspect(buttonRef(snapshot), 'press', 'Delete').error, 'file_deletion_blocked');
});
