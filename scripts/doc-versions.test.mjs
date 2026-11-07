// SPDX-License-Identifier: Apache-2.0
// Execute the actual embedded browser asset with a small DOM, without network or
// a second implementation of the selector. Gleam string literals permit raw
// newlines; escape those before decoding the otherwise JSON-compatible literal.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';

const source = readFileSync(new URL('../src/tools/docgen/versions.gleam', import.meta.url), 'utf8');
const literal = source.slice(source.indexOf('pub const javascript =') + 'pub const javascript ='.length).trim();
const script = JSON.parse(literal.replace(/\r?\n/g, '\\n'));
const origin = 'https://pooka-stdlib.hexdocs.pm';
class Element {
  children = [];
  listeners = {};
  hidden = false;
  appendChild(child) { this.children.push(child); }
  replaceChildren() { this.children = []; }
  addEventListener(event, callback) { this.listeners[event] = callback; }
}
function page({ href = origin + '/0.1.0/module-list.html', nodes, absent = false } = {}) {
  const badge = new Element();
  const select = new Element();
  select.hidden = true;
  const control = new Element();
  control.dataset = { docsUrl: origin + '/', version: '0.1.0' };
  control.querySelector = selector => selector === '[data-version-current]' ? badge : select;
  const head = new Element();
  const document = { head, createElement: () => new Element(), querySelector: () => absent ? null : control };
  const assigned = [];
  const location = new URL(href);
  location.assign = value => assigned.push(value);
  const window = { location };
  if (nodes !== undefined) window.versionNodes = nodes;
  runInNewContext(script, { document, window, URL });
  return { badge, select, head, window, assigned };
}
const releases = [
  { version: 'v0.2.0', url: origin + '/0.2.0', latest: true },
  { version: 'v0.1.0', url: origin + '/0.1.0' },
  { version: 'v0.1.0-rc1', url: origin + '/0.1.0-rc1' },
];

test('local files and alternate hosts keep the badge and make no request', () => {
  for (const href of ['file:///tmp/docs/index.html', 'http://localhost:8000/', 'https://example.org/']) {
    const p = page({ href, nodes: releases });
    assert.equal(p.badge.hidden, false);
    assert.equal(p.select.hidden, true);
    assert.equal(p.head.children.length, 0);
  }
});

test('published versions select the active release without mutating the host list', () => {
  const p = page({ nodes: releases });
  assert.equal(p.badge.hidden, true);
  assert.equal(p.select.hidden, false);
  assert.deepEqual(p.select.children.map(option => option.textContent), ['v0.2.0 (latest)', 'v0.1.0', 'v0.1.0-rc1']);
  assert.equal(p.select.children[1].selected, true);
  assert.equal(p.select.children[1].disabled, true);
  assert.equal(releases.length, 3);
});

test('old version pages load the current package-root history', () => {
  const p = page();
  assert.equal(p.head.children.length, 1);
  assert.equal(p.head.children[0].src, origin + '/docs_config.js');
  assert.equal(p.select.hidden, true);
  p.window.versionNodes = releases;
  p.head.children[0].onload();
  assert.equal(p.select.hidden, false);
});

test('missing or unavailable history leaves the ordinary version visible', () => {
  const p = page();
  p.head.children[0].onerror();
  p.head.children[0].onload();
  assert.equal(p.select.hidden, true);
  assert.equal(p.badge.hidden, false);
  assert.equal(page({ nodes: [] }).select.hidden, true);
  assert.equal(page({ absent: true }).head.children.length, 0);
});

test('the current version remains visible while its release is being indexed', () => {
  const p = page({ nodes: [releases[0]] });
  assert.equal(p.select.children.length, 2);
  assert.equal(p.select.children[0].textContent, 'v0.1.0');
  assert.equal(p.select.children[0].selected, true);
  assert.equal(p.select.children[0].disabled, true);
});

test('malformed, cross-package and active-content entries are ignored', () => {
  const bad = [null, {}, { version: '<script>', url: origin + '/0.1.0' },
    { version: 'v0.3.0', url: 'javascript:alert(1)' },
    { version: 'v0.3.0', url: 'https://other.hexdocs.pm/0.3.0' },
    { version: 'v0.3.0', url: 'https://user:secret@pooka-stdlib.hexdocs.pm/0.3.0' },
    { version: 'v0.3.0', url: origin + '/other-path' },
    { version: 'v0.3.0', url: origin + '/0.3.0?redirect=other' },
    { version: 'v0.3.0', url: origin + '/0.3.0#other' }];
  assert.equal(page({ nodes: bad }).select.hidden, true);
  const p = page({ nodes: [...bad, ...releases, releases[0]] });
  assert.equal(p.select.children.length, 3);
});

test('selection navigates only to validated release roots', () => {
  const p = page({ nodes: releases });
  p.select.value = 'https://other.example/';
  p.select.listeners.change();
  assert.equal(p.assigned.length, 0);
  p.select.value = origin + '/0.2.0';
  p.select.listeners.change();
  assert.deepEqual(p.assigned, [origin + '/0.2.0']);
});
