/* Where's Pi sound: an original "detective jazz" loop and small effects, all made live with
   Web Audio (no audio files, nothing to license). Starts on the first tap (browsers block
   sound before that), pauses when the tab is hidden, and one setting turns everything off.
   API: piSound.fx(name), piSound.toggle(), piSound.on, piSound.onChange(fn). */
(function () {
  "use strict";
  const KEY = "pi-sound";
  let on = (() => { try { return localStorage.getItem(KEY) !== "off"; } catch (e) { return true; } })();
  let ctx = null, master = null, musicBus = null, fxBus = null, noise = null, timer = null, listeners = [];
  const AC = window.AudioContext || window.webkitAudioContext;

  const hz = (m) => 440 * Math.pow(2, (m - 69) / 12);
  function init() {
    if (ctx || !AC) return;
    ctx = new AC();
    master = ctx.createGain(); master.gain.value = on ? 1 : 0; master.connect(ctx.destination);
    musicBus = ctx.createGain(); musicBus.gain.value = 0.16; musicBus.connect(master);
    fxBus = ctx.createGain(); fxBus.gain.value = 0.35; fxBus.connect(master);
    const len = ctx.sampleRate * 0.5, buf = ctx.createBuffer(1, len, ctx.sampleRate), d = buf.getChannelData(0);
    for (let i = 0; i < len; i++) d[i] = Math.random() * 2 - 1;
    noise = buf;
  }

  /* One note: oscillator through a filter with a short attack and a decay. */
  function tone(bus, t, midi, dur, o) {
    o = o || {};
    const osc = ctx.createOscillator(), g = ctx.createGain(), f = ctx.createBiquadFilter();
    osc.type = o.type || "sine"; osc.frequency.setValueAtTime(hz(midi), t);
    if (o.slide) osc.frequency.exponentialRampToValueAtTime(hz(midi + o.slide), t + dur);
    f.type = "lowpass"; f.frequency.value = o.cut || 2400; f.Q.value = o.q || 0.7;
    const v = o.vol || 0.5, a = o.attack || 0.008;
    g.gain.setValueAtTime(0.0001, t); g.gain.exponentialRampToValueAtTime(v, t + a);
    g.gain.exponentialRampToValueAtTime(0.0001, t + dur);
    osc.connect(f); f.connect(g); g.connect(bus);
    osc.start(t); osc.stop(t + dur + 0.05);
  }
  function hiss(bus, t, dur, vol, freq) {
    const s = ctx.createBufferSource(), f = ctx.createBiquadFilter(), g = ctx.createGain();
    s.buffer = noise; f.type = "highpass"; f.frequency.value = freq || 7000;
    g.gain.setValueAtTime(vol, t); g.gain.exponentialRampToValueAtTime(0.0001, t + dur);
    s.connect(f); f.connect(g); g.connect(bus); s.start(t); s.stop(t + dur + 0.02);
  }

  /* ---------- Music: 8 bars of swung minor jazz, looped (Cm7 | Fm7 | Dm7b5 G7 | Cm7) x2 ---------- */
  const BPM = 104, BEAT = 60 / BPM, BAR = BEAT * 4, LOOP = 8;
  // Walking bass, one note per beat.
  const BASS = [[36, 39, 43, 46], [41, 44, 48, 44], [38, 41, 43, 47], [36, 43, 39, 35],
                [36, 39, 43, 46], [41, 44, 48, 41], [38, 41, 43, 47], [36, 39, 43, 31]];
  // Melody: [beat within bar (swung eighths as .66), midi, length in beats]
  const MEL = [
    [[0.66, 72, 0.4], [1, 75, 0.4], [1.66, 77, 0.4], [2, 75, 0.9], [3.66, 72, 0.3]],
    [[0, 77, 1.4], [2, 75, 0.4], [2.66, 72, 0.4], [3, 70, 0.9]],
    [[0.66, 74, 0.4], [1, 75, 0.4], [1.66, 77, 0.4], [2, 79, 0.6], [3, 77, 0.4], [3.66, 74, 0.3]],
    [[0, 72, 2.4]],
    [[0, 79, 0.6], [1, 77, 0.4], [1.66, 75, 0.4], [2, 72, 1.4]],
    [[0.66, 75, 0.4], [1, 77, 0.6], [2, 80, 0.4], [2.66, 79, 0.4], [3, 77, 0.9]],
    [[0, 74, 0.4], [0.66, 71, 0.4], [1, 67, 0.9], [2.66, 71, 0.3], [3, 74, 0.6]],
    [[0, 72, 1.6], [2.66, 67, 0.3], [3, 70, 0.3], [3.66, 71, 0.3]],
  ];
  // Soft piano-ish chord stabs on the "and" of 2 and 4.
  const CHORDS = [[60, 63, 67, 70], [56, 60, 63, 65], [62, 65, 68, 72], [60, 63, 67, 70],
                  [60, 63, 67, 70], [56, 60, 63, 65], [59, 62, 65, 67], [60, 63, 67, 70]];
  let bar = 0, nextBar = 0;
  function scheduleBar(t, i) {
    BASS[i].forEach((m, b) => tone(musicBus, t + b * BEAT, m, BEAT * 0.95, { type: "triangle", vol: 0.9, cut: 700, attack: 0.01 }));
    for (let b = 0; b < 4; b++) {
      hiss(musicBus, t + b * BEAT, 0.09, 0.12, 6000);
      hiss(musicBus, t + (b + 0.66) * BEAT, 0.05, 0.06, 8000);
    }
    [1.66, 3.66].forEach((b) => CHORDS[i].forEach((m) => tone(musicBus, t + b * BEAT, m, 0.35, { type: "triangle", vol: 0.12, cut: 1600 })));
    MEL[i].forEach(([b, m, len]) => tone(musicBus, t + b * BEAT, m, len * BEAT, { type: "square", vol: 0.16, cut: 1400, attack: 0.02 }));
  }
  function pump() {
    if (!ctx) return;
    while (nextBar < ctx.currentTime + 0.6) { scheduleBar(nextBar, bar); nextBar += BAR; bar = (bar + 1) % LOOP; }
  }
  function startMusic() {
    if (!ctx || timer || !on) return;
    nextBar = ctx.currentTime + 0.1; bar = 0;
    musicBus.gain.cancelScheduledValues(ctx.currentTime);
    musicBus.gain.setValueAtTime(0.0001, ctx.currentTime); musicBus.gain.exponentialRampToValueAtTime(0.16, ctx.currentTime + 2.5);
    pump(); timer = setInterval(pump, 150);
  }
  function stopMusic() { clearInterval(timer); timer = null; }

  /* ---------- Effects ---------- */
  const FX = {
    warmer(t) { tone(fxBus, t, 72, 0.12, { type: "triangle" }); tone(fxBus, t + 0.09, 79, 0.18, { type: "triangle" }); },
    colder(t) { tone(fxBus, t, 67, 0.12, { type: "triangle" }); tone(fxBus, t + 0.09, 60, 0.22, { type: "triangle" }); },
    close(t) { [76, 79, 83].forEach((m, i) => tone(fxBus, t + i * 0.06, m, 0.16, { type: "triangle" })); },
    neutral(t) { tone(fxBus, t, 70, 0.14, { type: "triangle" }); },
    found(t) {
      tone(fxBus, t, 81, 0.09, { type: "sine", slide: -7, vol: 0.6 }); tone(fxBus, t + 0.1, 83, 0.1, { type: "sine", slide: -8, vol: 0.6 }); // yip yip
      [72, 76, 79, 84].forEach((m, i) => tone(fxBus, t + 0.25 + i * 0.08, m, 0.35, { type: "triangle", vol: 0.45 }));
    },
    missed(t) { tone(fxBus, t, 67, 0.5, { type: "triangle", slide: -5, vol: 0.4 }); },
    win(t) { [[60, 0], [64, 0.12], [67, 0.24], [72, 0.36], [76, 0.36], [79, 0.36]].forEach(([m, d]) => tone(fxBus, t + d, m, 0.7, { type: "square", vol: 0.18, cut: 2600 })); },
    lose(t) { [[67, 0], [66, 0.3], [65, 0.6], [64, 0.9]].forEach(([m, d], i) => tone(fxBus, t + d, m, i === 3 ? 0.9 : 0.28, { type: "triangle", vol: 0.4, slide: i === 3 ? -2 : 0 })); },
    hint(t) { hiss(fxBus, t, 0.08, 0.25, 2500); hiss(fxBus, t + 0.13, 0.08, 0.25, 2500); tone(fxBus, t + 0.28, 84, 0.2, { type: "sine", vol: 0.3 }); }, // sniff sniff, ping
    tick(t) { tone(fxBus, t, 96, 0.03, { type: "square", vol: 0.12, cut: 5000 }); },
    treat(t) { [84, 88, 91].forEach((m, i) => tone(fxBus, t + i * 0.05, m, 0.18, { type: "sine", vol: 0.25 })); },
  };

  function unlock() {
    init(); if (!ctx) return;
    if (ctx.state === "suspended") ctx.resume();
    if (on && document.visibilityState === "visible") startMusic();
  }
  ["pointerdown", "keydown", "touchstart"].forEach((ev) => addEventListener(ev, unlock, { passive: true }));
  document.addEventListener("visibilitychange", () => {
    if (!ctx) return;
    if (document.visibilityState === "hidden") { stopMusic(); ctx.suspend(); }
    else if (on) { ctx.resume(); startMusic(); }
  });

  window.piSound = {
    get on() { return on; },
    fx(name) { if (!on || !ctx || ctx.state !== "running" || !FX[name]) return; try { FX[name](ctx.currentTime + 0.01); } catch (e) { /* never break the game */ } },
    toggle() {
      on = !on; try { localStorage.setItem(KEY, on ? "on" : "off"); } catch (e) { /* ok */ }
      init();
      if (ctx) { master.gain.setTargetAtTime(on ? 1 : 0, ctx.currentTime, 0.05); if (on) { ctx.resume(); startMusic(); } else stopMusic(); }
      listeners.forEach((f) => f(on));
    },
    onChange(f) { listeners.push(f); },
  };
})();
