import LexMDRendering

/// The preview page and its script. Documents render into the page world, where the
/// Content-Security-Policy and disabled content JavaScript stop any script they contain.
/// The script below runs in LexMD's own content world, out of reach of document markup.
enum PreviewTemplate {
    static func html(allowsRemoteContent: Bool) -> String {
        page.replacingOccurrences(of: "REMOTE", with: allowsRemoteContent ? " https:" : "")
            .replacingOccurrences(of: "</head>", with: renderingHead + "</head>")
    }

    private static let page = #"""
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src lexmd-doc: data:REMOTE; media-src lexmd-doc: data:REMOTE; font-src lexmd-doc: lexmd-vendor: data:; base-uri lexmd-doc:; form-action 'none'">
<meta name="color-scheme" content="light dark">
<base id="lexmd-base" href="">
<style>
"""# + "\n" + PreviewStyle.page + "\n" + #"""
</style>
</head>
<body>
<article id="content"></article>
</body>
</html>
"""#

    static let script = #"""
(function () {
  var content = document.getElementById('content');
  var base = document.getElementById('lexmd-base');
  var currentBase = '';

  function sourceOf(node) {
    return node.nodeType === 1 ? node.outerHTML : node.textContent;
  }

  function prepare(node) {
    if (node.nodeType !== 1) return;
    var codes = node.matches && node.matches('pre code') ? [node] : node.querySelectorAll('pre code[class*="language-"]');
    for (var i = 0; i < codes.length; i++) highlight(codes[i]);
    if (window.lexmdEnhance) window.lexmdEnhance(node);
  }

  // Patch only the top-level blocks that changed so images and scroll position stay put.
  window.lexmdRender = function (html, baseHref, reset) {
    if (baseHref !== currentBase) {
      base.setAttribute('href', baseHref);
      currentBase = baseHref;
      reset = true;
    }
    var tpl = document.createElement('template');
    tpl.innerHTML = html;
    var next = Array.prototype.filter.call(tpl.content.childNodes, function (n) {
      return !(n.nodeType === 3 && !n.textContent.trim()) && n.nodeType !== 8;
    });
    var nextSrc = next.map(sourceOf);
    if (reset) {
      spyPin = null;
      content.textContent = '';
      next.forEach(function (n, i) { n.__src = nextSrc[i]; content.appendChild(n); prepare(n); });
      window.scrollTo(0, 0);
      return;
    }
    var old = Array.prototype.slice.call(content.childNodes);
    var start = 0;
    while (start < old.length && start < next.length && old[start].__src === nextSrc[start]) start++;
    var endOld = old.length - 1, endNew = next.length - 1;
    while (endOld >= start && endNew >= start && old[endOld].__src === nextSrc[endNew]) { endOld--; endNew--; }
    var anchor = old[endOld + 1] || null;
    for (var i = start; i <= endOld; i++) content.removeChild(old[i]);
    for (var j = start; j <= endNew; j++) {
      var n = next[j];
      n.__src = nextSrc[j];
      content.insertBefore(n, anchor);
      prepare(n);
    }
  };

  function clearHits() {
    var marks = content.querySelectorAll('mark.lexmd-hit');
    var parents = [];
    for (var i = 0; i < marks.length; i++) {
      var m = marks[i], p = m.parentNode;
      p.replaceChild(document.createTextNode(m.textContent), m);
      if (parents.indexOf(p) < 0) parents.push(p);
    }
    parents.forEach(function (p) { p.normalize(); });
  }

  // Highlights every match and returns the count; `current` gets the strong highlight.
  window.lexmdFind = function (q, cs, word, regex, current, scroll) {
    clearHits();
    if (!q) return 0;
    var pattern = regex ? q : q.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    if (word) pattern = '\\b(?:' + pattern + ')\\b';
    var re;
    try { re = new RegExp(pattern, cs ? 'g' : 'gi'); } catch (e) { return 0; }
    var walker = document.createTreeWalker(content, NodeFilter.SHOW_TEXT, {
      acceptNode: function (n) {
        var p = n.parentNode;
        if (!p || p.closest('.copy, .lang, script, style, svg, .katex')) return NodeFilter.FILTER_REJECT;
        return NodeFilter.FILTER_ACCEPT;
      }
    });
    var nodes = [];
    while (walker.nextNode()) nodes.push(walker.currentNode);
    nodes.forEach(function (node) {
      var text = node.nodeValue, ranges = [], m;
      re.lastIndex = 0;
      while ((m = re.exec(text))) {
        if (m[0].length === 0) { re.lastIndex++; continue; }
        ranges.push([m.index, m[0].length]);
      }
      for (var i = ranges.length - 1; i >= 0; i--) {
        var mid = node.splitText(ranges[i][0]);
        mid.splitText(ranges[i][1]);
        var mark = document.createElement('mark');
        mark.className = 'lexmd-hit';
        mid.parentNode.replaceChild(mark, mid);
        mark.appendChild(mid);
      }
    });
    var hits = content.querySelectorAll('mark.lexmd-hit');
    if (hits.length && current >= 0) {
      var target = hits[Math.min(current, hits.length - 1)];
      target.classList.add('current');
      if (scroll) target.scrollIntoView({ block: 'center' });
    }
    return hits.length;
  };

  var indicator = document.createElement('div');
  indicator.id = 'lexmd-scroll';
  document.body.appendChild(indicator);
  var hideTimer = null;
  function updateIndicator() {
    var view = window.innerHeight, total = document.documentElement.scrollHeight;
    if (total <= view + 1) { indicator.classList.remove('visible'); return false; }
    var thumb = Math.max(40, view * view / total);
    var top = 4 + (window.scrollY / (total - view)) * (view - thumb - 8);
    indicator.style.height = thumb + 'px';
    indicator.style.transform = 'translateY(' + top + 'px)';
    return true;
  }
  window.addEventListener('scroll', function () {
    if (!updateIndicator()) return;
    indicator.classList.add('visible');
    clearTimeout(hideTimer);
    hideTimer = setTimeout(function () { indicator.classList.remove('visible'); }, 900);
  }, { passive: true });
  window.addEventListener('resize', updateIndicator);

  window.lexmdScroll = function (f) {
    spyPin = null;
    var max = document.documentElement.scrollHeight - window.innerHeight;
    if (max > 0) window.scrollTo(0, Math.round(max * f));
  };

  window.lexmdZoom = function (s) {
    document.documentElement.style.fontSize = (17 * s) + 'px';
  };

  document.addEventListener('click', function (e) {
    var btn = e.target.closest('.copy');
    if (btn) {
      e.preventDefault();
      var code = btn.parentNode.querySelector('code');
      window.webkit.messageHandlers.lexmd.postMessage({ type: 'copy', text: code ? code.textContent : '' });
      btn.textContent = 'Copied';
      btn.classList.add('done');
      setTimeout(function () { btn.textContent = 'Copy'; btn.classList.remove('done'); }, 1400);
      return;
    }
    var a = e.target.closest('a[href]');
    if (!a) return;
    var href = a.getAttribute('href');
    if (href.charAt(0) === '#') {
      e.preventDefault();
      var target = document.getElementById(decodeURIComponent(href.slice(1)));
      if (target) target.scrollIntoView({ behavior: 'smooth', block: 'start' });
    }
  });

  // Outline: scroll to a heading, and report the heading in view as the page scrolls or changes.
  // A revealed heading stays current while the page scrolls to it and while the page stays
  // there, even when the next heading is close below it or the page cannot scroll that far.
  var spyId = null, spyPin = null, spyTimer = null;
  function headingInView() {
    // Headings drawn inside diagrams, math, or footnotes are not document headings.
    var hs = Array.prototype.filter.call(content.querySelectorAll('h1[id], h2[id], h3[id], h4[id], h5[id], h6[id]'), function (h) {
      return !h.closest('.lexmd-diagram, .lexmd-diagram-view, .lexmd-math, svg, .footnotes');
    });
    var limit = Math.min(140, window.innerHeight * 0.3), id = '';
    var atEnd = window.scrollY > 0 && window.scrollY + window.innerHeight >= document.documentElement.scrollHeight - 2;
    for (var i = 0; i < hs.length; i++) {
      var top = hs[i].getBoundingClientRect().top;
      if (top <= limit || (atEnd && top < window.innerHeight)) id = hs[i].id; else break;
    }
    return id;
  }
  function reportHeading(id) {
    if (id === spyId) return;
    spyId = id;
    window.webkit.messageHandlers.lexmd.postMessage({ type: 'heading', id: id });
  }
  function queueSpy() {
    if (spyTimer) return;
    spyTimer = setTimeout(function () {
      spyTimer = null;
      if (spyPin) {
        var arrived = Math.abs(window.scrollY - spyPin.y) <= 2;
        if (arrived) spyPin.arrived = true;
        if (arrived || (!spyPin.arrived && Date.now() < spyPin.until)) { reportHeading(spyPin.id); return; }
        spyPin = null;
      }
      reportHeading(headingInView());
    }, 60);
  }
  window.addEventListener('scroll', queueSpy, { passive: true });
  window.addEventListener('resize', queueSpy);
  new MutationObserver(queueSpy).observe(content, { childList: true });
  window.lexmdReveal = function (id, smooth) {
    var target = document.getElementById(id);
    if (!target) return false;
    var margin = parseFloat(getComputedStyle(target).scrollMarginTop) || 0;
    var max = Math.max(0, document.documentElement.scrollHeight - window.innerHeight);
    var y = Math.round(Math.min(max, Math.max(0, window.scrollY + target.getBoundingClientRect().top - margin)));
    spyPin = { id: id, y: y, until: Date.now() + 1500, arrived: false };
    window.scrollTo({ top: y, behavior: smooth ? 'smooth' : 'auto' });
    reportHeading(id);
    return true;
  };

  var KW = {};
  ('abstract actor and any as assert associatedtype async await break case catch class const constexpr continue ' +
   'convenience crate debugger declare def default defer del delete deinit do dyn elif else elsif end enum except ' +
   'export extends extension extern fallthrough false fileprivate final finally fn for foreach friend from func function ' +
   'get go goto guard if impl implements import in indirect init inline inout instanceof interface internal is lambda ' +
   'lazy let loop macro match mod module mut mutating namespace new nil none None nonlocal not null nullptr object of open ' +
   'operator or override package pass private protected protocol pub public raise readonly record ref rescue required ' +
   'return sealed select self Self set some static struct super switch synchronized template then this throw throws ' +
   'trait true True False try type typealias typeof undefined union unless unsafe until use using val var virtual void ' +
   'volatile weak when where while with yield fun suspend data lateinit companion echo fi esac done local export ' +
   'SELECT FROM WHERE INSERT INTO UPDATE DELETE CREATE TABLE ALTER DROP JOIN LEFT RIGHT INNER OUTER ON GROUP BY ORDER ' +
   'LIMIT AND OR NOT NULL AS VALUES SET PRIMARY KEY INDEX DISTINCT HAVING UNION').split(/\s+/).forEach(function (w) { KW[w] = 1; });

  var HASH = /^(py|python|python3|rb|ruby|sh|bash|zsh|shell|console|fish|yaml|yml|toml|r|perl|pl|ps1|powershell|dockerfile|makefile|make|conf|ini|properties|elixir|ex|exs|nim|coffee|julia|jl|cmake|nix|graphql|gql|tf|hcl|env|gitignore)$/;
  var DASH = /^(sql|lua|haskell|hs|elm|ada|psql|mysql|sqlite)$/;
  var SKIP = /^(text|txt|plain|plaintext|md|markdown|html|xml|svg|csv|tsv|log|output|mermaid|pele|math)$/;

  function esc(s) { return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'); }

  function highlight(code) {
    var m = /language-([\w+#.-]+)/.exec(code.className);
    if (!m) return;
    var lang = m[1].toLowerCase();
    var src = code.textContent;
    if (lang === 'diff' || lang === 'patch') {
      code.innerHTML = src.split('\n').map(function (l) {
        var c = /^(\+\+\+|---)/.test(l) ? 'hunk' : l.charAt(0) === '+' ? 'ins' : l.charAt(0) === '-' ? 'del' : /^@@/.test(l) ? 'hunk' : '';
        return c ? '<span class="tok-' + c + '">' + esc(l) + '</span>' : esc(l);
      }).join('\n');
      return;
    }
    if (SKIP.test(lang)) return;
    var comment = HASH.test(lang) ? '#.*' : DASH.test(lang) ? '--.*' : '\\/\\/.*|\\/\\*[\\s\\S]*?\\*\\/';
    var re = new RegExp(
      '(' + comment + ')' +
      '|("(?:\\\\.|[^"\\\\])*"|\'(?:\\\\.|[^\'\\\\\\n])*\'|`(?:\\\\.|[^`\\\\])*`)' +
      '|(\\b(?:0[xX][\\da-fA-F_]+|\\d[\\d_]*(?:\\.\\d+)?(?:[eE][+-]?\\d+)?)\\b)' +
      '|(@?[A-Za-z_$][\\w$]*)', 'gm');
    var out = '', last = 0, mm;
    while ((mm = re.exec(src))) {
      if (mm[0].length === 0) { re.lastIndex++; continue; }
      out += esc(src.slice(last, mm.index));
      var cls = null;
      if (mm[1]) cls = 'com';
      else if (mm[2]) cls = 'str';
      else if (mm[3]) cls = 'num';
      else if (mm[4]) {
        var w = mm[4];
        if (w.charAt(0) === '@') cls = 'attr';
        else if (KW[w]) cls = 'kw';
        else if (src.charAt(re.lastIndex) === '(') cls = 'fn';
        else if (/^[A-Z][a-z0-9]/.test(w)) cls = 'type';
      }
      out += cls ? '<span class="tok-' + cls + '">' + esc(mm[0]) + '</span>' : esc(mm[0]);
      last = re.lastIndex;
    }
    out += esc(src.slice(last));
    code.innerHTML = out;
  }
})();
"""#
}
