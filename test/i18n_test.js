// Runs html/i18n.js against a tiny stand-in for the page (no browser needed): texts, tooltips and later changes are translated, and English comes back.
// Run:  node test/i18n_test.js
'use strict';
const assert = require('assert');
const fs = require('fs');
const path = require('path');

// ---- a tiny DOM -------------------------------------------------------------------------------
const TEXT = 3;
const ELEMENT = 1;
const DOCUMENT = 9;
class TextNode { constructor(value) { this.nodeType = TEXT; this.nodeValue = value; this.parentNode = null; this.nodeName = '#text'; } }
class El {
  constructor(name, attrs = {}) { this.nodeType = ELEMENT; this.nodeName = name.toUpperCase(); this.attrs = { ...attrs }; this.childNodes = []; this.parentNode = null; }
  getAttribute(n) { return Object.prototype.hasOwnProperty.call(this.attrs, n) ? this.attrs[n] : null; }
  setAttribute(n, v) { this.attrs[n] = v; }
  append(...nodes) { nodes.forEach((n) => { n.parentNode = this; this.childNodes.push(n); }); return this; }
}
const t = (s) => new TextNode(s);
const body = new El('body');
const doc = { nodeType: DOCUMENT, body, documentElement: { lang: '' } };
global.document = doc;
global.Node = { TEXT_NODE: TEXT, ELEMENT_NODE: ELEMENT, DOCUMENT_NODE: DOCUMENT };
global.NodeFilter = { SHOW_ELEMENT: 1, SHOW_TEXT: 4, FILTER_ACCEPT: 1, FILTER_REJECT: 2 };
Object.defineProperty(global, 'navigator', { value: { language: 'de-DE' }, configurable: true });
doc.createTreeWalker = (root, _what, filter) => {
  const order = [];
  const visit = (n) => { n.childNodes.forEach((c) => { if (c.nodeType === ELEMENT && filter.acceptNode(c) === 2) return; order.push(c); if (c.nodeType === ELEMENT) visit(c); }); };
  visit(root);
  let i = 0;
  return { nextNode: () => order[i++] || null };
};
global.window = {};

// ---- the files ---------------------------------------------------------------------------------
const dir = path.join(__dirname, '..', 'easy_cabinet', 'html');
global.window.EC_LANG = {};
['de', 'zh'].forEach((code) => new Function('window', fs.readFileSync(path.join(dir, 'lang', `${code}.js`), 'utf8'))(global.window));
new Function('window', fs.readFileSync(path.join(dir, 'i18n.js'), 'utf8'))(global.window);
const I18N = global.window.EC_I18N;

// ---- the page ----------------------------------------------------------------------------------
const label = new El('span').append(t('Settings'));
const button = new El('button', { title: 'Toggle' }).append(t('  Insert  '));
const unknown = new El('p').append(t('A sentence that no file has'));
const script = new El('script').append(t('Settings'));
const area = new El('textarea').append(t('Settings'));
body.append(label, button, unknown, script, area);

assert.strictEqual(I18N.LANGUAGES.length, 17);
assert.strictEqual(I18N.resolve('auto'), 'de', 'Automatic is the language of the computer');
assert.strictEqual(I18N.resolve('xx'), 'en');

assert.strictEqual(I18N.use('de'), 'de');
assert.strictEqual(label.childNodes[0].nodeValue, 'Einstellungen');
assert.strictEqual(button.childNodes[0].nodeValue, '  Einfügen  ', 'the spaces around a text stay');
assert.strictEqual(button.attrs.title, 'Umschalten', 'a tooltip is translated too');
assert.strictEqual(unknown.childNodes[0].nodeValue, 'A sentence that no file has', 'what no file has stays English');
assert.strictEqual(script.childNodes[0].nodeValue, 'Settings', 'scripts are left alone');
assert.strictEqual(area.childNodes[0].nodeValue, 'Settings', 'so is what is typed');
assert.strictEqual(doc.documentElement.lang, 'de');

assert.strictEqual(I18N.use('zh'), 'zh', 'from one language straight to another');
assert.strictEqual(label.childNodes[0].nodeValue, '设置');
assert.strictEqual(button.attrs.title, '切换');

assert.strictEqual(I18N.use('en'), 'en');
assert.strictEqual(label.childNodes[0].nodeValue, 'Settings', 'English comes back');
assert.strictEqual(button.childNodes[0].nodeValue, '  Insert  ');
assert.strictEqual(button.attrs.title, 'Toggle');

// text the panel writes later, once the language is in use
I18N.use('de');
label.childNodes[0].nodeValue = 'Delete';
I18N.use('de');
assert.strictEqual(label.childNodes[0].nodeValue, 'Löschen');
I18N.use('en');
assert.strictEqual(label.childNodes[0].nodeValue, 'Delete');

assert.strictEqual(I18N.use('auto'), 'de');
console.log('i18n: all good');
