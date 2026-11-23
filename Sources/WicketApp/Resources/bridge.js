// Trusted host code, executed only in WKContentWorld.defaultClient. No agent script.
// Arguments: html (null only paints the selection), reset, turn, targetRevision, selected, icons (null: unchanged),
// restore (where a page that comes back was scrolled), follow (keep following a stream).
const scrolling = document.scrollingElement;
const fields = 'w-field[data-key]';
const targets = 'w-row[data-target], w-tile[data-target], div[data-target], ' + fields;
function paint(scroll) {
  for (const old of document.querySelectorAll('[data-selected]')) {
    old.removeAttribute('data-selected');
    old.removeAttribute('aria-current');
  }
  const target = selected === null ? null
    : [...document.querySelectorAll(targets)].find(t => t.dataset.target === selected);
  if (!target) return;
  target.setAttribute('data-selected', '');
  target.setAttribute('aria-current', 'true');
  if (scroll) target.scrollIntoView({block: 'nearest'});
}
if (html === null) { paint(true); return {}; }
if (!globalThis.listening) {
  globalThis.listening = true;
  const range = 'input[type=range]';
  function focus(turn = globalThis.turn) {
    webkit.messageHandlers.fieldFocus.postMessage(turn);
  }
  function changed(event, phase) {
    const input = event.target;
    const field = input.closest(fields);
    if (!field || !input.matches('input, select')) return;
    if (phase === 'preview' && !input.matches(range)) return;
    const value = input.type === 'checkbox' ? String(input.checked) : input.value;
    webkit.messageHandlers.fieldChange.postMessage({name: field.dataset.key, value, phase, turn: globalThis.turn});
    if (phase === 'commit') focus();
  }
  document.addEventListener('input', event => changed(event, 'preview'));
  document.addEventListener('change', event => changed(event, 'commit'));
  document.addEventListener('pointerdown', event => {
    if (event.button === 0 && event.target.matches(range) && event.target.closest(fields)) {
      globalThis.dragging = event.target;
    }
  });
  function release() {
    if (!globalThis.dragging) return;
    globalThis.dragging = null;
    // Mouseup and the range's change still have to run before AppKit takes focus.
    const turn = globalThis.turn;
    setTimeout(() => focus(turn), 0);
  }
  document.addEventListener('pointerup', release);
  document.addEventListener('pointercancel', release);
  // Links own their clicks. Code copies from its button, so clicking text can still select it.
  document.addEventListener('click', event => {
    if (event.button !== 0) return;
    if (event.target.closest(fields)) {
      if (!event.target.closest('select') && !globalThis.dragging) focus();
      return;
    }
    if (event.target.closest('a') || !getSelection().isCollapsed) return;
    const target = event.target.closest(targets);
    if (target && (target.localName !== 'div' || event.target.closest('button'))) {
      webkit.messageHandlers.target.postMessage({id: target.dataset.target, revision: globalThis.targetRevision});
    }
  });
}
const root = document.querySelector('main');
const left = scrollY;
const following = scrolling.scrollHeight - scrolling.scrollTop - innerHeight < 24;
if (icons !== null) document.querySelector('#icons').textContent = icons;
const template = document.createElement('template'); template.innerHTML = html;
const next = document.createElement('main'); next.append(template.content);
for (const target of next.querySelectorAll('w-row[data-target], w-tile[data-target]')) target.setAttribute('role', 'button');

const keyed = new Map([...root.querySelectorAll(fields)].map(node => [node.dataset.key, node]));
const hasFields = keyed.size || next.querySelector(fields);
const key = node => node.nodeType === Node.ELEMENT_NODE && node.matches(fields) ? node.dataset.key : null;

function patch(old, fresh) {
  if (!hasFields && old.isEqualNode(fresh)) return;
  if (old.nodeType !== Node.ELEMENT_NODE) {
    if (old.nodeValue !== fresh.nodeValue) old.nodeValue = fresh.nodeValue;
    return;
  }
  if (old === globalThis.dragging) return;
  for (const a of [...old.attributes]) if (!fresh.hasAttribute(a.name)) old.removeAttribute(a.name);
  for (const a of [...fresh.attributes]) if (old.getAttribute(a.name) !== a.value) old.setAttribute(a.name, a.value);
  const previous = [...old.childNodes];
  const byType = new Map();
  for (const node of previous.toReversed()) {
    if (key(node)) continue;
    const signature = node.nodeName + (node.type ?? '');
    if (!byType.has(signature)) byType.set(signature, []);
    byType.get(signature).push(node);
  }
  const pairs = [...fresh.childNodes].map(node => {
    const name = key(node);
    const match = name ? keyed.get(name) : byType.get(node.nodeName + (node.type ?? ''))?.pop();
    if (name) keyed.delete(name);
    return [match ?? node.cloneNode(false), node];
  });
  const kept = new Set(pairs.map(([node]) => node));
  for (const node of previous) if (!kept.has(node)) node.remove();
  let cursor = old.firstChild;
  for (const [node, desired] of pairs) {
    if (node !== cursor) {
      if (node.isConnected && old.isConnected && old.moveBefore) old.moveBefore(node, cursor);
      else old.insertBefore(node, cursor);
    }
    patch(node, desired);
    cursor = node.nextSibling;
  }
  // Changing attributes alone leaves a dirty form control's displayed value untouched.
  if (old.matches('input[type=checkbox], input[type=radio]') && old.checked !== fresh.checked) {
    old.checked = fresh.checked;
  }
  if (old.matches('input[type=range], select') && old.value !== fresh.value) old.value = fresh.value;
}

if (reset) {
  globalThis.dragging = null;
  root.replaceChildren(...next.childNodes);
} else {
  const focused = document.activeElement;
  patch(root, next);
  if (focused?.isConnected && focused.closest(fields) && document.activeElement !== focused) {
    focused.focus({preventScroll: true});
  }
}
globalThis.turn = turn;
globalThis.targetRevision = targetRevision;
paint(false);
if (reset) scrollTo(0, restore);
else if (follow && following && selected === null) scrollTo(0, scrolling.scrollHeight);
else if (!follow) scrollTo(0, left);
// This acknowledgement is layout-ready, not a visible screen paint.
return {height: root.getBoundingClientRect().height, scroll: scrollY, left};
