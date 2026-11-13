/// Script bodies for export, print, and rich text copy. They run with `callAsyncJavaScript` in
/// LexMD's content world, never in the page world where document markup lives.
enum ExportScripts {
    /// Waits for LexMD's rendering to finish: queued diagrams and math are rendered at once with
    /// `lexmdRenderAll()`, an optional `lexmdWhenRendered()` promise is awaited, and the content
    /// must stop changing. With `eager`, images load immediately, every image is awaited, and
    /// collapsed details open so printouts show everything.
    static let settle = #"""
var content = document.getElementById('content');
var deadline = Date.now() + limit;
function left() { return Math.max(0, deadline - Date.now()); }
function sleep(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }
if (eager) {
  content.querySelectorAll('img[loading]').forEach(function (img) { img.removeAttribute('loading'); });
  content.querySelectorAll('details').forEach(function (d) { d.open = true; });
}
if (typeof lexmdRenderAll === 'function') {
  try { await lexmdRenderAll(); } catch (e) {}
}
if (typeof window.lexmdWhenRendered === 'function') {
  try { await Promise.race([Promise.resolve(window.lexmdWhenRendered()), sleep(left())]); } catch (e) {}
}
await new Promise(function (resolve) {
  var timer = null, finished = false;
  var observer = new MutationObserver(function () { clearTimeout(timer); timer = setTimeout(finish, 200); });
  function finish() { if (finished) return; finished = true; observer.disconnect(); resolve(); }
  observer.observe(content, { subtree: true, childList: true, attributes: true, characterData: true });
  timer = setTimeout(finish, 200);
  setTimeout(finish, Math.min(left(), 5000));
});
if (eager) {
  var pending = Array.prototype.filter.call(content.querySelectorAll('img'), function (img) { return !img.complete; });
  if (pending.length) {
    await Promise.race([Promise.all(pending.map(function (img) {
      return new Promise(function (r) { img.addEventListener('load', r, { once: true }); img.addEventListener('error', r, { once: true }); });
    })), sleep(left())]);
  }
}
// Layout starts loading the fonts the content uses (such as KaTeX's); then wait for them.
void content.offsetHeight;
if (document.fonts && document.fonts.ready) await Promise.race([document.fonts.ready, sleep(Math.min(left(), 4000))]);
if (eager) {
  // Keep each heading on the same page as the short block after it. Print engines often
  // ignore break-after: avoid, but honor break-inside: avoid on a wrapper.
  Array.prototype.slice.call(content.querySelectorAll(':scope > h1, :scope > h2, :scope > h3, :scope > h4, :scope > h5, :scope > h6')).forEach(function (h) {
    var next = h.nextElementSibling;
    if (!next || next.offsetHeight > 240) return;
    var keep = document.createElement('div');
    keep.style.breakInside = 'avoid';
    keep.style.pageBreakInside = 'avoid';
    if (h === content.firstElementChild) h.style.marginTop = '0';
    h.parentNode.insertBefore(keep, h);
    keep.appendChild(h);
    keep.appendChild(next);
  });
}
await sleep(50);
return true;
"""#

    /// Shared helpers: cloning the content (or the selection) into an inert document, and
    /// removing anything that could run, load a frame, or navigate on its own.
    static let common = #"""
var content = document.getElementById('content');
var base = document.baseURI;
var inert = document.implementation.createHTMLDocument('');
var XHTML = 'http://www.w3.org/1999/xhtml';
var DROP = /^(\#(UnsafeMarkup.elements))$/i;

// Finishes any diagrams and math still queued in the preview.
async function lexmdFinish() {
  if (typeof lexmdRenderAll === 'function') {
    try { await lexmdRenderAll(); } catch (e) {}
  }
}

function lexmdClone(useSelection) {
  var holder = inert.createElement('div');
  var sel = window.getSelection();
  if (useSelection && sel && sel.rangeCount && !sel.isCollapsed) {
    var range = sel.getRangeAt(0);
    var node = range.commonAncestorContainer;
    if (content.contains(node)) {
      var piece = range.cloneContents();
      if (node.nodeType !== 1) node = node.parentNode;
      // Keep the enclosing blocks (code, lists, tables) so a partial selection keeps its formatting.
      while (node && node !== content) {
        var shell = node.cloneNode(false);
        shell.appendChild(piece);
        piece = shell;
        node = node.parentNode;
      }
      holder.appendChild(inert.importNode(piece, true));
      return { holder: holder, selection: true };
    }
  }
  Array.prototype.forEach.call(content.childNodes, function (n) { holder.appendChild(inert.importNode(n, true)); });
  return { holder: holder, selection: false };
}

function lexmdUnsafeURL(name, value) {
  var v = String(value).replace(/[\u0000- \u007f-\u009f]/g, '').toLowerCase();
  if (/^(javascript|vbscript|livescript):/.test(v)) return true;
  if (v.indexOf('data:') === 0) return !(name === 'src' && v.indexOf('data:image/') === 0);
  return false;
}

function lexmdScrub(root) {
  Array.prototype.slice.call(root.querySelectorAll('*')).forEach(function (el) {
    var name = el.localName.toLowerCase();
    if (DROP.test(name) || (name === 'button' && el.classList.contains('copy'))) { el.remove(); return; }
    if (name === 'mark' && el.classList.contains('lexmd-hit')) { el.replaceWith(inert.createTextNode(el.textContent)); return; }
    Array.prototype.slice.call(el.attributes).forEach(function (a) {
      var n = a.name.toLowerCase();
      var local = n.slice(n.indexOf(':') + 1);
      if (n.indexOf('on') === 0 || ['srcdoc', 'srcset', 'sizes', 'ping', 'formaction', 'action', 'http-equiv'].indexOf(n) >= 0) {
        el.removeAttributeNode(a);
      } else if (['href', 'src', 'poster', 'data', 'background'].indexOf(local) >= 0 && lexmdUnsafeURL(local, a.value)) {
        el.removeAttributeNode(a);
      }
    });
  });
}

function lexmdEachURL(root, visit) {
  Array.prototype.slice.call(root.querySelectorAll('[src], [href], [poster]')).forEach(function (el) {
    ['src', 'href', 'poster'].forEach(function (name) {
      var raw = el.getAttribute(name);
      if (raw === null || raw.charAt(0) === '#') return;
      var abs;
      try { abs = new URL(raw, base).href; } catch (e) { return; }
      visit(el, name, raw, abs);
    });
  });
}

"""#

    /// Serializes the rendered document for a standalone HTML file. Local references become
    /// numbered tokens that the app replaces with data URIs or relative paths.
    static let exportHTML = #"""
await lexmdFinish();
var holder = lexmdClone(false).holder;
lexmdScrub(holder);
var resources = [];
lexmdEachURL(holder, function (el, name, raw, abs) {
  if (abs.indexOf('lexmd-doc:///') !== 0) return;
  el.setAttribute(name, nonce + resources.length + ';');
  resources.push({ url: abs, image: name === 'src' && el.localName === 'img' });
});
var css = Array.prototype.map.call(document.querySelectorAll('head style:not(#lexmd-katex):not(#lexmd-overlay)'), function (s) { return s.textContent; }).join('\n');
// KaTeX's stylesheet is only needed with math, and only the font families the math uses.
var katexStyle = document.getElementById('lexmd-katex');
var fonts = new Set();
if (katexStyle && content.querySelector('.katex')) {
  content.querySelectorAll('.katex, .katex *').forEach(function (el) {
    var family = getComputedStyle(el).fontFamily.split(',')[0].trim().replace(/["']/g, '');
    if (/^KaTeX_/.test(family)) fonts.add(family);
  });
}
return {
  html: holder.innerHTML, css: css, resources: resources,
  katex: fonts.size ? katexStyle.textContent : '', fonts: Array.from(fonts)
};
"""#

    /// Captures the selection or the whole document as styled HTML (with inline styles that
    /// survive pasting into Mail, Pages, Notes, and web editors), HTML for RTF, and plain text.
    static let copy = #"""
await lexmdFinish();
var picked = lexmdClone(useSelection);
var holder = picked.holder;
lexmdScrub(holder);
holder.querySelectorAll('style, .lang').forEach(function (n) { n.remove(); });
// Without KaTeX's stylesheet only its MathML reads correctly, so the styled copy is dropped.
holder.querySelectorAll('.katex-html').forEach(function (n) { n.remove(); });
lexmdEachURL(holder, function (el, name, raw, abs) {
  if (abs.indexOf('lexmd-doc:///') === 0) {
    var u = new URL(abs);
    el.setAttribute(name, 'file://' + u.pathname + u.hash);
  } else if (raw !== abs) {
    el.setAttribute(name, abs);
  }
});
holder.querySelectorAll('input[type=checkbox]').forEach(function (box) {
  box.replaceWith(inert.createTextNode(box.hasAttribute('checked') ? '☑ ' : '☐ '));
});

var MONO = 'font-family: Menlo, Monaco, "Courier New", monospace';
var RULES = [
  ['h1', 'font-size: 22pt; font-weight: bold; margin: 14pt 0 8pt'],
  ['h2', 'font-size: 17pt; font-weight: bold; margin: 14pt 0 6pt'],
  ['h3', 'font-size: 14pt; font-weight: bold; margin: 12pt 0 5pt'],
  ['h4', 'font-size: 12pt; font-weight: bold; margin: 10pt 0 4pt'],
  ['h5', 'font-size: 11pt; font-weight: bold; margin: 10pt 0 4pt'],
  ['h6', 'font-size: 10pt; font-weight: bold; margin: 10pt 0 4pt; color: #6e6e73'],
  ['p', 'margin: 0 0 8pt'],
  ['ul, ol', 'margin: 0 0 8pt; padding-left: 22pt'],
  ['li', 'margin: 2pt 0'],
  ['blockquote', 'margin: 0 0 8pt; padding: 0 0 0 10pt; border-left: 3px solid #d2d2d7; color: #6e6e73'],
  ['pre', MONO + '; font-size: 10pt; line-height: 1.45; background-color: #f5f5f7; padding: 8pt 10pt; border-radius: 6px; white-space: pre-wrap; margin: 0 0 8pt'],
  ['code', MONO + '; font-size: 0.9em'],
  [':not(pre) > code', 'background-color: #f0f0f2; padding: 1px 4px; border-radius: 4px'],
  ['kbd', MONO + '; font-size: 0.9em; border: 1px solid #d2d2d7; border-radius: 4px; padding: 0 4px'],
  ['table', 'border-collapse: collapse; margin: 0 0 8pt'],
  ['th', 'border: 1px solid #d2d2d7; padding: 4pt 8pt; background-color: #f5f5f7; font-weight: bold; text-align: left'],
  ['td', 'border: 1px solid #d2d2d7; padding: 4pt 8pt; vertical-align: top'],
  ['a', 'color: #0066cc'],
  ['hr', 'border: none; border-top: 1px solid #d2d2d7; margin: 12pt 0'],
  ['del', 'text-decoration: line-through; color: #6e6e73'],
  ['mark', 'background-color: #fff3a3'],
  ['img', 'max-width: 100%'],
  ['.callout', 'margin: 0 0 8pt; padding: 6pt 10pt; border-left: 3px solid #0a84ff; background-color: #f2f7ff'],
  ['.callout-tip', 'border-left-color: #30a14e; background-color: #f1f9f3'],
  ['.callout-important', 'border-left-color: #8e44d6; background-color: #f7f1fc'],
  ['.callout-warning', 'border-left-color: #d98200; background-color: #fdf6ec'],
  ['.callout-caution', 'border-left-color: #e0352b; background-color: #fdf0ef'],
  ['.callout-title', 'font-weight: bold; margin-bottom: 3pt'],
  ['pre.frontmatter', 'color: #6e6e73'],
  ['.tok-kw', 'color: #ad3da4'], ['.tok-str', 'color: #c41a16'], ['.tok-com', 'color: #707f8c; font-style: italic'],
  ['.tok-num', 'color: #1c00cf'], ['.tok-type', 'color: #0b4f79'], ['.tok-fn', 'color: #326d74'],
  ['.tok-attr', 'color: #815f03'], ['.tok-ins', 'color: #1f7a35'], ['.tok-del', 'color: #b4232a'], ['.tok-hunk', 'color: #6c4fbb']
];
var styled = new Map();
RULES.forEach(function (rule) {
  holder.querySelectorAll(rule[0]).forEach(function (el) {
    styled.set(el, (styled.has(el) ? styled.get(el) + '; ' : '') + rule[1]);
  });
});
Array.prototype.slice.call(holder.querySelectorAll('*')).forEach(function (el) {
  if (el.namespaceURI !== XHTML) return;
  var own = el.getAttribute('style');
  if (own && /url\s*\(|expression\s*\(|@import/i.test(own)) own = null;
  var css = [styled.get(el), own].filter(Boolean).join('; ');
  Array.prototype.slice.call(el.attributes).forEach(function (a) {
    var n = a.name.toLowerCase();
    if (n === 'class' || n === 'id' || n === 'loading' || n === 'style' || n.indexOf('data-') === 0) el.removeAttributeNode(a);
  });
  if (css) el.setAttribute('style', css);
});

var rtf = holder.cloneNode(true);
rtf.querySelectorAll('[aria-hidden="true"]').forEach(function (n) { n.remove(); });
rtf.querySelectorAll('math').forEach(function (m) {
  var tex = m.querySelector('annotation[encoding="application/x-tex"]');
  m.replaceWith(inert.createTextNode(tex ? tex.textContent : m.textContent));
});
rtf.querySelectorAll('img').forEach(function (img) { img.replaceWith(inert.createTextNode(img.getAttribute('alt') || '')); });
rtf.querySelectorAll('svg, video, audio, picture, canvas, source, track, input, select, textarea, button, style').forEach(function (n) { n.remove(); });
Array.prototype.slice.call(rtf.querySelectorAll('*')).forEach(function (el) {
  ['src', 'poster', 'background'].forEach(function (n) { el.removeAttribute(n); });
});

var hidden = Array.prototype.slice.call(content.querySelectorAll('.copy, .lang'));
var saved = hidden.map(function (n) { return n.getAttribute('style'); });
hidden.forEach(function (n) { n.style.display = 'none'; });
var text = picked.selection ? window.getSelection().toString() : content.innerText;
hidden.forEach(function (n, i) { if (saved[i] === null) n.removeAttribute('style'); else n.setAttribute('style', saved[i]); });

return { html: holder.innerHTML, rtf: rtf.innerHTML, text: text.replace(/\s+$/, '') };
"""#
}
