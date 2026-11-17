/// The page's side of scroll sync and of double-click to edit. All the decisions are the app's
/// (see `ScrollSync`): the page measures where its blocks are, says when it scrolled and whether
/// the reader did it, and scrolls where it is told (`lexmdScrollTo` in the main script).
extension PreviewTemplate {
    static let scrollSyncScript = #"""
(function () {
  var content = document.getElementById('content');
  var page = window.lexmdPage;
  function post(message) { window.webkit.messageHandlers.lexmd.postMessage(message); }
  // A page out of view gets no animation frames, so it falls back to a timer.
  function nextFrame(f) { return document.hidden ? setTimeout(f, 16) : requestAnimationFrame(f); }

  // Where each block that carries source lines is: its first line at its top edge and the line
  // after its last at its bottom edge, as a flat list of line, offset pairs in increasing order.
  function anchors() {
    var list = [], lastLine = 0, lastY = 0, scrollY = window.scrollY;
    function push(line, y) {
      if (line < lastLine || y < lastY || (line === lastLine && y === lastY)) return;
      list.push(line, y);
      lastLine = line;
      lastY = y;
    }
    var blocks = content.querySelectorAll('[data-line]');
    for (var i = 0; i < blocks.length; i++) {
      var rect = blocks[i].getBoundingClientRect();
      if (!rect.height && !blocks[i].getClientRects().length) continue;
      var start = +blocks[i].getAttribute('data-line'), end = +(blocks[i].getAttribute('data-end') || start);
      push(start, rect.top + scrollY);
      push(end + 1, rect.bottom + scrollY);
    }
    return list;
  }

  // While the app syncs the panes, it is sent the page's layout whenever that changes: a
  // render, an image loading, a diagram drawing, zooming, a resize.
  var syncing = false, layoutQueued = false;
  function sendLayout() {
    layoutQueued = false;
    if (!syncing) return;
    post({
      type: 'layout', anchors: anchors(), scroll: window.scrollY,
      view: window.innerHeight, height: document.documentElement.scrollHeight
    });
  }
  function layoutChanged() {
    if (!syncing || layoutQueued) return;
    layoutQueued = true;
    nextFrame(sendLayout);
  }
  new ResizeObserver(layoutChanged).observe(content);
  new MutationObserver(layoutChanged).observe(content, {
    childList: true, subtree: true, attributes: true, attributeFilter: ['data-line', 'data-end']
  });
  window.addEventListener('resize', layoutChanged);
  window.lexmdSync = function (on) {
    syncing = on;
    if (on) sendLayout();
  };

  // Each scroll is reported once per displayed frame, with whether the reader made it: they
  // used the wheel, keys or mouse, or the page did not put itself there.
  var input = false, scrollQueued = false;
  ['wheel', 'keydown', 'mousedown', 'touchstart'].forEach(function (type) {
    window.addEventListener(type, function () { input = true; }, { passive: true, capture: true });
  });
  window.addEventListener('scroll', function () {
    if (!syncing || scrollQueued || page.isResizing()) return;
    scrollQueued = true;
    nextFrame(function () {
      scrollQueued = false;
      post({ type: 'scrolled', scroll: window.scrollY, reader: input || !page.isOwnScroll(), input: input });
      input = false;
    });
  }, { passive: true });

  // Double-click a block to edit it: the editor goes to its source lines, and to the word clicked.
  document.addEventListener('dblclick', function (e) {
    if (e.target.closest('a[href], button, input, .copy')) return;
    var block = e.target.closest('[data-line]');
    if (!block || !content.contains(block)) return;
    var line = +block.getAttribute('data-line'), end = +(block.getAttribute('data-end') || line);
    var selection = window.getSelection(), word = selection ? selection.toString().trim() : '';
    post({ type: 'edit', line: line, end: end, word: word });
  });
})();
"""#
}
