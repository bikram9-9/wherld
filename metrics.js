/* Where's Pi metrics: anonymous, cookie-free usage stats, error reports and page-speed timings.
   Events go to our own Supabase project (table analytics_events), batched every few seconds, and are
   also forwarded to PostHog / Sentry through observe.js. No cookies. A random visitor id lives in localStorage ("pi-vid") so repeat
   visits can be counted; clearing site data resets it. Global Privacy Control / Do Not Track
   turn off usage stats (error reports, which hold no personal data, still go). */
(function () {
  "use strict";
  const URL_ = "https://wyvstvxrjdcmvmmdvunp.supabase.co/rest/v1/analytics_events";
  const KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Ind5dnN0dnhyamRjbXZtbWR2dW5wIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTQ4ODEyMjEsImV4cCI6MjExMDQ1NzIyMX0.fIVQecib_eAua7j3bVBY5SNoBUkyuGhCyuyy0Y4YNRs";
  const host = location.hostname;
  const live = /(^|\.)wherespi\.com$/.test(host) || /\bmetrics=1\b/.test(location.search);
  const optedOut = navigator.globalPrivacyControl === true || navigator.doNotTrack === "1" || window.doNotTrack === "1";
  const robot = navigator.webdriver === true || /bot|crawl|spider|headless|lighthouse|preview/i.test(navigator.userAgent);
  const noop = () => {};
  if (!live || robot) { window.piTrack = Object.assign(noop, { mark: noop, setAuth: noop }); return; }

  const hex = () => { const a = new Uint8Array(8); crypto.getRandomValues(a); return Array.from(a, (b) => b.toString(16).padStart(2, "0")).join(""); };
  const keep = (store, k) => { try { let v = store.getItem(k); if (!/^[a-f0-9]{16}$/.test(v || "")) { v = hex(); store.setItem(k, v); } return v; } catch (e) { return hex(); } };
  const vid = keep(localStorage, "pi-vid"), sid = keep(sessionStorage, "pi-sid");

  const ua = navigator.userAgent;
  const os = /iPhone|iPad|iPod/.test(ua) || (/Macintosh/.test(ua) && navigator.maxTouchPoints > 1) ? "iOS" : /Android/.test(ua) ? "Android" : /Windows/.test(ua) ? "Windows" : /Mac OS X/.test(ua) ? "macOS" : /CrOS/.test(ua) ? "ChromeOS" : /Linux/.test(ua) ? "Linux" : "Other";
  const browser = /Edg\//.test(ua) ? "Edge" : /OPR\/|Opera/.test(ua) ? "Opera" : /SamsungBrowser/.test(ua) ? "Samsung" : /Firefox|FxiOS/.test(ua) ? "Firefox" : /CriOS|Chrome\//.test(ua) ? "Chrome" : /Safari\//.test(ua) ? "Safari" : "Other";
  const w = Math.min(screen.width, screen.height);
  const device = /iPad|Tablet/.test(ua) || (os === "iOS" && !/iPhone|iPod/.test(ua)) || (os === "Android" && !/Mobile/.test(ua)) ? "tablet" : /Mobi|iPhone|Android/.test(ua) || w < 500 ? "mobile" : "desktop";
  let tz = null; try { tz = Intl.DateTimeFormat().resolvedOptions().timeZone || null; } catch (e) { /* unknown */ }
  const ref = (() => {
    const q = new URLSearchParams(location.search), utm = q.get("utm_source") || q.get("ref");
    if (utm) return utm.slice(0, 60);
    try { const r = new URL(document.referrer); return r.hostname === host ? "" : r.hostname.replace(/^www\./, ""); } catch (e) { return ""; }
  })();
  const path = () => location.pathname + (/^#c-/.test(location.hash) ? "#challenge" : "");

  let getAuth = null, queue = [], timer = null, errorCount = 0;
  const seen = new Map();
  function send(useKeepalive) {
    clearTimeout(timer); timer = null;
    if (!queue.length) return;
    const batch = queue.splice(0, 50);
    const go = (token) => fetch(URL_, {
      method: "POST", keepalive: !!useKeepalive,
      headers: { apikey: KEY, Authorization: "Bearer " + (token || KEY), "Content-Type": "application/json", Prefer: "return=minimal, missing=default" },
      body: JSON.stringify(batch)
    }).catch(() => {});
    if (getAuth && !useKeepalive) Promise.resolve(getAuth()).then(go, () => go(KEY)); else go(KEY);
    if (queue.length) timer = setTimeout(send, 1000);
  }
  function track(name, props) {
    if (optedOut && name !== "error" && name !== "api_error") return;
    const p = {};
    for (const [k, v] of Object.entries(props || {})) if (v !== undefined && v !== null) p[k] = typeof v === "string" ? v.slice(0, 300) : v;
    try { if (window.piObserve) window.piObserve.event(name, p); } catch (e) { /* PostHog / Sentry, see observe.js */ }
    queue.push({ name, vid, sid, path: path(), ref: ref || null, device, browser, os, lang: (navigator.language || "").slice(0, 20) || null, tz, props: p });
    if (queue.length >= 20) send(); else if (!timer) timer = setTimeout(send, 4000);
  }
  track.setAuth = (fn) => { getAuth = fn; };

  /* ---------- Errors ---------- */
  function reportError(msg, src, stack) {
    msg = String(msg || "Unknown error").slice(0, 200);
    const n = (seen.get(msg) || 0) + 1; seen.set(msg, n);
    if (n > 3 || ++errorCount > 25) return;
    track("error", { msg, src: src || null, stack: stack ? String(stack).split("\n").slice(0, 4).join(" | ").slice(0, 300) : null });
  }
  addEventListener("error", (e) => {
    const t = e.target;
    if (t && t !== window && (t.src || t.href)) { reportError("Failed to load " + (t.tagName || "").toLowerCase() + ": " + String(t.src || t.href).replace(/\?.*$/, ""), null, null); return; }
    const file = e.filename ? e.filename.replace(location.origin, "") : "";
    if (!e.message && !file) return;
    reportError(e.message, file ? file + ":" + e.lineno + ":" + e.colno : null, e.error && e.error.stack);
  }, true);
  addEventListener("unhandledrejection", (e) => {
    const r = e.reason;
    reportError("Unhandled promise: " + (r && r.message ? r.message : String(r)), null, r && r.stack);
  });

  /* ---------- Page speed (Core Web Vitals and our own map-ready timing) ---------- */
  const vitals = {};
  const obs = (type, fn, extra) => { try { new PerformanceObserver((l) => l.getEntries().forEach(fn)).observe(Object.assign({ type, buffered: true }, extra || {})); } catch (e) { /* not supported */ } };
  obs("paint", (en) => { if (en.name === "first-contentful-paint") vitals.FCP = en.startTime; });
  obs("largest-contentful-paint", (en) => { vitals.LCP = en.startTime; });
  let clsWin = 0, clsFirst = 0, clsLast = 0;
  obs("layout-shift", (en) => {
    if (en.hadRecentInput) return;
    if (clsWin && en.startTime - clsLast < 1000 && en.startTime - clsFirst < 5000) clsWin += en.value; else { clsWin = en.value; clsFirst = en.startTime; }
    clsLast = en.startTime; vitals.CLS = Math.max(vitals.CLS || 0, clsWin);
  });
  obs("event", (en) => { if (en.interactionId) vitals.INP = Math.max(vitals.INP || 0, en.duration); }, { durationThreshold: 40 });
  try { const nav = performance.getEntriesByType("navigation")[0]; if (nav) vitals.TTFB = nav.responseStart; } catch (e) { /* none */ }
  track.mark = (metric) => { if (!(metric in vitals)) vitals[metric] = performance.now(); };
  let vitalsSent = false;
  function flush() {
    if (!vitalsSent) {
      vitalsSent = true;
      for (const [metric, v] of Object.entries(vitals)) if (isFinite(v)) track("vital", { metric, value: metric === "CLS" ? Math.round(v * 1000) / 1000 : Math.round(v) });
    }
    send(true);
  }
  addEventListener("visibilitychange", () => { if (document.visibilityState === "hidden") flush(); });
  addEventListener("pagehide", flush);

  window.piTrack = track;
  track("page_view", { title: document.title.slice(0, 80), w: innerWidth, h: innerHeight });
})();
