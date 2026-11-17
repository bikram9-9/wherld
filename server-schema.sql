create schema if not exists wh_private;

create table public.countries (
  key text primary key,
  name text not null,
  lat double precision not null,
  lon double precision not null,
  playable boolean not null default false,
  pop text, continent text, language text, dish text, flag text, outline text
);

create table public.players (
  id uuid primary key default gen_random_uuid(),
  token_hash text unique,
  name text not null,
  rating int not null default 1000,
  coins int not null default 100,
  wins int not null default 0,
  losses int not null default 0,
  draws int not null default 0,
  is_bot boolean not null default false,
  created_at timestamptz not null default now(),
  last_seen timestamptz not null default now()
);

create table public.matches (
  id uuid primary key default gen_random_uuid(),
  status text not null default 'waiting' check (status in ('waiting','active','done')),
  answer text not null references public.countries(key),
  p1 uuid not null references public.players(id),
  p2 uuid references public.players(id),
  created_at timestamptz not null default now(),
  p1_ping timestamptz not null default now(),
  started_at timestamptz,
  ends_at timestamptz,
  bot_next_at timestamptz,
  winner uuid references public.players(id),
  outcome text,
  finished_at timestamptz,
  p1_delta int, p2_delta int, p1_coins int, p2_coins int
);
create index matches_open_idx on public.matches(status) where status <> 'done';
create index matches_p1_idx on public.matches(p1);
create index matches_p2_idx on public.matches(p2);
create index matches_answer_idx on public.matches(answer);
create index matches_winner_idx on public.matches(winner);

create table public.guesses (
  id bigint generated always as identity primary key,
  match_id uuid not null references public.matches(id) on delete cascade,
  player_id uuid not null references public.players(id),
  country text not null references public.countries(key),
  dist_mi int not null,
  bearing int not null,
  correct boolean not null,
  created_at timestamptz not null default now(),
  unique (match_id, player_id, country)
);
create index guesses_player_idx on public.guesses(player_id);
create index guesses_country_idx on public.guesses(country);

-- Nobody reads or writes tables directly. Everything goes through the wh_* functions below.
alter table public.countries enable row level security;
alter table public.players enable row level security;
alter table public.matches enable row level security;
alter table public.guesses enable row level security;
revoke all on public.countries, public.players, public.matches, public.guesses from anon, authenticated;

-- ---------- helpers (not reachable from the API) ----------
create or replace function wh_private.dist_mi(lat1 float8, lon1 float8, lat2 float8, lon2 float8)
returns float8 language sql immutable set search_path = '' as $$
  select 3958.8 * 2 * asin(least(1.0, sqrt(
    power(sin(radians(lat2 - lat1) / 2), 2) +
    cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lon2 - lon1) / 2), 2))));
$$;

create or replace function wh_private.bearing(lat1 float8, lon1 float8, lat2 float8, lon2 float8)
returns int language sql immutable set search_path = '' as $$
  select (((degrees(atan2(
      sin(radians(lon2 - lon1)) * cos(radians(lat2)),
      cos(radians(lat1)) * sin(radians(lat2)) - sin(radians(lat1)) * cos(radians(lat2)) * cos(radians(lon2 - lon1))
    )))::numeric + 360) % 360)::int;
$$;

create or replace function wh_private.me(p_token text)
returns public.players language plpgsql security definer set search_path = public, wh_private as $$
declare p public.players;
begin
  if p_token is null or length(p_token) < 20 or length(p_token) > 200 then raise exception 'Bad player token'; end if;
  update public.players set last_seen = now()
    where token_hash = encode(sha256(convert_to(p_token, 'UTF8')), 'hex') returning * into p;
  if not found then raise exception 'Unknown player'; end if;
  return p;
end $$;

create or replace function wh_private.profile_json(p public.players)
returns json language sql stable set search_path = '' as $$
  select json_build_object('name', p.name, 'rating', p.rating, 'coins', p.coins,
                           'wins', p.wins, 'losses', p.losses, 'draws', p.draws);
$$;

-- Decide the match if it is over: first correct guess wins; on time-out or when both
-- players are out of guesses, the closest guess wins. Applies rating and coins once.
create or replace function wh_private.maybe_finish(m public.matches)
returns public.matches language plpgsql security definer set search_path = public, wh_private as $$
declare
  w uuid; outc text; c1 int; c2 int; b1 int; b2 int;
  r1 int; r2 int; e1 float8; s1 float8; d1 int; d2 int; k1 int; k2 int;
begin
  if m.status <> 'active' then return m; end if;
  select player_id into w from public.guesses where match_id = m.id and correct order by created_at, id limit 1;
  if w is not null then
    outc := 'solved';
  else
    select count(*) filter (where player_id = m.p1), count(*) filter (where player_id = m.p2),
           min(dist_mi) filter (where player_id = m.p1), min(dist_mi) filter (where player_id = m.p2)
      into c1, c2, b1, b2 from public.guesses where match_id = m.id;
    if now() >= m.ends_at or (c1 >= 6 and c2 >= 6) then
      if b1 is null and b2 is null then w := null;
      elsif b2 is null or b1 < b2 then w := m.p1;
      elsif b1 is null or b2 < b1 then w := m.p2;
      else w := null; end if;
      outc := case when now() >= m.ends_at then 'time' else 'closest' end;
    else
      return m;
    end if;
  end if;

  select rating into r1 from public.players where id = m.p1;
  select rating into r2 from public.players where id = m.p2;
  e1 := 1.0 / (1.0 + power(10.0, (r2 - r1) / 400.0));
  s1 := case when w is null then 0.5 when w = m.p1 then 1.0 else 0.0 end;
  d1 := round(32 * (s1 - e1))::int; d2 := -d1;
  k1 := case when w is null then 10 when w = m.p1 then 25 else 0 end;
  k2 := case when w is null then 10 when w = m.p2 then 25 else 0 end;

  update public.players set rating = greatest(100, rating + d1), coins = coins + k1,
    wins = wins + (w is not distinct from m.p1)::int, losses = losses + (w is not distinct from m.p2)::int, draws = draws + (w is null)::int
    where id = m.p1;
  update public.players set rating = greatest(100, rating + d2), coins = coins + k2,
    wins = wins + (w is not distinct from m.p2)::int, losses = losses + (w is not distinct from m.p1)::int, draws = draws + (w is null)::int
    where id = m.p2;

  update public.matches set status = 'done', winner = w, outcome = outc, finished_at = now(),
    p1_delta = d1, p2_delta = d2, p1_coins = k1, p2_coins = k2
    where id = m.id returning * into m;
  return m;
end $$;

-- Advance a match: seat a bot if nobody joined in 10 s, play any bot moves that are due, end on time.
create or replace function wh_private.tick(p_match uuid)
returns public.matches language plpgsql security definer set search_path = public, wh_private as $$
declare
  m public.matches; bot public.players; a public.countries;
  n int; target text; radius float8; skill float8; r1 int;
begin
  select * into m from public.matches where id = p_match for update;
  if not found then raise exception 'Match not found'; end if;

  if m.status = 'waiting' and m.created_at < now() - interval '10 seconds' then
    select rating into r1 from public.players where id = m.p1;
    select * into bot from public.players where is_bot order by abs(rating - r1) + random() * 200 limit 1;
    if found then
      update public.matches set p2 = bot.id, status = 'active',
        started_at = now() + interval '4 seconds', ends_at = now() + interval '124 seconds',
        bot_next_at = now() + interval '4 seconds' + (8 + random() * 10) * interval '1 second'
        where id = m.id returning * into m;
    end if;
  end if;

  if m.status = 'active' then
    if m.bot_next_at is not null then
      select * into a from public.countries where key = m.answer;
      select greatest(0.6, least(1.5, rating / 1000.0)) into skill from public.players where id = m.p2;
      loop
        exit when m.bot_next_at > now() or m.bot_next_at >= m.ends_at;
        exit when exists (select 1 from public.guesses where match_id = m.id and correct);
        select count(*) into n from public.guesses where match_id = m.id and player_id = m.p2;
        exit when n >= 6;
        n := n + 1;
        target := null;
        if random() < (array[0.03, 0.08, 0.18, 0.32, 0.45, 0.55])[n] * skill then
          target := m.answer;
        else
          radius := (array[9000, 6500, 4500, 3000, 2000, 1200])[n];
          select c.key into target from public.countries c
            where c.key <> m.answer
              and not exists (select 1 from public.guesses g where g.match_id = m.id and g.player_id = m.p2 and g.country = c.key)
              and wh_private.dist_mi(c.lat, c.lon, a.lat, a.lon) < radius
            order by random() limit 1;
          if target is null then
            select c.key into target from public.countries c
              where c.key <> m.answer
                and not exists (select 1 from public.guesses g where g.match_id = m.id and g.player_id = m.p2 and g.country = c.key)
              order by random() limit 1;
          end if;
        end if;
        insert into public.guesses(match_id, player_id, country, dist_mi, bearing, correct, created_at)
          select m.id, m.p2, c.key, round(wh_private.dist_mi(c.lat, c.lon, a.lat, a.lon))::int,
                 wh_private.bearing(c.lat, c.lon, a.lat, a.lon), c.key = m.answer, m.bot_next_at
          from public.countries c where c.key = target;
        update public.matches set bot_next_at = m.bot_next_at + (9 + random() * 13) * interval '1 second'
          where id = m.id returning * into m;
      end loop;
    end if;
    m := wh_private.maybe_finish(m);
  end if;
  return m;
end $$;

-- What one player is allowed to see. The answer is only included once the match is over.
create or replace function wh_private.state_json(m public.matches, p_me uuid)
returns json language plpgsql stable security definer set search_path = public, wh_private as $$
declare
  me public.players; opp public.players; a public.countries;
  opp_id uuid; n_me int; shown int; started boolean;
begin
  select * into me from public.players where id = p_me;
  opp_id := case when m.p1 = p_me then m.p2 else m.p1 end;
  if opp_id is not null then select * into opp from public.players where id = opp_id; end if;
  select * into a from public.countries where key = m.answer;
  select count(*) into n_me from public.guesses where match_id = m.id and player_id = p_me;
  started := m.started_at is not null and now() >= m.started_at;
  shown := case when m.status = 'done' then 6 when started then least(6, n_me + 1) else 0 end;

  return json_build_object(
    'id', m.id,
    'status', m.status,
    'now', floor(extract(epoch from now()) * 1000),
    'starts', floor(extract(epoch from m.started_at) * 1000),
    'ends', floor(extract(epoch from m.ends_at) * 1000),
    'me', wh_private.profile_json(me),
    'opp', case when opp_id is null then null else json_build_object(
        'name', opp.name, 'rating', opp.rating, 'bot', opp.is_bot,
        'guesses', (select coalesce(json_agg(json_build_object('d', g.dist_mi, 'ok', g.correct) order by g.id), '[]'::json)
                    from public.guesses g where g.match_id = m.id and g.player_id = opp_id)) end,
    'guesses', (select coalesce(json_agg(json_build_object('key', g.country, 'd', g.dist_mi, 'b', g.bearing, 'ok', g.correct) order by g.id), '[]'::json)
                from public.guesses g where g.match_id = m.id and g.player_id = p_me),
    'clues', to_json((array[a.pop, a.continent, a.language, a.dish, a.flag, a.outline])[1:shown]),
    'result', case when m.status <> 'done' then null else json_build_object(
        'answer', m.answer, 'answerName', a.name, 'outcome', m.outcome,
        'winner', case when m.winner is null then 'draw' when m.winner = p_me then 'me' else 'opp' end,
        'delta', case when m.p1 = p_me then m.p1_delta else m.p2_delta end,
        'coins', case when m.p1 = p_me then m.p1_coins else m.p2_coins end) end
  );
end $$;

-- ---------- public API ----------
create or replace function public.wh_register(p_token text, p_name text)
returns json language plpgsql security definer set search_path = public, wh_private as $$
declare h text; nm text; p public.players;
begin
  if p_token is null or length(p_token) < 20 or length(p_token) > 200 then raise exception 'Bad player token'; end if;
  h := encode(sha256(convert_to(p_token, 'UTF8')), 'hex');
  nm := left(trim(regexp_replace(coalesce(p_name, ''), '[^A-Za-z0-9 _-]', '', 'g')), 16);
  if length(nm) < 3 then nm := 'Explorer' || (1000 + floor(random() * 9000))::int; end if;
  if lower(nm) like '%bot' then nm := nm || '1'; end if;
  insert into public.players(token_hash, name) values (h, nm)
    on conflict (token_hash) do update set name = excluded.name, last_seen = now()
    returning * into p;
  return wh_private.profile_json(p);
end $$;

create or replace function public.wh_profile(p_token text)
returns json language plpgsql security definer set search_path = public, wh_private as $$
begin
  return wh_private.profile_json(wh_private.me(p_token));
end $$;

create or replace function public.wh_find_match(p_token text)
returns json language plpgsql security definer set search_path = public, wh_private as $$
declare me public.players; m public.matches; ans text; mid uuid;
begin
  me := wh_private.me(p_token);

  select id into mid from public.matches
    where status in ('waiting', 'active') and (p1 = me.id or p2 = me.id) order by created_at desc limit 1;
  if mid is not null then
    m := wh_private.tick(mid);
    if m.status <> 'done' then
      if m.status = 'waiting' then update public.matches set p1_ping = now() where id = m.id; end if;
      return json_build_object('match', m.id);
    end if;
  end if;

  delete from public.matches where status = 'waiting' and p1_ping < now() - interval '2 minutes';

  select mm.* into m from public.matches mm join public.players pp on pp.id = mm.p1
    where mm.status = 'waiting' and mm.p1 <> me.id and mm.p1_ping > now() - interval '6 seconds'
    order by abs(pp.rating - me.rating), mm.created_at
    limit 1 for update of mm skip locked;
  if found then
    update public.matches set p2 = me.id, status = 'active',
      started_at = now() + interval '4 seconds', ends_at = now() + interval '124 seconds'
      where id = m.id;
    return json_build_object('match', m.id);
  end if;

  select key into ans from public.countries where playable order by random() limit 1;
  insert into public.matches(answer, p1) values (ans, me.id) returning * into m;
  return json_build_object('match', m.id);
end $$;

create or replace function public.wh_cancel(p_token text)
returns json language plpgsql security definer set search_path = public, wh_private as $$
declare me public.players;
begin
  me := wh_private.me(p_token);
  delete from public.matches where status = 'waiting' and p1 = me.id;
  return json_build_object('ok', true);
end $$;

create or replace function public.wh_state(p_token text, p_match uuid)
returns json language plpgsql security definer set search_path = public, wh_private as $$
declare me public.players; m public.matches;
begin
  me := wh_private.me(p_token);
  select * into m from public.matches where id = p_match;
  if not found or (m.p1 <> me.id and m.p2 is distinct from me.id) then raise exception 'Match not found'; end if;
  if m.status <> 'done' then
    if m.status = 'waiting' and m.p1 = me.id then update public.matches set p1_ping = now() where id = m.id; end if;
    m := wh_private.tick(p_match);
  end if;
  return wh_private.state_json(m, me.id);
end $$;

create or replace function public.wh_guess(p_token text, p_match uuid, p_country text)
returns json language plpgsql security definer set search_path = public, wh_private as $$
declare me public.players; m public.matches; a public.countries; c public.countries; n int;
begin
  me := wh_private.me(p_token);
  m := wh_private.tick(p_match);
  if m.p1 <> me.id and m.p2 is distinct from me.id then raise exception 'Match not found'; end if;
  if m.status = 'done' then return wh_private.state_json(m, me.id); end if;
  if m.status <> 'active' or now() < m.started_at then raise exception 'The match has not started yet'; end if;
  select count(*) into n from public.guesses where match_id = m.id and player_id = me.id;
  if n >= 6 then raise exception 'You are out of guesses'; end if;
  select * into c from public.countries where key = p_country;
  if not found then raise exception 'Unknown country'; end if;
  if exists (select 1 from public.guesses where match_id = m.id and player_id = me.id and country = c.key) then
    raise exception 'You already guessed %', c.name;
  end if;
  select * into a from public.countries where key = m.answer;
  insert into public.guesses(match_id, player_id, country, dist_mi, bearing, correct)
    values (m.id, me.id, c.key, round(wh_private.dist_mi(c.lat, c.lon, a.lat, a.lon))::int,
            wh_private.bearing(c.lat, c.lon, a.lat, a.lon), c.key = m.answer);
  m := wh_private.maybe_finish(m);
  return wh_private.state_json(m, me.id);
end $$;

create or replace function public.wh_leaderboard()
returns json language sql stable security definer set search_path = public, wh_private as $$
  select coalesce(json_agg(t), '[]'::json) from (
    select name, rating, wins, losses, draws from public.players
    where not is_bot and wins + losses + draws > 0
    order by rating desc, wins desc limit 20) t;
$$;

revoke all on schema wh_private from public, anon, authenticated;
revoke execute on all functions in schema wh_private from public, anon, authenticated;
revoke execute on function public.wh_register(text, text), public.wh_profile(text), public.wh_find_match(text),
  public.wh_cancel(text), public.wh_state(text, uuid), public.wh_guess(text, uuid, text), public.wh_leaderboard() from public;
grant execute on function public.wh_register(text, text), public.wh_profile(text), public.wh_find_match(text),
  public.wh_cancel(text), public.wh_state(text, uuid), public.wh_guess(text, uuid, text), public.wh_leaderboard() to anon, authenticated;

insert into public.players(name, rating, is_bot) values
  ('Atlas Bot', 820, true), ('Compass Bot', 880, true), ('Tundra Bot', 930, true), ('Savanna Bot', 970, true),
  ('Meridian Bot', 1000, true), ('Monsoon Bot', 1030, true), ('Fjord Bot', 1070, true), ('Equator Bot', 1110, true),
  ('Delta Bot', 1160, true), ('Summit Bot', 1220, true), ('Polaris Bot', 1290, true), ('Magellan Bot', 1380, true);
