/// The preview's stylesheets, shared by the app's preview and the Quick Look extension.
package enum PreviewStyle {
    /// Typography, colors for light and dark, code blocks, tables, task lists, callouts, and print.
    package static let page = #"""
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
/* Links: wiki links to missing documents, and local links whose file or heading is gone. */
.lexmd-missing { color: var(--tertiary); border-bottom: 1px dashed currentColor; cursor: default; }
a.lexmd-broken { color: var(--caution); text-decoration: underline wavy color-mix(in srgb, var(--caution) 60%, transparent); text-underline-offset: 0.2em; text-decoration-thickness: 1px; }
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
"""#

    /// Diagrams, math, footnotes, and front matter properties.
    package static let rendering = #"""
:root {
  --diagram-bg: #ffffff;
  --diagram-surface: #f5f5f7;
  --diagram-surface-alt: #e8e8ed;
  --diagram-border: #b8b8bf;
}
@media (prefers-color-scheme: dark) {
  :root {
    --diagram-bg: #1c1c1e;
    --diagram-surface: #2c2c2e;
    --diagram-surface-alt: #3a3a3c;
    --diagram-border: #636366;
  }
}
.lexmd-diagram { margin: 0 0 1.15em; }
.lexmd-diagram > .codeblock { margin: 0; }
.lexmd-diagram-view {
  --pele-bg: var(--diagram-bg);
  --pele-fg: var(--text);
  --pele-muted: var(--secondary);
  --pele-line: var(--secondary);
  --pele-surface: var(--diagram-surface);
  --pele-surface-alt: var(--diagram-surface-alt);
  --pele-border: var(--diagram-border);
  --pele-accent: var(--accent);
  --pele-error: var(--caution);
  --pele-critical: var(--caution);
  --pele-font: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
  --pele-font-mono: "SF Mono", ui-monospace, Menlo, monospace;
  --pele-radius: 6px;
  padding: 1.1rem;
  border-radius: 12px;
  background: var(--diagram-bg);
  border: 1px solid var(--hair);
  overflow-x: auto;
  text-align: center;
  line-height: normal;
}
.lexmd-diagram-view > svg { display: inline-block; max-width: 100%; height: auto; vertical-align: top; }
.lexmd-render-error {
  margin: 0.45em 0 0;
  white-space: pre-wrap;
  font-family: "SF Mono", ui-monospace, Menlo, monospace;
  font-size: 0.72rem;
  line-height: 1.45;
  color: var(--caution);
}
.lexmd-math { color: var(--secondary); font-family: "SF Mono", ui-monospace, Menlo, monospace; font-size: 0.85em; }
.lexmd-math.rendered { color: inherit; font-family: inherit; font-size: inherit; }
div.lexmd-math, span.lexmd-display:not(.rendered) { display: block; margin: 0 0 1.15em; white-space: pre-wrap; text-align: center; }
div.lexmd-math.rendered { white-space: normal; overflow-x: auto; overflow-y: hidden; }
div.lexmd-math .katex-display { margin: 0.4em 0; }
.lexmd-math .katex { font-size: 1.12em; }
.katex-error { color: var(--caution) !important; font-family: "SF Mono", ui-monospace, Menlo, monospace; font-size: 0.85em; }
sup.footnote-ref { font-size: 0.72em; margin-left: 0.08em; }
sup.footnote-ref a { padding: 0 0.12em; }
section.footnotes {
  margin-top: 3em;
  padding-top: 1.2em;
  border-top: 1px solid var(--hair);
  font-size: 0.86rem;
  color: var(--secondary);
}
section.footnotes ol { padding-left: 1.3em; margin: 0; }
section.footnotes li { margin: 0.4em 0; scroll-margin-top: 1.25rem; }
section.footnotes li p { margin: 0 0 0.4em; }
a.footnote-back { margin-left: 0.2em; font-size: 0.9em; }
.properties { margin: 0 0 1.6em; border-bottom: 1px solid var(--hair); padding-bottom: 0.8em; }
.properties table { width: auto; font-size: 0.84rem; }
.properties th, .properties td { padding: 0.22em 0; border: none; background: none; vertical-align: baseline; }
.properties th { padding-right: 1.6em; font-weight: 500; color: var(--secondary); white-space: nowrap; }
.properties td { color: var(--text); }
.properties .tag {
  display: inline-block;
  margin: 0.1em 0.1em 0.1em 0;
  padding: 0.05em 0.55em;
  border-radius: 999px;
  background: var(--fill-strong);
  font-size: 0.92em;
}

"""#
}
