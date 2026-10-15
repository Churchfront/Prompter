/* Prompter stage for the web: renders a script, measures where every word sits,
   and scrolls to a fractional word position. Shared by display.html (follows the
   Prompter app) and embed.html (runs on its own).

   Geometry matches the app (PrompterTextSurface + TokenGeometry): each word's
   reading y is its line's top plus its horizontal place on the line as a
   fraction of the line height, so position 0 is the first line on the reading
   line and positions between words glide smoothly. */
(function () {
  "use strict";

  const FONTS = {
    figtree: '"Figtree", -apple-system, system-ui, sans-serif',
    system: '-apple-system, system-ui, "Segoe UI", sans-serif',
    rounded: 'ui-rounded, "SF Pro Rounded", -apple-system, system-ui, sans-serif',
    serif: 'ui-serif, "New York", Georgia, serif'
  };

  const DEFAULT_STYLE = {
    typeface: "figtree", weight: 600, fontSize: 44, lineSpacing: 1.3, alignment: "leading",
    margin: 0.07, readingLine: 0.3, marker: true,
    textColor: "#E6E7E8", backgroundColor: "#090E14", highlightColor: "#CAE7F9",
    highlightMode: "phrase", dimReadText: true,
    display: { mirror: false, flip: false, scale: 1 }
  };

  function escapeHTML(s) {
    return s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
  }

  /* Words and stage directions for scripts typed into the embed. The app sends its own. */
  function tokenize(text) {
    const cues = [];
    const cueRe = /\[[^\]\n]*\]/g;
    let m;
    while ((m = cueRe.exec(text))) cues.push([m.index, m[0].length]);
    const inCue = (i) => cues.some(([a, n]) => i >= a && i < a + n);
    const tokens = [];
    const sentenceStarts = [];
    const wordRe = /[\p{L}\p{N}][\p{L}\p{N}'’\-]*/gu;
    let last = 0;
    let lastWord = "";
    while ((m = wordRe.exec(text))) {
      if (inCue(m.index)) continue;
      const between = text.slice(last, m.index);
      const abbrev = /^(mr|mrs|ms|dr|st|vs|etc|jr|sr|prof|rev)$/i.test(lastWord);
      if (tokens.length === 0 || /\n/.test(between) || /[!?…]/.test(between) || (/\./.test(between) && !abbrev) || /\]/.test(between)) {
        sentenceStarts.push(tokens.length);
      }
      tokens.push([m.index, m[0].length]);
      last = m.index + m[0].length;
      lastWord = m[0];
    }
    return { tokens, cues, sentenceStarts };
  }

  class PrompterStage {
    constructor(root) {
      this.root = root;
      root.classList.add("stage");
      root.innerHTML =
        '<div class="stage-progress-track"></div><div class="stage-progress"></div>' +
        '<div class="stage-flip"><div class="stage-scroller"><div class="stage-text"></div></div>' +
        '<div class="stage-marker" aria-hidden="true"></div></div>';
      this.flip = root.querySelector(".stage-flip");
      this.scroller = root.querySelector(".stage-scroller");
      this.textEl = root.querySelector(".stage-text");
      this.marker = root.querySelector(".stage-marker");
      this.progressEl = root.querySelector(".stage-progress");
      this.style = Object.assign({}, DEFAULT_STYLE);
      this.tokens = [];
      this.spans = [];
      this.readingY = [];
      this.maxOffset = 0;
      this.offset = 0;
      this.anchor = -1;
      this.highlight = { readUpTo: 0, current: null };
      this.applied = { readUpTo: 0, current: null };
      this.onRelayout = null;
      this._measureQueued = false;
      new ResizeObserver(() => this.relayout()).observe(root);
      if (document.fonts && document.fonts.ready) document.fonts.ready.then(() => this.relayout());
    }

    /* text: the script. tokens/cues: flat [location, length, ...] UTF-16 pairs or [[loc, len], ...]. */
    setScript(text, tokens, cues) {
      const pairs = (a) => (a.length && !Array.isArray(a[0]) ? a.reduce((o, v, i) => (i % 2 ? o[o.length - 1].push(v) : o.push([v]), o), []) : a);
      this.text = text || "";
      this.tokens = pairs(tokens || []);
      const cueList = pairs(cues || []);
      this.anchor = -1;
      this.highlight = { readUpTo: 0, current: null };
      this.applied = { readUpTo: 0, current: null };
      this.textEl.innerHTML = this.buildHTML(this.text, this.tokens, cueList);
      this.spans = Array.from(this.textEl.querySelectorAll(".w"));
      this.relayout();
    }

    /* Each word span runs from its start to the next word, so punctuation dims and highlights with it. */
    buildHTML(text, tokens, cues) {
      const marks = [];
      tokens.forEach(([loc], i) => marks.push({ at: loc, kind: "w", i }));
      cues.forEach(([loc, len]) => { marks.push({ at: loc, kind: "cue", end: loc + len }); marks.push({ at: loc + len, kind: "end" }); });
      marks.push({ at: text.length, kind: "end" });
      marks.sort((a, b) => a.at - b.at || (a.kind === "end" ? -1 : 1));
      let html = "";
      let pos = 0;
      let open = null;
      const emit = (from, to) => {
        // Paragraphs become blocks so they get the app's paragraph spacing.
        const chunk = text.slice(from, to);
        const parts = chunk.split("\n");
        parts.forEach((part, k) => {
          if (k > 0) {
            // A word's span stops at the line break; the rest of the gap is plain text.
            if (open) { html += "</span>"; open = null; }
            html += '</div><div class="p">';
          }
          html += escapeHTML(part);
        });
      };
      html += '<div class="p">';
      for (const mark of marks) {
        if (mark.at > pos) emit(pos, mark.at);
        pos = Math.max(pos, mark.at);
        if (open) { html += "</span>"; open = null; }
        if (mark.kind === "w") open = `<span class="w" data-i="${mark.i}">`;
        else if (mark.kind === "cue") open = '<span class="cue">';
        if (open) html += open;
      }
      if (open) html += "</span>";
      html += "</div>";
      // Empty paragraphs still take a line, as they do in the app.
      return html.replace(/<div class="p"><\/div>/g, '<div class="p">​</div>');
    }

    setStyle(style) {
      this.style = Object.assign({}, DEFAULT_STYLE, style || {});
      this.style.display = Object.assign({}, DEFAULT_STYLE.display, (style && style.display) || {});
      const s = this.style;
      const r = this.root.style;
      r.setProperty("--stage-bg", s.backgroundColor);
      r.setProperty("--stage-text", s.textColor);
      r.setProperty("--stage-highlight", s.highlightColor);
      document.documentElement.style.background = s.backgroundColor;
      const size = s.fontSize * (s.display.scale || 1);
      const t = this.textEl.style;
      t.fontFamily = FONTS[s.typeface] || FONTS.figtree;
      t.fontWeight = String(s.weight);
      t.fontSize = size + "px";
      // Figtree and SF have a natural line height near 1.2 em; the app multiplies that.
      t.lineHeight = (1.2 * s.lineSpacing).toFixed(3);
      t.textAlign = s.alignment === "center" ? "center" : s.alignment === "trailing" ? "right" : "left";
      this.textEl.querySelectorAll(".cue").forEach((c) => (c.style.fontSize = Math.max(14, s.fontSize * 0.42) * (s.display.scale || 1) + "px"));
      this.textEl.style.setProperty("--para", size * 0.5 + "px");
      this.textEl.querySelectorAll(".p").forEach((p) => (p.style.marginBottom = size * 0.5 + "px"));
      this.marker.style.display = s.marker ? "block" : "none";
      this.flip.style.transform = `scale(${s.display.mirror ? -1 : 1}, ${s.display.flip ? -1 : 1})`;
      this.relayout();
    }

    relayout() {
      if (this._measureQueued) return;
      this._measureQueued = true;
      requestAnimationFrame(() => {
        this._measureQueued = false;
        this.measure();
      });
    }

    measure() {
      const anchor = this.anchor;
      const w = this.root.clientWidth, h = this.root.clientHeight;
      if (!w || !h) return;
      const s = this.style;
      const readingY = Math.round(h * s.readingLine);
      const side = Math.round(w * s.margin);
      this.textEl.style.padding = `${readingY}px ${side}px ${h - readingY}px`;
      // Paragraph styles depend on spans existing; re-apply after a new script.
      const size = s.fontSize * (s.display.scale || 1);
      this.textEl.querySelectorAll(".p").forEach((p) => (p.style.marginBottom = size * 0.5 + "px"));
      this.textEl.querySelectorAll(".cue").forEach((c) => (c.style.fontSize = Math.max(14, s.fontSize * 0.42) * (s.display.scale || 1) + "px"));

      const lineHeight = parseFloat(getComputedStyle(this.textEl).lineHeight) || size * 1.2 * s.lineSpacing;
      // Measure unmirrored and unflipped: client rects include transforms, and a
      // flipped display would otherwise read the words bottom to top. The
      // transform does not change layout, so lifting it for the measurement
      // moves nothing on screen.
      const flipped = this.flip.style.transform;
      this.flip.style.transform = "none";
      const base = this.textEl.getBoundingClientRect();
      const top0 = base.top + readingY;
      // Group words into visual lines, then place each word along its line.
      const rects = this.spans.map((span) => {
        const r = span.getClientRects()[0] || span.getBoundingClientRect();
        return { top: r.top - top0, bottom: r.bottom - top0, left: r.left, right: r.right };
      });
      this.flip.style.transform = flipped;
      const ys = new Array(rects.length);
      let i = 0;
      while (i < rects.length) {
        const mid = (rects[i].top + rects[i].bottom) / 2;
        let j = i;
        let minX = Infinity, maxX = -Infinity;
        while (j < rects.length && Math.abs((rects[j].top + rects[j].bottom) / 2 - mid) < lineHeight * 0.5) {
          minX = Math.min(minX, rects[j].left);
          maxX = Math.max(maxX, rects[j].right);
          j++;
        }
        const lineTop = mid - lineHeight / 2;
        for (let k = i; k < j; k++) {
          const f = maxX > minX ? Math.min(Math.max((rects[k].left - minX) / (maxX - minX), 0), 1) : 0;
          ys[k] = lineTop + f * lineHeight;
        }
        i = j;
      }
      for (let k = 0; k < ys.length; k++) {
        if (k === 0) ys[k] = Math.max(ys[k], 0);
        else ys[k] = Math.max(ys[k], ys[k - 1]);
      }
      this.readingY = ys;
      this.lineHeight = lineHeight;
      this.maxOffset = Math.max(0, this.textEl.scrollHeight - h);
      this.pointsPerWord = ys.length > 1 ? (ys[ys.length - 1] - ys[0]) / (ys.length - 1) : lineHeight / 8;
      // Aim the marker at the glyphs' center on the reading line.
      const glyph = size * 1.2;
      this.marker.style.top = readingY + (lineHeight - glyph) / 2 + glyph / 2 - 12 + "px";
      this.setPosition(anchor);
      this.drawHighlight(true);
      if (this.onRelayout) this.onRelayout();
    }

    offsetFor(position) {
      const ys = this.readingY;
      if (!ys.length) return 0;
      if (position <= 0) return ys[0] * Math.max(0, 1 + position);
      const last = ys.length - 1;
      if (position >= last) return ys[last];
      const i = Math.floor(position), f = position - i;
      return ys[i] + (ys[i + 1] - ys[i]) * f;
    }

    /* Timed mode: the app's steady scroll distance in average words, mapped with
       this screen's average height per word, so the display moves at one constant
       speed and still reaches the end with the app. */
    offsetForTimed(timed) {
      const ys = this.readingY;
      if (!ys.length) return 0;
      return Math.min(Math.max(ys[0] + timed * this.pointsPerWord, 0), this.maxOffset);
    }

    positionFor(offset) {
      const ys = this.readingY;
      if (!ys.length) return 0;
      if (offset <= ys[0]) return ys[0] > 0 ? offset / ys[0] - 1 : 0;
      const last = ys.length - 1;
      if (offset >= ys[last]) return last;
      let lo = 0, hi = last;
      while (hi - lo > 1) {
        const mid = (lo + hi) >> 1;
        if (ys[mid] <= offset) lo = mid; else hi = mid;
      }
      const span = ys[hi] - ys[lo];
      return lo + (span > 0 ? (offset - ys[lo]) / span : 0);
    }

    setOffset(offset) {
      const o = Math.min(Math.max(offset, 0), this.maxOffset);
      this.offset = o;
      this.anchor = this.positionFor(o);
      this.scroller.style.transform = `translate3d(0, ${-o}px, 0)`;
      const n = this.tokens.length;
      this.progressEl.style.width = n > 1 ? (Math.min(Math.max(this.anchor, 0), n - 1) / (n - 1)) * 100 + "%" : "0";
    }

    setPosition(position) {
      const goal = position <= -1 ? 0 : this.offsetFor(position);
      this.setOffset(goal);
      this.anchor = position;
    }

    setHighlight(readUpTo, current) {
      this.highlight = { readUpTo: readUpTo || 0, current: current || null };
      this.drawHighlight(false);
    }

    /* Only words whose state changed are touched. */
    drawHighlight(all) {
      const s = this.style;
      const n = this.spans.length;
      const want = {
        readUpTo: s.dimReadText ? Math.min(this.highlight.readUpTo, n) : 0,
        current: s.highlightMode === "off" ? null : this.highlight.current
      };
      const had = this.applied;
      let lo = 0, hi = n;
      if (!all) {
        lo = Math.min(had.readUpTo, want.readUpTo);
        hi = Math.max(had.readUpTo, want.readUpTo);
        for (const c of [had.current, want.current]) if (c) { lo = Math.min(lo, c[0]); hi = Math.max(hi, c[1]); }
        if (hi <= lo) { this.applied = want; return; }
      }
      lo = Math.max(lo, 0); hi = Math.min(hi, n);
      for (let k = lo; k < hi; k++) {
        const el = this.spans[k];
        const cur = want.current && k >= want.current[0] && k < want.current[1];
        el.classList.toggle("current", !!cur);
        el.classList.toggle("read", !cur && k < want.readUpTo);
      }
      this.applied = want;
    }
  }

  /* Smooths a stream of positions (about 30 a second from the app) into
     display-rate motion: it predicts ahead at the measured speed while
     playing and eases toward each new sample, all in screen pixels. */
  class Follower {
    constructor(stage) {
      this.stage = stage;
      this.target = null;
      this.velocity = 0;
      this.sampleAt = 0;
      this.playing = false;
      this.shown = null;
      this.last = performance.now();
      const frame = (now) => { this.step(now); requestAnimationFrame(frame); };
      requestAnimationFrame(frame);
    }

    /* timed: the app's steady timed-mode distance, when it sends one. */
    push(position, playing, timed) {
      const now = performance.now();
      this.timed = typeof timed === "number" && isFinite(timed) ? timed : null;
      const offset = this.goalFor(position);
      if (this.target !== null && this.playing && playing) {
        const dt = (now - this.sampleAt) / 1000;
        if (dt > 0.005 && dt < 0.5) {
          const v = (offset - this.target) / dt;
          // Large moves are jumps, not reading speed.
          const plausible = Math.abs(v) < this.stage.lineHeight * 6;
          this.velocity = plausible ? this.velocity * 0.6 + v * 0.4 : 0;
        }
      } else {
        this.velocity = 0;
      }
      this.target = offset;
      this.position = position;
      this.sampleAt = now;
      this.playing = playing;
      if (this.shown === null) { this.shown = offset; this.stage.setOffset(offset); this.stage.anchor = position; }
    }

    /* After a relayout, the same word position maps to a new offset. */
    goalFor(position) {
      if (this.timed !== null && this.timed !== undefined) return this.stage.offsetForTimed(this.timed);
      return position <= -1 ? 0 : this.stage.offsetFor(position);
    }

    resync() {
      if (this.position === undefined) return;
      this.target = this.goalFor(this.position);
      this.shown = this.target;
      this.velocity = 0;
      this.stage.setOffset(this.shown);
      this.stage.anchor = this.position;
    }

    step(now) {
      const dt = Math.min((now - this.last) / 1000, 0.1);
      this.last = now;
      if (this.target === null) return;
      const ahead = this.playing ? Math.max(Math.min((now - this.sampleAt) / 1000, 0.15), 0) : 0;
      const goal = this.target + this.velocity * ahead;
      const ease = 1 - Math.exp(-dt * 14);
      const next = this.shown + (goal - this.shown) * ease;
      if (Math.abs(next - this.shown) > 0.01 || Math.abs(goal - this.shown) > 0.5) {
        this.shown = next;
        this.stage.setOffset(next);
      }
    }
  }

  window.Prompter = { PrompterStage, Follower, tokenize, escapeHTML, DEFAULT_STYLE };
})();
