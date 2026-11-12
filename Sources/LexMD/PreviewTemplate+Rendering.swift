import LexMDRendering

/// Diagrams (Pele), math (KaTeX), footnotes, and front matter properties in the preview.
/// The script runs in LexMD's content world next to `PreviewTemplate.script`, with Pele and
/// KaTeX injected into the same world. Rendered output is real DOM and SVG in the document.
extension PreviewTemplate {
    /// Extra `<head>` markup: styles for rendered blocks and KaTeX's stylesheet.
    static var renderingHead: String {
        "<style>\n\(renderingStyle)</style>\n" + (VendorAssets.katexStyle.map { "<style id=\"lexmd-katex\">\n\($0)\n</style>\n" } ?? "")
    }

    static var renderingStyle: String { PreviewStyle.rendering }

    static let renderingScript = #"""
(function () {
  var FONT = '-apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif';
  var SELECTOR = '.lexmd-diagram, .lexmd-math';
  var cache = new Map();
  var CACHE_LIMIT = 400;
  var BUDGET_MS = 40;
  var SLICE_MS = 12;
  var pending = [];
  var near = new Set();
  var timer = null;

  function remember(key, value) {
    cache.delete(key);
    cache.set(key, value);
    if (cache.size > CACHE_LIMIT) cache.delete(cache.keys().next().value);
    return value;
  }

  function hash(s) {
    var h = 2166136261;
    for (var i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 16777619); }
    return (h >>> 0).toString(36);
  }

  // Diagram output is treated as untrusted: anything that could run code, load content, or
  // navigate somewhere unexpected is removed before it reaches the document.
  var DROP = /^(script|foreignobject|iframe|frame|embed|object|applet|animate|animatemotion|animatetransform|set|discard|handler|listener|audio|video|canvas|link|meta|base|form|input|button|textarea|select)$/i;
  var LINK_OK = /^(https?:|mailto:|#)/i;
  var IMAGE_OK = /^data:image\/(png|jpe?g|gif|webp);/i;
  function clean(root) {
    var elements = [root].concat(Array.prototype.slice.call(root.querySelectorAll('*')));
    for (var i = 0; i < elements.length; i++) {
      var el = elements[i];
      if (el !== root && DROP.test(el.localName)) { el.remove(); continue; }
      var attrs = Array.prototype.slice.call(el.attributes);
      for (var j = 0; j < attrs.length; j++) {
        var name = attrs[j].name.toLowerCase(), value = attrs[j].value;
        var compact = value.replace(/[\u0000- \u007f-\u009f]+/g, '').toLowerCase();
        var local = name.replace(/^.*:/, '');
        var bad = name.indexOf('on') === 0 || /(javascript|vbscript|livescript):/.test(compact);
        if (!bad && (local === 'href' || local === 'src' || local === 'action' || local === 'formaction')) {
          bad = el.localName.toLowerCase() === 'image' ? !(IMAGE_OK.test(compact) || compact.charAt(0) === '#')
            : el.localName.toLowerCase() === 'a' ? !LINK_OK.test(compact) : compact.charAt(0) !== '#';
        }
        if (bad) el.removeAttribute(attrs[j].name);
      }
    }
    return root;
  }

  window.lexmdCleanSVG = clean;

  function parseSVG(markup) {
    var tpl = document.createElement('template');
    tpl.innerHTML = markup;
    var svg = tpl.content.firstElementChild;
    if (!svg || svg.localName !== 'svg' || tpl.content.children.length !== 1) return null;
    return clean(svg);
  }

  function diagram(src) {
    if (typeof pele === 'undefined') return { error: 'The diagram renderer is not available.' };
    try {
      var result = pele.render(src, {
        fontFamily: FONT,
        idPrefix: 'lexmd-d' + hash(src) + '-',
        linkSchemes: ['http', 'https', 'mailto'],
        images: false
      });
      var svg = parseSVG(result.svg);
      return svg ? { node: svg } : { error: 'The diagram could not be displayed.' };
    } catch (e) {
      var message = e && e.message ? String(e.message) : String(e);
      return { error: message.split('\n').slice(0, 4).join('\n').slice(0, 400) };
    }
  }

  function math(tex, display) {
    if (typeof katex === 'undefined') return null;
    var holder = document.createElement('span');
    try {
      katex.render(tex, holder, {
        displayMode: display, throwOnError: false, trust: false, strict: 'ignore',
        output: 'htmlAndMathml', maxSize: 100, maxExpand: 1000
      });
    } catch (e) {
      holder.textContent = tex;
      holder.className = 'katex-error';
      holder.title = e && e.message ? String(e.message) : '';
    }
    return { node: clean(holder) };
  }

  function renderOne(el) {
    el.__lexmdPending = false;
    if (!el.isConnected || el.__lexmdDone) return;
    el.__lexmdDone = true;
    if (el.classList.contains('lexmd-diagram')) {
      var code = el.querySelector('pre code');
      if (!code) return;
      var src = code.textContent;
      var entry = cache.get('d' + src) || remember('d' + src, diagram(src));
      if (entry.node) {
        var view = document.createElement('div');
        view.className = 'lexmd-diagram-view';
        var svg = entry.node.cloneNode(true);
        // Sized in rem so diagrams follow the preview zoom (the root font is 17px at 100%).
        var width = parseFloat(svg.getAttribute('width'));
        if (width > 0 && svg.hasAttribute('viewBox')) svg.style.width = (width / 17) + 'rem';
        view.appendChild(svg);
        el.replaceChildren(view);
      } else {
        var note = document.createElement('p');
        note.className = 'lexmd-render-error';
        note.textContent = 'Diagram error: ' + entry.error;
        el.appendChild(note);
      }
    } else {
      var tex = el.getAttribute('data-tex') || '';
      var display = el.classList.contains('lexmd-display');
      var key = (display ? 'D' : 'I') + tex;
      var rendered = cache.get(key) || math(tex, display);
      if (!rendered) { el.__lexmdDone = false; return; }
      remember(key, rendered);
      el.replaceChildren(rendered.node.cloneNode(true));
      el.classList.add('rendered');
    }
  }

  function isCached(el) {
    if (el.classList.contains('lexmd-diagram')) {
      var code = el.querySelector('pre code');
      return !!code && cache.has('d' + code.textContent);
    }
    return cache.has((el.classList.contains('lexmd-display') ? 'D' : 'I') + (el.getAttribute('data-tex') || ''));
  }

  var observer = typeof IntersectionObserver === 'function' ? new IntersectionObserver(function (entries) {
    entries.forEach(function (e) {
      if (e.isIntersecting) { near.add(e.target); observer.unobserve(e.target); }
    });
    schedule();
  }, { rootMargin: '1200px 0px' }) : null;

  function schedule() {
    if (timer === null && pending.length) timer = setTimeout(pump, 0);
  }

  // Renders in short slices, nearest the viewport first, so long documents stay responsive.
  function pump() {
    timer = null;
    var start = performance.now();
    while (pending.length && performance.now() - start < SLICE_MS) {
      var index = 0;
      if (near.size) {
        for (var i = 0; i < pending.length; i++) if (near.has(pending[i])) { index = i; break; }
      }
      var el = pending.splice(index, 1)[0];
      near.delete(el);
      if (observer) observer.unobserve(el);
      renderOne(el);
    }
    schedule();
  }

  // Called for each block the preview inserts. Cached results apply at once; new ones render
  // within a small budget, and the rest are queued.
  window.lexmdEnhance = function (node) {
    if (node.nodeType !== 1) return;
    var found = node.matches(SELECTOR) ? [node] : Array.prototype.slice.call(node.querySelectorAll(SELECTOR));
    if (!found.length) return;
    var deadline = performance.now() + BUDGET_MS;
    found.forEach(function (el) {
      if (el.__lexmdDone || el.__lexmdPending) return;
      if (isCached(el) || performance.now() < deadline) { renderOne(el); return; }
      el.__lexmdPending = true;
      pending.push(el);
      if (observer) observer.observe(el);
    });
    pending = pending.filter(function (el) { return el.isConnected; });
    schedule();
  };

  // Renders everything still queued, for callers that need the finished document.
  window.lexmdRenderAll = function () {
    var queue = pending;
    pending = [];
    near.clear();
    queue.forEach(function (el) { if (observer) observer.unobserve(el); renderOne(el); });
    return queue.length;
  };
})();
"""#
}
