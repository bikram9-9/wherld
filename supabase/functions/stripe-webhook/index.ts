// Stripe webhook: verifies Stripe's signature, then credits coins for paid Checkout sessions.
// Idempotent: wh_credit_purchase records each session once, so retries never double-credit.
import { createClient } from "npm:@supabase/supabase-js@2";

const PACKS: Record<string, { coins: number; cents: number }> = {
  small: { coins: 250, cents: 99 },
  medium: { coins: 1400, cents: 499 },
  large: { coins: 3000, cents: 999 },
};
const enc = new TextEncoder();

async function verify(body: string, header: string, secret: string): Promise<boolean> {
  let t = ""; const sigs: string[] = [];
  for (const kv of header.split(",")) {
    const [k, v] = kv.split("=", 2);
    if (k === "t") t = v; else if (k === "v1" && v) sigs.push(v);
  }
  if (!t || !sigs.length) return false;
  if (Math.abs(Date.now() / 1000 - Number(t)) > 300) return false;
  const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, enc.encode(t + "." + body)));
  const hex = Array.from(mac, (b) => b.toString(16).padStart(2, "0")).join("");
  return sigs.some((s) => {
    if (s.length !== hex.length) return false;
    let d = 0; for (let i = 0; i < s.length; i++) d |= s.charCodeAt(i) ^ hex.charCodeAt(i);
    return d === 0;
  });
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });
  const secret = Deno.env.get("STRIPE_WEBHOOK_SECRET");
  if (!secret) return new Response("Webhook not configured", { status: 503 });
  const body = await req.text();
  if (!(await verify(body, req.headers.get("stripe-signature") || "", secret))) {
    return new Response("Bad signature", { status: 400 });
  }
  const event = JSON.parse(body);
  if (event.type !== "checkout.session.completed" && event.type !== "checkout.session.async_payment_succeeded") {
    return new Response(JSON.stringify({ ignored: event.type }), { status: 200 });
  }
  const s = event.data.object;
  if (s.payment_status !== "paid") return new Response(JSON.stringify({ pending: true }), { status: 200 });

  const md = s.metadata || {}, pack = PACKS[md.pack];
  if (!pack || !md.player_id || Number(md.coins) !== pack.coins || s.amount_total !== pack.cents || s.currency !== "usd") {
    console.error("checkout session does not match a coin pack", s.id, md, s.amount_total, s.currency);
    return new Response(JSON.stringify({ error: "mismatch" }), { status: 200 }); // don't make Stripe retry forever
  }
  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const { data, error } = await admin.rpc("wh_credit_purchase", {
    p_session: s.id, p_player: md.player_id, p_pack: md.pack, p_coins: pack.coins, p_amount: s.amount_total, p_currency: s.currency,
  });
  if (error) { console.error("credit failed", s.id, error.message); return new Response("Credit failed", { status: 500 }); }
  return new Response(JSON.stringify(data), { status: 200, headers: { "Content-Type": "application/json" } });
});
