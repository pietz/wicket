// Trusted host code, executed only in WKContentWorld.defaultClient. No agent script.
// The canvas shows the list (w-list) or the page (main, inside w-page); the host decides which, what
// they hold and what is selected. Arguments: op ('list', 'page' or 'paint'), selected, css ({core, own},
// null when unchanged); for 'list' rows; for 'page' html, reset, turn, show (false lays the page out
// unseen, to be measured), icons (null: unchanged) and restore (where a page that comes back was scrolled).
const root = document.documentElement;
const scrolling = document.scrollingElement;
const list = document.querySelector('w-list');
const main = document.querySelector('main');
const paging = root.dataset.mode === 'page';
// The selected target is marked where it stands; the host owns which one it is. Only an arrow key or a
// new list scrolls, and just enough to show it.
function paint(scroll) {
  for (const old of document.querySelectorAll('[data-selected]')) {
    old.removeAttribute('data-selected');
    old.removeAttribute('aria-current');
  }
  const shown = root.dataset.mode === 'page' ? main : list;
  const target = selected === null ? null
    : [...shown.querySelectorAll('[data-target]')].find(t => t.dataset.target === selected);
  if (!target) return;
  target.setAttribute('data-selected', '');
  target.setAttribute('aria-current', 'true');
  if (scroll) target.scrollIntoView({block: 'nearest'});
}
// The owner's theme is parsed on its own, so a stray brace cannot end its layer, and loses every
// !important, so nothing in it can outrank the unlayered core (canvas.css).
if (css !== null) {
  document.querySelector('#theme').textContent = css.core;
  const own = new CSSStyleSheet();
  own.replaceSync(css.own.replace(/!\s*important/gi, ''));
  const layer = document.querySelector('#user').sheet.cssRules[0];
  while (layer.cssRules.length) layer.deleteRule(0);
  for (const rule of own.cssRules) {
    try { layer.insertRule(rule.cssText, layer.cssRules.length); } catch {}
  }
}
// A click on a row or target goes to the host with the page's turn ('list' for a row), so a click on a
// page that has since been replaced is ignored there. A link keeps its own click, and a drag that
// selected text is no click. A right click asks for the target's actions instead of WebKit's menu.
if (!globalThis.listening) {
  globalThis.listening = true;
  const post = (event, menu) => {
    const target = event.target.closest('[data-target]');
    if (!target) return false;
    webkit.messageHandlers.target.postMessage({
      id: target.dataset.target, turn: list.contains(target) ? 'list' : globalThis.turn,
      count: Math.max(1, event.detail), menu,
    });
    return true;
  };
  document.addEventListener('click', event => {
    if (event.button !== 0 || event.target.closest('a') || !getSelection().isCollapsed) return;
    post(event, false);
  });
  document.addEventListener('contextmenu', event => { if (post(event, true)) event.preventDefault(); });
}
// Patch unchanged nodes in place, preserving focus and selections in stable paragraphs.
function patch(old, fresh) {
  if (!old.isEqualNode(fresh)) {
    if (old.nodeType !== fresh.nodeType || old.nodeName !== fresh.nodeName) {
      old.replaceWith(fresh.cloneNode(true)); return;
    }
    if (old.nodeType === Node.TEXT_NODE || old.nodeType === Node.COMMENT_NODE) {
      old.nodeValue = fresh.nodeValue; return;
    }
    for (const a of [...old.attributes]) if (!fresh.hasAttribute(a.name)) old.removeAttribute(a.name);
    for (const a of [...fresh.attributes]) if (old.getAttribute(a.name) !== a.value) old.setAttribute(a.name, a.value);
    const count = fresh.childNodes.length;
    for (let i = 0; i < count; i++) {
      if (old.childNodes[i]) patch(old.childNodes[i], fresh.childNodes[i]);
      else old.append(fresh.childNodes[i].cloneNode(true));
    }
    while (old.childNodes.length > count) old.lastChild.remove();
  }
}
function fresh(name, html) {
  const template = document.createElement('template'); template.innerHTML = html;
  const element = document.createElement(name); element.append(template.content);
  return element;
}
if (op === 'paint') { paint(true); return {}; }
// Where the page was scrolled when the list or another page replaced it.
const left = paging ? scrollY : null;
if (op === 'list') {
  patch(list, fresh('w-list', rows));
  if (paging) { root.dataset.mode = 'list'; scrollTo(0, 0); }
  paint(true);
  // This acknowledgement is layout-ready, NOT claimed to be a visible screen paint.
  return {height: list.getBoundingClientRect().height, left};
}
const following = paging && scrolling.scrollHeight - scrolling.scrollTop - innerHeight < 24;
if (icons !== null) document.querySelector('#icons').textContent = icons;
const next = fresh('main', html);
for (const target of next.querySelectorAll('[data-target]')) target.setAttribute('role', 'button');
patch(main, next);
globalThis.turn = turn;
if (show) {
  root.dataset.mode = 'page';
  paint(false);
  if (reset || !paging) scrollTo(0, restore ?? 0);
  // A stream is followed to its end unless the user is on a target.
  else if (following && selected === null) scrollTo(0, scrolling.scrollHeight);
}
return {height: main.getBoundingClientRect().height, left: reset ? left : null};
