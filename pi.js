"use strict";
/* ---------- Pi, the goldendoodle (original mascot, drawn here). Outfits come from the shop. ---------- */
const OUTFITS = {
  shades: '<g><rect x="35" y="52" width="22" height="14" rx="6" fill="#141414"/><rect x="63" y="52" width="22" height="14" rx="6" fill="#141414"/><path d="M57 57 h6 M35 57 l-9 -4 M85 57 l9 -4" stroke="#141414" stroke-width="3" stroke-linecap="round"/><path d="M40 56 l5 -2 M68 56 l5 -2" stroke="#fff" stroke-width="2" stroke-linecap="round" opacity="0.7"/></g>',
  beret: '<g><ellipse cx="64" cy="19" rx="32" ry="13" fill="#b3202c" transform="rotate(-9 64 19)"/><path d="M66 7 l4 -8" stroke="#b3202c" stroke-width="3.5" stroke-linecap="round"/><ellipse cx="60" cy="29" rx="24" ry="4" fill="#8f1822"/></g>',
  sombrero: '<g><ellipse cx="60" cy="27" rx="58" ry="11" fill="#d9b25a" stroke="#8a5a1c" stroke-width="2"/><path d="M37 27 q23 -50 46 0 z" fill="#e6c574" stroke="#8a5a1c" stroke-width="2"/><path d="M40 21 q20 9 40 0" stroke="#c2262e" stroke-width="4.5" fill="none"/><path d="M12 27 q48 12 96 0" stroke="#2f8f5b" stroke-width="2.5" fill="none" stroke-dasharray="5 5"/></g>',
  explorer: '<g><ellipse cx="60" cy="27" rx="42" ry="8" fill="#b9a26a" stroke="#6b5a2e" stroke-width="2"/><path d="M33 27 q27 -38 54 0 z" fill="#cdb87c" stroke="#6b5a2e" stroke-width="2"/><path d="M35 23 q25 7 50 0" stroke="#6b5a2e" stroke-width="4" fill="none"/></g>',
  santa: '<g><path d="M30 27 q22 -42 66 -18 q-18 0 -8 18 z" fill="#c2182b"/><rect x="26" y="20" width="66" height="13" rx="6.5" fill="#ffffff"/><circle cx="99" cy="11" r="8.5" fill="#ffffff"/></g>',
  crown: '<g><path d="M34 29 l5 -25 l11 15 l10 -19 l10 19 l11 -15 l5 25 z" fill="#f2c230" stroke="#a87b12" stroke-width="2" stroke-linejoin="round"/><circle cx="60" cy="19" r="3.5" fill="#c2182b"/><circle cx="43" cy="22" r="2.5" fill="#1f4fa3"/><circle cx="77" cy="22" r="2.5" fill="#1f4fa3"/></g>'
};
function piSVG(o) {
  o = o || {}; const fit = o.outfit || "";
  let curls = "", fur = "";
  for (let i = 0; i < 12; i++) { const a = i * Math.PI / 6; curls += '<circle cx="' + (60 + 33 * Math.cos(a)).toFixed(1) + '" cy="' + (62 + 33 * Math.sin(a)).toFixed(1) + '" r="11"/>'; }
  for (let d = 195; d <= 345; d += 15) { const a = d * Math.PI / 180; fur += '<circle cx="' + (60 + 48 * Math.cos(a)).toFixed(1) + '" cy="' + (60 + 48 * Math.sin(a)).toFixed(1) + '" r="7.5"/>'; }
  let s = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="' + (o.body ? "0 0 120 162" : "0 0 120 120") + '">';
  if (o.body) s += '<g class="pi-tail"><ellipse cx="98" cy="124" rx="8" ry="21" transform="rotate(38 98 124)" fill="#c58a2e"/></g>' +
    '<g fill="#e3ad55"><ellipse cx="60" cy="130" rx="31" ry="26"/><circle cx="35" cy="120" r="10"/><circle cx="85" cy="120" r="10"/><circle cx="32" cy="138" r="10"/><circle cx="88" cy="138" r="10"/></g>' +
    '<g fill="#efc77a"><circle cx="60" cy="116" r="13"/><circle cx="49" cy="127" r="9"/><circle cx="71" cy="127" r="9"/></g>' +
    '<g fill="#f6e3b8"><ellipse cx="46" cy="153" rx="10" ry="7"/><ellipse cx="74" cy="153" rx="10" ry="7"/></g>';
  if (fit === "parka") s += '<circle cx="60" cy="60" r="53" fill="#2f6fb0"/>';
  s += '<g class="pi-ear-l"><ellipse cx="20" cy="68" rx="14" ry="27" transform="rotate(12 20 68)" fill="#c58a2e"/></g>' +
    '<g class="pi-ear-r"><ellipse cx="100" cy="68" rx="14" ry="27" transform="rotate(-12 100 68)" fill="#c58a2e"/></g>' +
    '<g fill="#e3ad55"><circle cx="60" cy="62" r="36"/>' + curls + '</g>' +
    '<g fill="#efc77a"><circle cx="47" cy="27" r="11"/><circle cx="60" cy="22" r="12"/><circle cx="73" cy="27" r="11"/><circle cx="53" cy="37" r="9"/><circle cx="67" cy="37" r="9"/></g>' +
    '<g fill="#f6e3b8"><ellipse cx="60" cy="81" rx="20" ry="15"/><circle cx="45" cy="80" r="9"/><circle cx="75" cy="80" r="9"/></g>' +
    '<g class="pi-eyes"><circle cx="46" cy="59" r="5.2" fill="#2a1c12"/><circle cx="74" cy="59" r="5.2" fill="#2a1c12"/><circle cx="47.6" cy="57.2" r="1.6" fill="#fff"/><circle cx="75.6" cy="57.2" r="1.6" fill="#fff"/></g>' +
    '<path d="M55 88 q5 11 10 0 z" fill="#e8788a"/>' +
    '<ellipse cx="60" cy="73" rx="7.5" ry="5.2" fill="#2a1c12"/>' +
    '<path d="M60 78 v5 M60 83 q-6 6 -11 1 M60 83 q6 6 11 1" stroke="#2a1c12" stroke-width="2.2" fill="none" stroke-linecap="round"/>';
  if (fit === "parka") s += '<g fill="#ffffff">' + fur + '</g>';
  else s += OUTFITS[fit] || "";
  return s + '</svg>';
}
