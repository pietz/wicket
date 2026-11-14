// Trusted host code, executed only in WKContentWorld.defaultClient. No agent script.
// Arguments: html (null only paints the selection), reset, turn, selected, icons (null: unchanged),
// restore (where a page that comes back was scrolled).
const scrolling = document.scrollingElement;
// The selected target is marked where it stands; the host owns which one it is. Only an arrow key
// scrolls, and just enough to show it.
function paint(scroll) {
  for (const old of document.querySelectorAll('[data-selected]')) {
    old.removeAttribute('data-selected');
    old.removeAttribute('aria-current');
  }
  const target = selected === null ? null
    : [...document.querySelectorAll('w-row[data-target], w-card[data-target]')].find(t => t.dataset.target === selected);
  if (!target) return;
  target.setAttribute('data-selected', '');
  target.setAttribute('aria-current', 'true');
  if (scroll) target.scrollIntoView({block: 'nearest'});
}
globalThis.selected = selected;
if (html === null) { paint(true); return {}; }
// A click on a target goes to the host with the page's turn, so a click on a page that has since been
// replaced is ignored there. A link keeps its own click, and a drag that selected text is no click.
if (!globalThis.listening) {
  globalThis.listening = true;
  document.addEventListener('click', event => {
    if (event.button !== 0 || event.target.closest('a') || !getSelection().isCollapsed) return;
    const target = event.target.closest('w-row[data-target], w-card[data-target]');
    if (target) webkit.messageHandlers.target.postMessage({id: target.dataset.target, turn: globalThis.turn});
  });
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
const root = document.querySelector('main');
const left = scrollY;
const following = scrolling.scrollHeight - scrolling.scrollTop - innerHeight < 24;
if (icons !== null) document.querySelector('#icons').textContent = icons;
const template = document.createElement('template'); template.innerHTML = html;
const next = document.createElement('main'); next.append(template.content);
for (const target of next.querySelectorAll('w-row[data-target], w-card[data-target]')) target.setAttribute('role', 'button');
patch(root, next);
globalThis.turn = turn;
paint(false);
if (reset) scrollTo(0, restore);
// A stream is followed to its end unless the user is on a target.
else if (following && selected === null) scrollTo(0, scrolling.scrollHeight);
// This acknowledgement is layout-ready, NOT claimed to be a visible screen paint.
return {height: root.getBoundingClientRect().height, scroll: scrollY, left};
