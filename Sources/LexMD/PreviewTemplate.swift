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
:root {
  --text: #1d1d1f;
  --secondary: #6e6e73;
  --tertiary: #8e8e93;
  --accent: #0066cc;
  --hair: rgba(0, 0, 0, 0.09);
  --hair-strong: rgba(0, 0, 0, 0.16);
  --fill: rgba(0, 0, 0, 0.028);
  --fill-strong: rgba(0, 0, 0, 0.055);
  --kw: #ad3da4; --str: #c41a16; --com: #707f8c; --num: #1c00cf;
  --type: #0b4f79; --fn: #326d74; --attr: #815f03;
  --ins: #1f7a35; --del: #b4232a; --hunk: #6c4fbb;
  --note: #0a84ff; --tip: #30a14e; --important: #8e44d6; --warning: #d98200; --caution: #e0352b;
}
@media (prefers-color-scheme: dark) {
  :root {
    --text: #f5f5f7;
    --secondary: #a1a1a6;
    --tertiary: #7c7c82;
    --accent: #3d9bff;
    --hair: rgba(255, 255, 255, 0.10);
    --hair-strong: rgba(255, 255, 255, 0.18);
    --fill: rgba(255, 255, 255, 0.035);
    --fill-strong: rgba(255, 255, 255, 0.075);
    --kw: #ff7ab2; --str: #ff8170; --com: #7f8c98; --num: #d9c97c;
    --type: #6bdfff; --fn: #67b7a4; --attr: #cc9768;
    --ins: #5ccf7a; --del: #ff6b62; --hunk: #b4a2ff;
  }
}
html { font-size: 17px; -webkit-text-size-adjust: 100%; }
body {
  margin: 0;
  background: transparent;
  color: var(--text);
  font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
  line-height: 1.62;
  letter-spacing: -0.003em;
  -webkit-font-smoothing: antialiased;
  text-rendering: optimizeLegibility;
  font-kerning: normal;
  hanging-punctuation: first;
}
::selection { background: color-mix(in srgb, var(--accent) 24%, transparent); }
#content {
  max-width: 42rem;
  margin: 0 auto;
  padding: 3rem 2.75rem 9rem;
  overflow-wrap: break-word;
}
#content:empty::before {
  content: "Nothing to preview yet.";
  display: block;
  margin-top: 30vh;
  text-align: center;
  color: var(--tertiary);
  font-size: 0.94rem;
}
#content > :first-child { margin-top: 0 !important; }
h1, h2, h3, h4, h5, h6 {
  font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", sans-serif;
  font-weight: 700;
  line-height: 1.2;
  margin: 2em 0 0.65em;
  scroll-margin-top: 1.25rem;
}
h1 { font-size: 2.3rem; letter-spacing: -0.028em; line-height: 1.1; margin-top: 1.2em; }
h2 { font-size: 1.62rem; letter-spacing: -0.021em; }
h3 { font-size: 1.27rem; letter-spacing: -0.014em; }
h4 { font-size: 1.06rem; letter-spacing: -0.008em; }
h5 { font-size: 0.94rem; }
h6 { font-size: 0.8rem; text-transform: uppercase; letter-spacing: 0.06em; color: var(--secondary); }
h1 + p { font-size: 1.08rem; color: var(--secondary); }
p, ul, ol, dl, blockquote, .codeblock, .table-wrap, .callout, pre.frontmatter, figure { margin: 0 0 1.15em; }
a { color: var(--accent); text-decoration: none; }
a:hover { text-decoration: underline; text-underline-offset: 0.18em; text-decoration-thickness: 1px; }
strong, b { font-weight: 600; }
em { font-style: italic; }
del { color: var(--secondary); }
mark { background: color-mix(in srgb, #ffd60a 45%, transparent); color: inherit; border-radius: 3px; padding: 0 0.12em; }
kbd {
  font: 500 0.8em -apple-system, sans-serif;
  padding: 0.12em 0.42em;
  border: 1px solid var(--hair-strong);
  border-bottom-width: 2px;
  border-radius: 5px;
  background: var(--fill);
}
ul, ol { padding-left: 1.45em; }
li { margin: 0.32em 0; padding-left: 0.15em; }
li > p { margin: 0.32em 0; }
li > ul, li > ol { margin: 0.2em 0 0.4em; }
li::marker { color: var(--tertiary); }
ol > li::marker { font-variant-numeric: tabular-nums; }
ul.tasks { list-style: none; padding-left: 0.2em; }
li.task { position: relative; padding-left: 1.85em; }
li.task > input[type=checkbox] {
  -webkit-appearance: none;
  appearance: none;
  position: absolute;
  left: 0;
  top: 0.24em;
  width: 1.12em;
  height: 1.12em;
  margin: 0;
  border-radius: 50%;
  border: 1.5px solid var(--tertiary);
  background: transparent;
}
li.task > input[type=checkbox]:checked {
  border-color: var(--accent);
  background: var(--accent) url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'><path d='M4.2 8.4l2.4 2.4 5.2-5.6' fill='none' stroke='white' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'/></svg>") center / 78% no-repeat;
}
li.task.done > p, li.task.done { color: var(--secondary); }
blockquote {
  padding: 0.05em 0 0.05em 1.15em;
  border-left: 3px solid var(--hair-strong);
  color: var(--secondary);
}
blockquote > :last-child { margin-bottom: 0; }
hr { border: none; height: 1px; background: var(--hair); margin: 2.6em 0; }
img, video { max-width: 100%; height: auto; border-radius: 10px; }
p > img:only-child { display: block; margin: 1.6em auto; box-shadow: 0 1px 2px rgba(0,0,0,0.06), 0 8px 28px rgba(0,0,0,0.08); }
code, pre, kbd, samp { font-family: "SF Mono", ui-monospace, Menlo, monospace; }
:not(pre) > code {
  font-size: 0.85em;
  padding: 0.14em 0.38em;
  border-radius: 6px;
  background: var(--fill-strong);
}
.codeblock {
  position: relative;
  border-radius: 12px;
  background: var(--fill);
  border: 1px solid var(--hair);
}
.codeblock pre {
  margin: 0;
  padding: 1.05rem 1.25rem;
  overflow-x: auto;
  font-size: 0.8rem;
  line-height: 1.6;
  tab-size: 4;
}
.codeblock .lang, .codeblock .copy {
  position: absolute;
  top: 0.55rem;
  right: 0.7rem;
  font: 500 0.66rem -apple-system, sans-serif;
  letter-spacing: 0.04em;
  text-transform: uppercase;
  color: var(--tertiary);
  transition: opacity 0.18s ease;
}
.codeblock .copy {
  opacity: 0;
  border: none;
  border-radius: 6px;
  padding: 0.28rem 0.6rem;
  background: var(--fill-strong);
  color: var(--secondary);
  cursor: default;
  -webkit-backdrop-filter: blur(12px);
  backdrop-filter: blur(12px);
}
.codeblock:hover .copy { opacity: 1; }
.codeblock:hover .lang { opacity: 0; }
.codeblock .copy:hover { color: var(--text); }
.codeblock .copy.done { color: var(--tip); }
.table-wrap { overflow-x: auto; border: 1px solid var(--hair); border-radius: 12px; }
table { border-collapse: collapse; width: 100%; font-size: 0.9rem; font-variant-numeric: tabular-nums; }
th, td { padding: 0.62em 0.95em; text-align: left; vertical-align: top; }
th { font-weight: 600; background: var(--fill); border-bottom: 1px solid var(--hair-strong); }
td { border-top: 1px solid var(--hair); }
tbody tr:first-child td { border-top: none; }
.callout {
  --c: var(--note);
  padding: 0.85em 1.1em 0.9em;
  border-radius: 12px;
  background: color-mix(in srgb, var(--c) 8%, transparent);
  border: 1px solid color-mix(in srgb, var(--c) 22%, transparent);
}
.callout > :last-child { margin-bottom: 0; }
.callout-title { font-weight: 600; font-size: 0.86rem; color: var(--c); margin-bottom: 0.3em; display: flex; align-items: center; gap: 0.45em; }
.callout-title::before { content: ""; width: 0.5em; height: 0.5em; border-radius: 50%; background: var(--c); }
.callout-tip { --c: var(--tip); }
.callout-important { --c: var(--important); }
.callout-warning { --c: var(--warning); }
.callout-caution { --c: var(--caution); }
pre.frontmatter {
  font-size: 0.76rem;
  line-height: 1.55;
  color: var(--secondary);
  background: var(--fill);
  border-radius: 10px;
  padding: 0.8rem 1rem;
  overflow-x: auto;
}
details { margin: 0 0 1.15em; padding: 0.6em 1em; border: 1px solid var(--hair); border-radius: 10px; }
summary { font-weight: 600; cursor: default; }
dt { font-weight: 600; }
dd { margin: 0 0 0.6em 1.4em; }
sup, sub { line-height: 0; }
/* Native scroll bars are hidden; #lexmd-scroll is an overlay indicator shown while scrolling. */
::-webkit-scrollbar { width: 0; height: 0; background: transparent; }
#lexmd-scroll {
  position: fixed;
  top: 0;
  right: 3px;
  width: 7px;
  border-radius: 4px;
  background: rgba(0, 0, 0, 0.36);
  opacity: 0;
  transition: opacity 0.45s ease;
  pointer-events: none;
  z-index: 10;
}
#lexmd-scroll.visible { opacity: 1; transition-duration: 0.12s; }
@media (prefers-color-scheme: dark) {
  #lexmd-scroll { background: rgba(255, 255, 255, 0.38); }
}
mark.lexmd-hit {
  background: color-mix(in srgb, #ffd60a 42%, transparent);
  color: inherit;
  border-radius: 3px;
  padding: 0 1px;
  margin: 0 -1px;
}
mark.lexmd-hit.current {
  background: #ffd60a;
  color: #1d1d1f;
  box-shadow: 0 0 0 2px color-mix(in srgb, #ffd60a 45%, transparent), 0 1px 6px rgba(0,0,0,0.18);
}
.tok-kw { color: var(--kw); font-weight: 500; }
.tok-str { color: var(--str); }
.tok-com { color: var(--com); font-style: italic; }
.tok-num { color: var(--num); }
.tok-type { color: var(--type); }
.tok-fn { color: var(--fn); }
.tok-attr { color: var(--attr); }
.tok-ins { color: var(--ins); }
.tok-del { color: var(--del); }
.tok-hunk { color: var(--hunk); }
/* Printing and PDF export: light colors, full width, and page breaks that keep blocks readable. */
@media print {
  :root {
    --text: #1d1d1f; --secondary: #6e6e73; --tertiary: #8e8e93; --accent: #0066cc;
    --hair: rgba(0, 0, 0, 0.12); --hair-strong: rgba(0, 0, 0, 0.2);
    --fill: rgba(0, 0, 0, 0.035); --fill-strong: rgba(0, 0, 0, 0.06);
    --kw: #ad3da4; --str: #c41a16; --com: #707f8c; --num: #1c00cf;
    --type: #0b4f79; --fn: #326d74; --attr: #815f03;
    --ins: #1f7a35; --del: #b4232a; --hunk: #6c4fbb;
    --diagram-bg: #ffffff !important; --diagram-surface: #f5f5f7 !important;
    --diagram-surface-alt: #e8e8ed !important; --diagram-border: #b8b8bf !important;
  }
  html { font-size: 11pt !important; }
  html, body { background: #fff !important; color: var(--text); }
  #content { max-width: none; margin: 0; padding: 0; }
  #content:empty::before, #lexmd-scroll, .codeblock .copy, .codeblock .lang { display: none !important; }
  h1, h2, h3, h4, h5, h6 { break-after: avoid; page-break-after: avoid; break-inside: avoid; }
  h1 + p { color: var(--text); }
  p, li, dd, blockquote { orphans: 3; widows: 3; }
  a { color: var(--accent); text-decoration: underline; text-decoration-thickness: 0.5pt; }
  img, video, svg, figure, tr, .callout, li.task, kbd, .lexmd-diagram-view, div.lexmd-math { break-inside: avoid; page-break-inside: avoid; }
  img, video { box-shadow: none !important; }
  .codeblock, .table-wrap, .callout, pre.frontmatter, details, :not(pre) > code, th, mark, li.task > input[type=checkbox], .lexmd-diagram-view {
    -webkit-print-color-adjust: exact;
    print-color-adjust: exact;
  }
  .codeblock pre, pre.frontmatter { overflow: visible; white-space: pre-wrap; overflow-wrap: anywhere; }
  .table-wrap { overflow: visible; border-radius: 0; border: none; }
  table { border: 1px solid var(--hair-strong); }
  thead { display: table-header-group; }
  mark.lexmd-hit, mark.lexmd-hit.current { background: none; box-shadow: none; padding: 0; margin: 0; }
}
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
