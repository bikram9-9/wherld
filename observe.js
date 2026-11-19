/* Where's Pi observability: PostHog (players, sessions, session replays, live events) and Sentry (errors).
   Runs on wherespi.com only, or anywhere with ?metrics=1 for testing.
   - Every visit is recorded in PostHog. Password and email fields are masked, and anything inside a
     .ph-no-capture element (the two-step sign-in key and QR code) is blocked from recordings.
   - Players: signed-in accounts are identified by their Supabase user id; guests stay anonymous but carry
     their nickname, rank and treats as profile fields. A guest who signs up is merged into the account.
   - 1v1 races: every event during a race carries match_id, so both players' replays can be pulled up.
   - Sentry errors carry a link to the PostHog replay at the moment of the error.
   - Global Privacy Control / Do Not Track: PostHog is not loaded at all; Sentry still reports crashes. */
(function () {
  "use strict";
  const PH_KEY = "phc_DoV9UJ48w2Ru9jB8ZqXZdNFQTwaJD7sxzvvor249JkEP";
  const PH_HOST = "https://us.i.posthog.com", PH_UI = "https://us.posthog.com", PH_PROJECT = 748389;
  const SENTRY_DSN = "https://a3bb2fb8556d6015b752893315981580@o4512455592509440.ingest.us.sentry.io/4512455595524096";

  const host = location.hostname;
  const prod = /(^|\.)wherespi\.com$/.test(host);
  const live = prod || /\bmetrics=1\b/.test(location.search);
  const optedOut = navigator.globalPrivacyControl === true || navigator.doNotTrack === "1" || window.doNotTrack === "1";
  const robot = navigator.webdriver === true || /bot|crawl|spider|headless|lighthouse|preview/i.test(navigator.userAgent);
  const noop = () => {};
  const api = { identify: noop, signOut: noop, player: noop, match: noop, event: noop };
  window.piObserve = api;
  if (!live || robot) return;
  const env = prod ? "production" : "test";
  const safe = (fn) => function () { try { return fn.apply(null, arguments); } catch (e) { /* never break the game */ } };

  /* ---------- PostHog ---------- */
  let phOn = false;
  // The loader swaps window.posthog for the real client once array.js arrives, so always look it up.
  const PH = () => (phOn ? window.posthog : null);
  if (!optedOut) {
    /* Official PostHog loader: queues calls until array.js arrives. */
    !function (t, e) { var o, n, p, r; e.__SV || (window.posthog = e, e._i = [], e.init = function (i, s, a) { function g(t, e) { var o = e.split("."); 2 == o.length && (t = t[o[0]], e = o[1]), t[e] = function () { t.push([e].concat(Array.prototype.slice.call(arguments, 0))) } } (p = t.createElement("script")).type = "text/javascript", p.crossOrigin = "anonymous", p.async = !0, p.src = s.api_host.replace(".i.posthog.com", "-assets.i.posthog.com") + "/static/array.js", (r = t.getElementsByTagName("script")[0]).parentNode.insertBefore(p, r); var u = e; for (void 0 !== a ? u = e[a] = [] : a = "posthog", u.people = u.people || [], u.toString = function (t) { var e = "posthog"; return "posthog" !== a && (e += "." + a), t || (e += " (stub)"), e }, u.people.toString = function () { return u.toString(1) + ".people (stub)" }, o = "init capture register register_once register_for_session unregister unregister_for_session identify setPersonProperties alias reset get_distinct_id get_session_id get_session_replay_url set_config startSessionRecording stopSessionRecording sessionRecordingStarted opt_in_capturing opt_out_capturing has_opted_out_capturing on onSessionId captureException getFeatureFlag isFeatureEnabled onFeatureFlags debug".split(" "), n = 0; n < o.length; n++)g(u, o[n]); e._i.push([i, s, a]) }, e.__SV = 1) }(document, window.posthog || []);
    window.posthog.init(PH_KEY, {
      api_host: PH_HOST,
      ui_host: PH_UI,
      persistence: "localStorage",      // no cookies
      person_profiles: "always",        // guests get searchable profiles too
      capture_pageview: true,
      capture_pageleave: true,
      autocapture: true,
      capture_exceptions: false,        // Sentry owns errors
      enable_recording_console_log: true,
      session_recording: {
        maskAllInputs: false,           // keep country guesses visible in replays
        maskInputOptions: { password: true, email: true },
        blockSelector: ".ph-no-capture",
        maskTextSelector: ".ph-mask"
      },
      loaded: (p) => { p.register({ env }); flush(); }
    });
    phOn = true;
  }
  const phReady = () => !!(PH() && PH().__loaded);

  /* ---------- Sentry ---------- */
  const S = window.Sentry && typeof window.Sentry.init === "function" ? window.Sentry : null;
  if (S) {
    S.init({
      dsn: SENTRY_DSN,
      environment: env,
      sendDefaultPii: false,
      maxBreadcrumbs: 60,
      ignoreErrors: [
        "ResizeObserver loop limit exceeded",
        "ResizeObserver loop completed with undelivered notifications",
        /^Script error\.?$/
      ],
      denyUrls: [/extensions\//i, /^chrome(-extension)?:\/\//i, /^moz-extension:\/\//i, /^safari-(web-)?extension:\/\//i],
      beforeSend(event) {
        if (phReady()) {
          try {
            const did = PH().get_distinct_id();
            event.tags = Object.assign({}, event.tags, { posthog_session: PH().get_session_id() });
            event.contexts = Object.assign({}, event.contexts, {
              posthog: {
                replay: PH().get_session_replay_url({ withTimestamp: true, timestampLookBack: 30 }),
                person: PH_UI + "/project/" + PH_PROJECT + "/person/" + encodeURIComponent(did)
              }
            });
            if (!event.user || !event.user.id) event.user = Object.assign({}, event.user, { id: "ph:" + did });
          } catch (e) { /* send without the link */ }
        }
        return event;
      }
    });
  }

  /* ---------- Hooks the game calls ----------
     Calls made before PostHog's script has loaded are not reliably replayed, so the current account,
     player and race are kept here and pushed to PostHog once it is ready (and on every change after). */
  const MATCH_KEYS = ["match_id", "match_mode", "race_target", "opponent", "opponent_bot"];
  const state = { user: null, player: null, match: null };
  const sent = { user: "", player: "", match: "" };
  function flush() {
    if (!phReady()) return;
    const u = state.user;
    if (u && sent.user !== u.id) { sent.user = u.id; PH().identify(u.id, u.props); }
    const pk = state.player ? JSON.stringify(state.player) : "";
    if (pk && sent.player !== pk) { sent.player = pk; PH().setPersonProperties(state.player); PH().register({ nickname: state.player.nickname }); }
    const mk = state.match ? JSON.stringify(state.match) : "";
    if (sent.match !== mk) { sent.match = mk; if (state.match) PH().register(state.match); else MATCH_KEYS.forEach((k) => PH().unregister(k)); }
  }

  // Signed-in account (Supabase user).
  api.identify = safe((user) => {
    if (!user || !user.id || (state.user && state.user.id === user.id)) return;
    const provider = (user.app_metadata && user.app_metadata.provider) || "email";
    state.user = { id: user.id, props: { email: user.email || undefined, auth_provider: provider, has_account: true } };
    if (S) S.setUser(Object.assign({ id: user.id }, state.player ? { username: state.player.nickname } : {}));
    flush();
  });

  api.signOut = safe(() => {
    if (!state.user) return;
    state.user = null; state.player = null; state.match = null; sent.user = sent.player = sent.match = "";
    if (phReady()) PH().reset();
    if (S) S.setUser(null);
  });

  // Game profile (guest or account): nickname, rank, treats, record.
  api.player = safe((p) => {
    if (!p) return;
    const next = {
      nickname: p.name, rank: p.rating, tier: p.tier, treats: p.coins, wins: p.wins, losses: p.losses, draws: p.draws,
      country: p.country || undefined, outfit: p.outfit || undefined, global_rank: p.rank || undefined
    };
    const changedName = !state.player || state.player.nickname !== next.nickname;
    state.player = next;
    if (S && changedName) S.setUser(Object.assign({}, state.user ? { id: state.user.id } : {}, { username: next.nickname }));
    flush();
  });

  // Live 1v1 race: {id, mode, target, opponent, opponentBot} while playing, null when it is over.
  api.match = safe((m) => {
    const id = m && m.id ? String(m.id) : null;
    if (id === (state.match ? state.match.match_id : null)) return;
    state.match = id ? { match_id: id, match_mode: m.mode, race_target: m.target, opponent: m.opponent, opponent_bot: !!m.opponentBot } : null;
    if (S) { S.setTag("match_id", id || undefined); S.setTag("match_mode", id ? m.mode : undefined); }
    flush();
  });

  // Game events from metrics.js (game_start, game_end, hint, share, sign_in, api_error...).
  api.event = safe((name, props) => {
    if (name === "vital" || name === "page_view") return; // PostHog measures these itself
    if (name === "api_error" && S) S.captureMessage(props && props.msg ? props.msg : "Game server error", { level: "error", tags: { rpc: props && props.src } });
    if (name === "error") return; // Sentry captures these with full stack traces
    if (PH()) PH().capture(name, props || {});
  });
})();
