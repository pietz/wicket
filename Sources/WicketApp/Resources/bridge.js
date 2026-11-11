// Trusted host code, executed only in WKContentWorld.defaultClient. No agent script.
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
const root = document.querySelector('main'), scrolling = document.scrollingElement;
const following = scrolling.scrollHeight - scrolling.scrollTop - innerHeight < 24;
const template = document.createElement('template'); template.innerHTML = html;
const next = document.createElement('main'); next.append(template.content);
patch(root, next);
if (reset) scrollTo(0, 0);
else if (following) scrollTo(0, scrolling.scrollHeight);
// This acknowledgement is layout-ready, NOT claimed to be a visible screen paint.
return {height: root.getBoundingClientRect().height, scroll: scrollY};
