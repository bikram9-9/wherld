// Treat shop: GET lists the treat packs (and whether the shop is open);
// POST { pack } starts a Stripe Checkout session for the signed-in player and returns its URL.
// Treats are credited only by the stripe-webhook function after Stripe confirms payment.
// (Treats are stored in the players.coins column.)
import { createClient } from "npm:@supabase/supabase-js@2";

const PACKS: Record<string, { coins: number; cents: number; label: string }> = {
  small: { coins: 250, cents: 99, label: "250 treats" },
  medium: { coins: 1400, cents: 499, label: "1,400 treats" },
  large: { coins: 3000, cents: 999, label: "3,000 treats" },
};
const SITE = "https://wherespi.com";
const ALLOWED = new Set(["https://wherespi.com", "https://www.wherespi.com"]);

function cors(req: Request) {
  const o = req.headers.get("Origin") || "";
  return {
    "Access-Control-Allow-Origin": ALLOWED.has(o) ? o : SITE,
    "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    "Vary": "Origin",
  };
}
const json = (req: Request, body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors(req), "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: cors(req) });
  const stripeKey = Deno.env.get("STRIPE_SECRET_KEY");
  const ready = !!stripeKey && !!Deno.env.get("STRIPE_WEBHOOK_SECRET");
  if (req.method === "GET") {
    return json(req, { ready, packs: Object.entries(PACKS).map(([id, p]) => ({ id, coins: p.coins, price: p.cents / 100, label: p.label })) });
  }
  if (req.method !== "POST") return json(req, { error: "Method not allowed" }, 405);
  if (!ready) return json(req, { error: "The treat shop isn't open yet. Check back soon." }, 503);

  const url = Deno.env.get("SUPABASE_URL")!;
  const authHeader = req.headers.get("Authorization") || "";
  const asUser = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: authHeader } } });
  const { data: u } = await asUser.auth.getUser();
  if (!u?.user) return json(req, { error: "Sign in to your account to buy treats." }, 401);
  const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const { data: player } = await admin.from("players").select("id").eq("user_id", u.user.id).maybeSingle();
  if (!player) return json(req, { error: "Pick a nickname first, then you can buy treats." }, 400);

  let packId = "";
  try { packId = String((await req.json()).pack || ""); } catch { /* bad body */ }
  const pack = PACKS[packId];
  if (!pack) return json(req, { error: "Unknown treat pack." }, 400);

  const form = new URLSearchParams({
    mode: "payment",
    success_url: SITE + "/?coins=success",
    cancel_url: SITE + "/?coins=cancel",
    client_reference_id: player.id,
    "line_items[0][quantity]": "1",
    "line_items[0][price_data][currency]": "usd",
    "line_items[0][price_data][unit_amount]": String(pack.cents),
    "line_items[0][price_data][product_data][name]": "Where's Pi · " + pack.label,
    "metadata[player_id]": player.id,
    "metadata[pack]": packId,
    "metadata[coins]": String(pack.coins),
    "payment_intent_data[metadata][player_id]": player.id,
    "payment_intent_data[metadata][pack]": packId,
  });
  if (u.user.email) form.set("customer_email", u.user.email);

  const r = await fetch("https://api.stripe.com/v1/checkout/sessions", {
    method: "POST",
    headers: { Authorization: "Bearer " + stripeKey, "Content-Type": "application/x-www-form-urlencoded" },
    body: form,
  });
  const s = await r.json().catch(() => null);
  if (!r.ok || !s?.url) {
    console.error("stripe checkout failed", r.status, s?.error?.message);
    return json(req, { error: "Couldn't start checkout. Try again in a minute." }, 502);
  }
  return json(req, { url: s.url });
});
