// The languages of the panel. The words of the panel are written in English in index.html; a language file (lang/<code>.js, made by
// translations/build.rb) gives the same words in that language, and this file puts them in place: every text, tooltip and placeholder of the page
// whose English is in the file is shown translated, also what the panel writes later (lists, messages). Words a file does not have stay English.
(function () {
  'use strict';

  // [code, the name of the language in that language]. Arabic and Hebrew are written right to left, which the panel does not follow yet.
  const LANGUAGES = [
    ['ar', 'العربية (experimental, no rtl)'], ['cs', 'Čeština'], ['de', 'Deutsch'], ['en', 'English'], ['es', 'Español'], ['fr', 'Français'],
    ['he', 'עברית (experimental, no rtl)'], ['hu', 'Magyar'], ['it', 'Italiano'], ['nl', 'Nederlands'], ['pl', 'Polski'], ['pt', 'Português'],
    ['ru', 'Русский'], ['sr', 'Srpski'], ['uk', 'Українська'], ['vi', 'Tiếng Việt'], ['zh', '简体中文']
  ];
  const ATTRIBUTES = ['title', 'placeholder', 'aria-label'];
  const SKIP = new Set(['SCRIPT', 'STYLE', 'TEXTAREA']);

  let table = null; // the words of the language in use (null: English)
  let current = 'en';
  const texts = new WeakMap(); // a text node -> the English it was written with
  const attributes = new WeakMap(); // an element -> { attribute: English }
  let observer = null;

  // 'auto' (or nothing): the language of the browser when there is a file for it, else English.
  function resolve(code) {
    if (code && code !== 'auto') return LANGUAGES.some((entry) => entry[0] === code) ? code : 'en';
    const own = String(navigator.language || 'en').slice(0, 2).toLowerCase();
    return LANGUAGES.some((entry) => entry[0] === own) ? own : 'en';
  }

  function translated(english) {
    return table && Object.prototype.hasOwnProperty.call(table, english) ? table[english] : null;
  }

  // What was written, and what it is shown as: when the text is neither, the panel wrote something new there and it is English again.
  function englishOf(saved, now) {
    return saved && (now === saved.english || now === saved.shown) ? saved.english : now;
  }

  function doText(node) {
    const raw = node.nodeValue;
    const trimmed = raw.trim();
    if (!trimmed) return;
    const english = englishOf(texts.get(node), trimmed);
    const wanted = translated(english) || english;
    if (wanted !== trimmed) node.nodeValue = raw.replace(trimmed, () => wanted);
    if (wanted !== english) texts.set(node, { english, shown: wanted });
    else texts.delete(node);
  }

  function doElement(element) {
    ATTRIBUTES.forEach((name) => {
      const value = element.getAttribute(name);
      if (!value) return;
      const saved = attributes.get(element) || {};
      const english = englishOf(saved[name], value);
      const wanted = translated(english) || english;
      if (wanted !== value) element.setAttribute(name, wanted);
      if (wanted !== english) saved[name] = { english, shown: wanted };
      else delete saved[name];
      attributes.set(element, saved);
    });
  }

  function walk(root) {
    if (root.nodeType === Node.TEXT_NODE) {
      if (!root.parentNode || !SKIP.has(root.parentNode.nodeName)) doText(root);
      return;
    }
    if (root.nodeType !== Node.ELEMENT_NODE && root.nodeType !== Node.DOCUMENT_NODE) return;
    if (root.nodeType === Node.ELEMENT_NODE) {
      if (SKIP.has(root.nodeName)) return;
      doElement(root);
    }
    const scope = root.nodeType === Node.DOCUMENT_NODE ? root.body : root;
    const filter = { acceptNode: (node) => (node.nodeType === Node.ELEMENT_NODE && SKIP.has(node.nodeName) ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT) };
    const walker = document.createTreeWalker(scope, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, filter);
    let node = walker.nextNode();
    while (node) {
      if (node.nodeType === Node.TEXT_NODE) doText(node);
      else doElement(node);
      node = walker.nextNode();
    }
  }

  function watch() {
    if (observer || typeof MutationObserver === 'undefined') return;
    observer = new MutationObserver((records) => {
      records.forEach((record) => {
        if (record.type === 'childList') record.addedNodes.forEach((node) => walk(node));
        else if (record.type === 'characterData') walk(record.target);
        else if (record.type === 'attributes') doElement(record.target);
      });
    });
    observer.observe(document.body, { childList: true, subtree: true, characterData: true, attributes: true, attributeFilter: ATTRIBUTES });
  }

  // Puts the panel in the language (a code, or 'auto'). Returns the code in use.
  function use(code) {
    current = resolve(code);
    const words = (window.KCM_LANG || {})[current];
    table = current === 'en' || !words ? null : words;
    document.documentElement.lang = current;
    if (observer) observer.disconnect();
    walk(document);
    observer = null;
    watch();
    return current;
  }

  window.KCM_I18N = { LANGUAGES, use, resolve, current: () => current };
})();
