/// The page's image viewer: clicking an image or a diagram opens it over the page, where it can
/// be zoomed (pinch, ⌘+ and ⌘-, the buttons, or double-click) and moved around (drag, scroll,
/// arrow keys). Escape, the close button, or a click outside it closes it. Everything opens
/// fitted to the window; 100% is the size it has in the document, and 1:1 an image's own pixels.
///
/// Opening grows the item from its place in the document to its place in the viewer, and
/// closing returns it. Only transform and opacity animate, so the motion stays on the GPU and
/// can be reversed midway.
///
/// The viewer's item is laid out at its large size, so shrunk by a transform it is a scaled
/// bitmap: its thin lines never match the page's own drawing, least of all on a 1x display.
/// Closing therefore lands a second copy (the flight) that is laid out at the page's size and
/// place, scaled up to start where the item is. It takes over from the item on the first frame,
/// as the motion starts, and ends with no transform at all, drawn exactly as the page draws the
/// original, so handing back to the page changes no pixel.
///
/// A diagram's text needs care. WebKit picks its font for the size it will have on screen,
/// counting the scales of the elements around it, and the system font spaces its letters by
/// size. Text laid out while the flight is scaled up would keep large-size spacing back at its
/// real size, and shift as the page took over. So the flight is laid out at rest before it is
/// scaled, and its diagram sits in a layer of its own, which hides the motion's scale from it.
///
/// A double-click still edits the block: its second click lands on the viewer just opened,
/// which closes at once and asks to edit. Images inside links follow the link.
extension PreviewTemplate {
    static let lightboxScript = #"""
(function () {
  var content = document.getElementById('content');
  function post(message) { window.webkit.messageHandlers.lexmd.postMessage(message); }
  var reduced = window.matchMedia('(prefers-reduced-motion: reduce)');

  // The viewer's elements, built on first use.
  var box = null, backdrop, stage, bar, label, caption;
  // `shown` is the page's own image or diagram drawing (an img or svg), hidden on the page while
  // the viewer has it; `item` is the copy being viewed. Both last until the motion out is over;
  // `isOpen` turns false as closing starts.
  var shown = null, item = null, isOpen = false, openedAt = 0;
  // natural: the item's size at 1:1 (an image's pixels, a diagram's size on the page). Zoom is
  // shown relative to pageScale, the size the item has in the document, so 100% always means
  // "as in the document".
  var natural = { w: 1, h: 1 }, pageScale = 1, scale = 1, fitScale = 1, x = 0, y = 0;
  var MIN = 0.05, MAX = 12, PAD = 40;
  var motion = [];
  // Opening is unhurried enough to follow; closing is quicker, as the reader is done.
  var OPEN = 300, CLOSE = 220;
  var EASE_OPEN = 'cubic-bezier(0.32, 0.72, 0, 1)', EASE_CLOSE = 'cubic-bezier(0.23, 1, 0.32, 1)';

  function isImage(el) { return el.tagName === 'IMG'; }

  // MARK: Zoom and place

  /// The item's transform at its place: on whole pixels, so a 1x display doesn't draw it between two.
  function resting() { return 'translate(' + Math.round(x) + 'px,' + Math.round(y) + 'px)'; }

  /// Draws the item at the current zoom, keeping it centered while it fits the window and
  /// against the window's edges once it doesn't.
  function layout() {
    var w = natural.w * scale, h = natural.h * scale, fitsX = w + 2 * PAD <= box.clientWidth, fitsY = h + 2 * PAD <= box.clientHeight;
    x = fitsX ? (box.clientWidth - w) / 2 : Math.min(PAD, Math.max(box.clientWidth - w - PAD, x));
    y = fitsY ? (box.clientHeight - h) / 2 : Math.min(PAD, Math.max(box.clientHeight - h - PAD, y));
    item.style.width = w + 'px';
    item.style.height = h + 'px';
    item.style.transform = resting();
    label.textContent = Math.round(scale / pageScale * 100) + '%';
    box.classList.toggle('lexmd-lightbox-pannable', !fitsX || !fitsY);
  }

  /// Everything opens filling the window, small images included, so each takes the same space.
  function fit() {
    scale = fitScale = Math.min((box.clientWidth - 2 * PAD) / natural.w, (box.clientHeight - 2 * PAD) / natural.h);
    layout();
  }

  /// Zooms about a point of the window (its center by default), which stays where it is.
  function zoomTo(next, px, py) {
    next = Math.min(MAX * Math.max(1, pageScale, fitScale), Math.max(MIN * Math.min(pageScale, fitScale), next));
    if (px === undefined) { px = box.clientWidth / 2; py = box.clientHeight / 2; }
    x = px - (px - x) * (next / scale);
    y = py - (py - y) * (next / scale);
    scale = next;
    layout();
  }

  function pan(dx, dy) {
    x += dx;
    y += dy;
    layout();
  }

  // MARK: The viewer

  function button(text, title, action) {
    var b = document.createElement('button');
    b.type = 'button';
    b.textContent = text;
    b.title = title;
    b.setAttribute('aria-label', title);
    b.addEventListener('click', action);
    return b;
  }

  function part(className) {
    var el = document.createElement('div');
    el.className = className;
    return el;
  }

  function build() {
    box = part('');
    box.id = 'lexmd-lightbox';
    box.setAttribute('role', 'dialog');
    box.setAttribute('aria-modal', 'true');
    box.tabIndex = -1;
    backdrop = part('lexmd-lightbox-backdrop');
    stage = part('lexmd-lightbox-stage');
    bar = part('lexmd-lightbox-bar');
    caption = part('lexmd-lightbox-caption');
    label = document.createElement('span');
    label.className = 'lexmd-lightbox-zoom';
    bar.append(
      button('−', 'Zoom Out', function () { zoomTo(scale / 1.25); }),
      label,
      button('+', 'Zoom In', function () { zoomTo(scale * 1.25); }),
      button('Fit', 'Zoom to Fit', fit),
      button('1:1', 'Actual Size', function () { zoomTo(1); }),
      button('✕', 'Close', close)
    );
    box.append(backdrop, stage, bar, caption);
    document.body.appendChild(box);

    function onItem(e) { return isOpen && item.contains(e.target); }
    function inBox(e) { var r = box.getBoundingClientRect(); return { x: e.clientX - r.left, y: e.clientY - r.top }; }
    // The stage covers the window behind the item, so a click on it is a click outside. A drag
    // that ends off the item also arrives as a click on the stage, and must not close the viewer.
    var drag = null, dragged = false;
    stage.addEventListener('click', function (e) { if (e.target === stage && !dragged) close(); });
    box.addEventListener('dblclick', function (e) {
      if (!onItem(e)) return;
      e.preventDefault();
      // The second click of a double-click on the page: edit the block, as everywhere else.
      if (performance.now() - openedAt < 500) { editSource(); return; }
      var at = inBox(e);
      if (scale > fitScale * 1.01) fit(); else zoomTo(Math.max(fitScale * 2, 1), at.x, at.y);
    });
    box.addEventListener('wheel', function (e) {
      e.preventDefault();
      if (!isOpen) return;
      var at = inBox(e);
      if (e.ctrlKey || e.metaKey) zoomTo(scale * Math.exp(-e.deltaY / 200), at.x, at.y); else pan(-e.deltaX, -e.deltaY);
    }, { passive: false });
    box.addEventListener('mousedown', function (e) {
      dragged = false;
      if (e.button !== 0 || !onItem(e)) return;
      e.preventDefault();
      drag = { fromX: e.clientX, fromY: e.clientY, x: x, y: y };
      box.classList.add('lexmd-lightbox-dragging');
    });
    window.addEventListener('mousemove', function (e) {
      if (!drag || !isOpen) return;
      x = drag.x + e.clientX - drag.fromX;
      y = drag.y + e.clientY - drag.fromY;
      dragged = true;
      layout();
    });
    window.addEventListener('mouseup', function () {
      drag = null;
      box.classList.remove('lexmd-lightbox-dragging');
    });
    box.addEventListener('keydown', function (e) {
      if (!isOpen) return;
      var step = 60;
      switch (e.key) {
        case 'Escape': close(); break;
        case '+': case '=': zoomTo(scale * 1.25); break;
        case '-': case '_': zoomTo(scale / 1.25); break;
        case '0': fit(); break;
        case '1': zoomTo(1); break;
        case 'ArrowLeft': pan(step, 0); break;
        case 'ArrowRight': pan(-step, 0); break;
        case 'ArrowUp': pan(0, step); break;
        case 'ArrowDown': pan(0, -step); break;
        default: return;
      }
      e.preventDefault();
      e.stopPropagation();
    });
    window.addEventListener('resize', function () { if (isOpen) layout(); });
  }

  /// What a click on `node` opens: an image that isn't a link, or a rendered diagram's drawing.
  function target(node) {
    if (!node || !node.closest || !content.contains(node) || node.closest('a[href]')) return null;
    var img = node.closest('img');
    if (img) return img.complete && img.naturalWidth > 0 ? img : null;
    var diagram = node.closest('.lexmd-diagram-view');
    return diagram ? diagram.querySelector('svg') : null;
  }

  /// A copy of a page drawing that fills whatever holds it. Only what places it changes: a
  /// diagram keeps its colors and fonts in its own inline style.
  function copyToFill(source) {
    var copy = source.cloneNode(true);
    copy.style.display = 'block';
    copy.style.width = '100%';
    copy.style.height = '100%';
    copy.style.maxWidth = 'none';
    copy.style.margin = '0';
    copy.style.visibility = 'visible';
    return copy;
  }

  /// The copy the viewer shows, and the measures zoom works in.
  function makeItem(source) {
    var rect = source.getBoundingClientRect(), el;
    if (isImage(source)) {
      el = document.createElement('img');
      el.src = source.currentSrc || source.src;
      el.alt = source.alt;
      el.draggable = false;
      natural = { w: source.naturalWidth, h: source.naturalHeight };
    } else {
      // The diagram keeps its classes, so it draws with the page's colors and fonts.
      el = part('lexmd-diagram-view lexmd-lightbox-diagram');
      el.appendChild(copyToFill(source));
      natural = { w: Math.max(1, rect.width), h: Math.max(1, rect.height) };
    }
    pageScale = Math.max(0.01, rect.width / natural.w);
    el.classList.add('lexmd-lightbox-item');
    return el;
  }

  function open(source) {
    if (!box) build();
    dismantle();
    shown = source;
    isOpen = true;
    item = makeItem(source);
    stage.appendChild(item);
    caption.textContent = isImage(source) ? (source.alt || source.title) : '';
    caption.hidden = !caption.textContent;
    box.setAttribute('aria-label', !isImage(source) ? 'Diagram' : source.alt ? 'Image: ' + source.alt : 'Image');
    box.classList.add('open');
    document.documentElement.classList.add('lexmd-lightbox-open');
    // The item's final place, laid out once; the motion only moves and scales it.
    fit();
    // The page's own drawing is hidden while the viewer has it, so there is never a ghost.
    var rect = source.getBoundingClientRect(), look = getComputedStyle(source);
    source.style.visibility = 'hidden';
    openedAt = performance.now();
    box.focus({ preventScroll: true });
    post({ type: 'lightbox', open: true });

    var kind = motionKind();
    if (kind === 'none') return;
    if (kind === 'fade') { run(box, [{ opacity: 0 }, { opacity: 1 }], 150, 'ease-out'); return; }
    // The item starts over the page's drawing: moved there and scaled down by k. It leaves with
    // the page image's rounded corners, squaring them off as it grows, and carries its shadow,
    // which for a white image on a white page is its visible edge. Both are written in the
    // item's own size (divided by k), so scaled down they match the page.
    var origin = box.getBoundingClientRect(), k = Math.max(1, rect.width) / (natural.w * scale);
    var from = 'translate(' + (rect.left - origin.left) + 'px,' + (rect.top - origin.top) + 'px) scale(' + k + ')', to = resting();
    var corner = (parseFloat(look.borderTopLeftRadius) || 0) / k + 'px';
    item.style.boxShadow = look.boxShadow.replace(/(-?\d*\.?\d+)px/g, function (_, n) { return n / k + 'px'; });
    item.style.transform = from;
    backdrop.style.opacity = '0';
    chrome(0);
    var start = function () {
      if (shown !== source || !isOpen) return;
      item.style.transform = to;
      backdrop.style.opacity = '';
      chrome('');
      item.style.willChange = 'transform';
      run(item, [{ transform: from, borderRadius: corner }, { transform: to, borderRadius: '0px' }], OPEN, EASE_OPEN, function () { item.style.willChange = ''; });
      run(backdrop, [{ opacity: 0 }, { opacity: 1 }], OPEN * 0.8, 'ease-out');
      [bar, caption].forEach(function (el) {
        run(el, [{ opacity: 0 }, { opacity: 1 }], 180, 'ease-out', null, OPEN * 0.45);
      });
    };
    // A photo is decoded at its new size before it moves, so the first frames aren't blank.
    if (isImage(item)) {
      Promise.race([item.decode().catch(function () {}), new Promise(function (r) { setTimeout(r, 90); })]).then(start);
    } else {
      start();
    }
  }

  function close() {
    if (!isOpen) return;
    isOpen = false;
    post({ type: 'lightbox', open: false });
    var kind = motionKind(), rect = shown.getBoundingClientRect();
    var inView = shown.isConnected && rect.width > 0 && rect.bottom > 0 && rect.top < window.innerHeight;
    if (kind === 'full' && inView) {
      // Shrinks back into its place, from wherever it is now (even midway through opening).
      var start = item.getBoundingClientRect(), fade = getComputedStyle(backdrop).opacity;
      stopMotion();
      var flight = landFlight(shown, rect);
      // The flight starts scaled up over the item and ends as it is laid out: on the page's
      // drawing, at the page's size, with no transform. It replaces the item on the first frame,
      // where the motion is fastest and the difference in how the two are drawn can't be seen.
      var away = 'translate(' + (start.left - rect.left) + 'px,' + (start.top - rect.top) + 'px) scale(' + (start.width / rect.width) + ')';
      item.style.opacity = '0';
      backdrop.style.opacity = '0';
      chrome(0);
      run(flight, [{ transform: away }, { transform: 'translate(0px,0px) scale(1)' }], CLOSE, EASE_CLOSE, dismantle);
      run(backdrop, [{ opacity: fade }, { opacity: 0 }], CLOSE, EASE_CLOSE);
    } else if (kind !== 'none') {
      // With Reduce Motion, or when the page's drawing is out of sight, the viewer fades away.
      stopMotion();
      shown.style.visibility = '';
      box.style.opacity = '0';
      run(box, [{ opacity: 1 }, { opacity: 0 }], 120, 'ease-out', dismantle);
    } else {
      dismantle();
    }
  }

  /// Puts the flight in the viewer: a copy of the page's drawing laid out exactly as the page
  /// lays it out, the same size at the same place, with an image's own corners and shadow. It is
  /// laid out here, at rest, before anything scales it (see the note on text at the top).
  function landFlight(source, rect) {
    var origin = box.getBoundingClientRect(), look = getComputedStyle(source);
    var flight = part('lexmd-lightbox-flight'), copy = copyToFill(source);
    flight.style.left = (rect.left - origin.left) + 'px';
    flight.style.top = (rect.top - origin.top) + 'px';
    flight.style.width = rect.width + 'px';
    flight.style.height = rect.height + 'px';
    ['borderTopLeftRadius', 'borderTopRightRadius', 'borderBottomLeftRadius', 'borderBottomRightRadius', 'boxShadow'].forEach(function (property) {
      copy.style[property] = look[property];
    });
    if (isImage(source)) {
      // Inside the flight, so the transform is the flight's and the image is painted as on the page.
      flight.appendChild(copy);
    } else {
      // A layer of its own between the diagram and the scaled flight: WebKit sizes a diagram's
      // text for the scales up to the nearest composited layer, so here it never sees the
      // motion's scale and the text stays set as the page sets it.
      flight.classList.add('lexmd-diagram-view', 'lexmd-lightbox-diagram');
      flight.appendChild(part('lexmd-lightbox-shield')).appendChild(copy);
    }
    stage.appendChild(flight);
    flight.getBoundingClientRect();
    return flight;
  }

  /// Takes the viewer down and gives the page its drawing back. Safe to call at any time.
  function dismantle() {
    stopMotion();
    if (!shown) return;
    shown.style.visibility = '';
    shown = item = null;
    isOpen = false;
    box.classList.remove('open');
    box.style.opacity = '';
    backdrop.style.opacity = '';
    chrome('');
    document.documentElement.classList.remove('lexmd-lightbox-open');
    stage.replaceChildren();
  }

  /// A double-click that opened the viewer on its first click: close at once and edit the
  /// block, as a double-click does anywhere on the page.
  function editSource() {
    var block = shown.closest('[data-line]');
    post({ type: 'lightbox', open: false });
    dismantle();
    if (!block) return;
    var line = +block.getAttribute('data-line');
    post({ type: 'edit', line: line, end: +(block.getAttribute('data-end') || line), word: '' });
  }

  // MARK: Motion

  /// Full motion; a short fade with Reduce Motion; none while the page counts as hidden, where
  /// animations would not run.
  function motionKind() {
    if (document.hidden) return 'none';
    return reduced.matches ? 'fade' : 'full';
  }

  /// Plays keyframes from where the element's style already rests at their last one, so a
  /// finished or cancelled animation leaves it in place.
  function run(el, frames, duration, easing, done, delay) {
    var animation = el.animate(frames, { duration: duration, easing: easing, delay: delay || 0, fill: 'backwards' });
    motion.push(animation);
    animation.onfinish = function () {
      motion = motion.filter(function (other) { return other !== animation; });
      if (done) done();
    };
  }

  function stopMotion() {
    var running = motion;
    motion = [];
    running.forEach(function (animation) { animation.onfinish = null; animation.cancel(); });
    if (item) item.style.willChange = '';
  }

  /// The toolbar and caption, which appear after the item arrives and go before it leaves.
  function chrome(opacity) { bar.style.opacity = opacity; caption.style.opacity = opacity; }

  document.addEventListener('click', function (e) {
    if (e.button !== 0 || e.metaKey || e.shiftKey || e.altKey || e.ctrlKey || e.detail > 1) return;
    var source = target(e.target);
    if (source) open(source);
  });

  // What the app calls: its zoom commands and trackpad pinches go to the open viewer.
  window.lexmdLightbox = {
    close: close,
    zoom: function (steps) { if (!isOpen) return; if (steps === 0) fit(); else zoomTo(scale * Math.pow(1.25, steps)); },
    pinch: function (magnification, px, py) { if (isOpen) zoomTo(scale * (1 + magnification), px, py); },
    // For tests only.
    isOpen: function () { return isOpen; },
    // The last frame of closing, held still: the flight at rest over its hidden page drawing.
    // Tests compare it with the page to check that the hand-back changes nothing.
    showLanding: function (selector) {
      var source = target(document.querySelector(selector));
      if (!source) return false;
      if (!box) build();
      dismantle();
      shown = source;
      source.style.visibility = 'hidden';
      backdrop.style.opacity = '0';
      chrome(0);
      box.classList.add('open');
      landFlight(source, source.getBoundingClientRect());
      return true;
    },
    hideLanding: dismantle
  };
})();
"""#
}
