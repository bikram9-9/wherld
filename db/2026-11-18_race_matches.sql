-- Race 1v1: first to 5, 15 or 20 countries. Both players get the same countries in the same
-- order and move through them independently. Six guesses per country; a country you miss is
-- skipped and doesn't count. First to the target wins; if the match clock runs out, most found
-- wins and a tie goes to whoever reached that count first.

alter table public.matches
  add column if not exists target int not null default 1,
  add column if not exists answers text[],
  add column if not exists p1_round int not null default 0,
  add column if not exists p2_round int not null default 0,
  add column if not exists p1_found int not null default 0,
  add column if not exists p2_found int not null default 0,
  add column if not exists p1_last_at timestamptz,
  add column if not exists p2_last_at timestamptz;
update public.matches set answers = array[answer] where answers is null;
alter table public.guesses add column if not exists round int not null default 0;
create index if not exists guesses_match_player_round_idx on public.guesses (match_id, player_id, round);
create index if not exists matches_waiting_target_idx on public.matches (status, target) where status = 'waiting';

create or replace function wh_private.race_len(p_target int) returns interval
language sql immutable set search_path = '' as $$
  select case p_target when 5 then interval '5 minutes' when 15 then interval '12 minutes' when 20 then interval '15 minutes' else interval '5 minutes' end;
$$;

-- Same shuffled list for both players, long enough that nobody runs out by skipping.
create or replace function wh_private.race_answers(p_target int) returns text[]
language sql volatile set search_path = '' as $$
  select array(select key from public.countries where playable order by random() limit least(105, p_target * 3 + 15));
$$;

create or replace function wh_private.check_target(p_target int) returns int
language plpgsql immutable set search_path = '' as $$
begin
  if p_target is null then return 5; end if;
  if p_target not in (5, 15, 20) then raise exception 'Pick a race to 5, 15 or 20 countries'; end if;
  return p_target;
end $$;

-- Start an active race now (both players known).
create or replace function wh_private.start_race(p_id uuid, p_p2 uuid, p_bot boolean, p_rated boolean) returns public.matches
language plpgsql set search_path = '' as $$
declare m public.matches;
begin
  update public.matches set p2 = p_p2, status = 'active', rated = p_rated,
    started_at = now() + interval '4 seconds', ends_at = now() + interval '4 seconds' + wh_private.race_len(target),
    p1_seen = now(), p2_seen = now(),
    bot_next_at = case when p_bot then now() + interval '4 seconds' + (6 + random() * 8) * interval '1 second' else null end
    where id = p_id returning * into m;
  return m;
end $$;

create or replace function wh_private.finish(m public.matches, w uuid, outc text) returns public.matches
language plpgsql set search_path = '' as $$
declare r1 int; r2 int; e1 float8; s1 float8; d1 int := 0; d2 int := 0; k1 int := 0; k2 int := 0; prize int;
begin
  if m.status <> 'active' then return m; end if;
  if m.rated then
    prize := case m.target when 20 then 80 when 15 then 60 else 25 end;
    select rating into r1 from public.players where id = m.p1;
    select rating into r2 from public.players where id = m.p2;
    e1 := 1.0 / (1.0 + power(10.0, (r2 - r1) / 400.0));
    s1 := case when w is null then 0.5 when w = m.p1 then 1.0 else 0.0 end;
    d1 := round(32 * (s1 - e1))::int; d2 := -d1;
    k1 := case when w is null then 10 when w = m.p1 then prize else 0 end;
    k2 := case when w is null then 10 when w = m.p2 then prize else 0 end;
    update public.players set rating = greatest(100, rating + d1),
      wins = wins + (w is not distinct from m.p1)::int, losses = losses + (w is not distinct from m.p2)::int, draws = draws + (w is null)::int
      where id = m.p1;
    update public.players set rating = greatest(100, rating + d2),
      wins = wins + (w is not distinct from m.p2)::int, losses = losses + (w is not distinct from m.p1)::int, draws = draws + (w is null)::int
      where id = m.p2;
    k1 := wh_private.grant_coins(m.p1, k1);
    k2 := wh_private.grant_coins(m.p2, k2);
  end if;
  update public.matches set status = 'done', winner = w, outcome = outc, finished_at = now(),
    p1_delta = d1, p2_delta = d2, p1_coins = k1, p2_coins = k2
    where id = m.id returning * into m;
  return m;
end $$;

-- Records one guess for a player on their current country and moves them on when it ends.
create or replace function wh_private.race_guess(m public.matches, p_player uuid, p_country text, p_at timestamptz) returns public.matches
language plpgsql set search_path = '' as $$
declare is1 boolean := (p_player = m.p1); r int; ans text; a public.countries; c public.countries; n int; ok boolean;
begin
  r := case when is1 then m.p1_round else m.p2_round end;
  ans := m.answers[r + 1];
  if ans is null then raise exception 'No countries left in this match'; end if;
  select * into c from public.countries where key = p_country;
  if not found then raise exception 'Unknown country'; end if;
  if exists (select 1 from public.guesses where match_id = m.id and player_id = p_player and round = r and country = c.key) then
    raise exception 'You already guessed %', c.name;
  end if;
  select * into a from public.countries where key = ans;
  ok := c.key = ans;
  insert into public.guesses(match_id, player_id, country, dist_mi, bearing, correct, round, created_at)
    values (m.id, p_player, c.key, round(wh_private.dist_mi(c.lat, c.lon, a.lat, a.lon))::int,
            wh_private.bearing(c.lat, c.lon, a.lat, a.lon), ok, r, p_at);
  select count(*) into n from public.guesses where match_id = m.id and player_id = p_player and round = r;
  if ok or n >= 6 then
    if is1 then
      update public.matches set p1_round = p1_round + 1, p1_found = p1_found + ok::int, p1_last_at = case when ok then p_at else p1_last_at end
        where id = m.id returning * into m;
    else
      update public.matches set p2_round = p2_round + 1, p2_found = p2_found + ok::int, p2_last_at = case when ok then p_at else p2_last_at end
        where id = m.id returning * into m;
    end if;
  end if;
  return m;
end $$;

create or replace function wh_private.maybe_finish(m public.matches) returns public.matches
language plpgsql set search_path = '' as $$
declare w uuid; total int := coalesce(array_length(m.answers, 1), 1);
begin
  if m.status <> 'active' then return m; end if;
  if m.p1_found >= m.target or m.p2_found >= m.target then
    if m.p1_found >= m.target and (m.p2_found < m.target or m.p1_last_at <= m.p2_last_at) then w := m.p1; else w := m.p2; end if;
    return wh_private.finish(m, w, 'target');
  end if;
  if now() >= m.ends_at or (m.p1_round >= total and m.p2_round >= total) then
    if m.p1_found > m.p2_found then w := m.p1;
    elsif m.p2_found > m.p1_found then w := m.p2;
    elsif m.p1_found = 0 then w := null;
    elsif m.p1_last_at < m.p2_last_at then w := m.p1;
    elsif m.p2_last_at < m.p1_last_at then w := m.p2;
    else w := null; end if;
    return wh_private.finish(m, w, 'time');
  end if;
  return m;
end $$;

create or replace function wh_private.tick(p_match uuid) returns public.matches
language plpgsql set search_path = '' as $$
declare
  m public.matches; bot public.players; a public.countries;
  n int; r int; ans text; target text; radius float8; skill float8; r1 int; nb int; g1 boolean; g2 boolean;
begin
  select * into m from public.matches where id = p_match for update;
  if not found then raise exception 'Match not found'; end if;

  -- Nobody joined a public match within 10 seconds: a bot near your rating steps in.
  if m.status = 'waiting' and not m.private and m.created_at < now() - interval '10 seconds' then
    select rating into r1 from public.players where id = m.p1;
    select * into bot from public.players where is_bot order by abs(rating - r1) + random() * 200 limit 1;
    if found then
      select count(*) into nb from public.matches where p1 = m.p1 and status = 'done' and rated and bot_next_at is not null
        and finished_at >= date_trunc('day', now());
      m := wh_private.start_race(m.id, bot.id, true, nb < 15);
    end if;
  end if;

  if m.status = 'active' then
    if m.bot_next_at is not null then
      select greatest(0.6, least(1.5, rating / 1000.0)) into skill from public.players where id = m.p2;
      loop
        exit when m.bot_next_at > now() or m.bot_next_at >= m.ends_at;
        exit when m.p1_found >= m.target or m.p2_found >= m.target;
        r := m.p2_round; ans := m.answers[r + 1];
        exit when ans is null;
        select * into a from public.countries where key = ans;
        select count(*) into n from public.guesses where match_id = m.id and player_id = m.p2 and round = r;
        n := n + 1;
        target := null;
        if random() < (array[0.05, 0.12, 0.24, 0.38, 0.5, 0.6])[n] * skill then
          target := ans;
        else
          radius := (array[9000, 6500, 4500, 3000, 2000, 1200])[n];
          select c.key into target from public.countries c
            where c.key <> ans
              and not exists (select 1 from public.guesses g where g.match_id = m.id and g.player_id = m.p2 and g.round = r and g.country = c.key)
              and wh_private.dist_mi(c.lat, c.lon, a.lat, a.lon) < radius
            order by random() limit 1;
          if target is null then
            select c.key into target from public.countries c
              where c.key <> ans
                and not exists (select 1 from public.guesses g where g.match_id = m.id and g.player_id = m.p2 and g.round = r and g.country = c.key)
              order by random() limit 1;
          end if;
        end if;
        m := wh_private.race_guess(m, m.p2, target, m.bot_next_at);
        update public.matches set bot_next_at = m.bot_next_at + (7 + random() * 11) * interval '1 second'
          where id = m.id returning * into m;
      end loop;
    end if;
    m := wh_private.maybe_finish(m);
    -- A human who stops checking in for 25 seconds has left: the player still here wins.
    if m.status = 'active' and m.bot_next_at is null and now() > m.started_at + interval '15 seconds' then
      g1 := coalesce(m.p1_seen, m.started_at) < now() - interval '25 seconds';
      g2 := coalesce(m.p2_seen, m.started_at) < now() - interval '25 seconds';
      if g1 and not g2 then m := wh_private.finish(m, m.p2, 'abandon');
      elsif g2 and not g1 then m := wh_private.finish(m, m.p1, 'abandon'); end if;
    end if;
  end if;
  return m;
end $$;

create or replace function wh_private.state_json(m public.matches, p_me uuid) returns json
language plpgsql set search_path = '' as $$
declare
  me public.players; opp public.players; opp_id uuid; is1 boolean := (m.p1 = p_me);
  my_round int; opp_round int; my_found int; opp_found int; cur int; ans text; a public.countries; prev public.countries;
  n_me int; shown int; started boolean; total int := coalesce(array_length(m.answers, 1), 1);
begin
  select * into me from public.players where id = p_me;
  opp_id := case when is1 then m.p2 else m.p1 end;
  if opp_id is not null then select * into opp from public.players where id = opp_id; end if;
  my_round := case when is1 then m.p1_round else m.p2_round end;
  opp_round := case when is1 then m.p2_round else m.p1_round end;
  my_found := case when is1 then m.p1_found else m.p2_found end;
  opp_found := case when is1 then m.p2_found else m.p1_found end;
  -- The country on screen: your current one, or the last one you played once the match is over.
  cur := case when m.status = 'done' then greatest(0, least(my_round, total) - case when my_round > 0 and (my_round >= total or not exists (
           select 1 from public.guesses where match_id = m.id and player_id = p_me and round = my_round)) then 1 else 0 end)
         else least(my_round, total - 1) end;
  ans := m.answers[cur + 1];
  select * into a from public.countries where key = ans;
  if my_round > 0 then select * into prev from public.countries where key = m.answers[my_round]; end if;
  select count(*) into n_me from public.guesses where match_id = m.id and player_id = p_me and round = cur;
  started := m.started_at is not null and now() >= m.started_at;
  shown := case when m.status = 'done' then 6 when started then least(6, n_me + 1) else 0 end;

  return json_build_object(
    'id', m.id, 'status', m.status, 'rated', m.rated, 'code', m.code, 'target', m.target,
    'now', floor(extract(epoch from now()) * 1000),
    'starts', floor(extract(epoch from m.started_at) * 1000),
    'ends', floor(extract(epoch from m.ends_at) * 1000),
    'me', wh_private.profile_json(me),
    'round', my_round, 'found', my_found,
    'last', case when my_round = 0 then null else json_build_object('answer', prev.key, 'answerName', prev.name,
        'ok', exists (select 1 from public.guesses where match_id = m.id and player_id = p_me and round = my_round - 1 and correct)) end,
    'opp', case when opp_id is null then null else json_build_object(
        'name', opp.name, 'rating', opp.rating, 'bot', opp.is_bot, 'outfit', opp.outfit, 'found', opp_found, 'round', opp_round,
        'guesses', (select coalesce(json_agg(json_build_object('d', g.dist_mi, 'ok', g.correct) order by g.id), '[]'::json)
                    from public.guesses g where g.match_id = m.id and g.player_id = opp_id and g.round = opp_round)) end,
    'guesses', (select coalesce(json_agg(json_build_object('key', g.country, 'd', g.dist_mi, 'b', g.bearing, 'ok', g.correct) order by g.id), '[]'::json)
                from public.guesses g where g.match_id = m.id and g.player_id = p_me and g.round = cur),
    'clues', to_json((array[a.pop, a.continent, a.language, a.dish, a.flag, a.outline])[1:shown]),
    'result', case when m.status <> 'done' then null else json_build_object(
        'answer', a.key, 'answerName', a.name, 'outcome', m.outcome,
        'winner', case when m.winner is null then 'draw' when m.winner = p_me then 'me' else 'opp' end,
        'found', my_found, 'oppFound', opp_found,
        'delta', case when is1 then m.p1_delta else m.p2_delta end,
        'coins', case when is1 then m.p1_coins else m.p2_coins end) end
  );
end $$;

create or replace function public.wh_guess(p_token text, p_match uuid, p_country text) returns json
language plpgsql security definer set search_path = '' as $$
declare me public.players; m public.matches;
begin
  me := wh_private.me(p_token);
  update public.matches set p1_seen = case when p1 = me.id then now() else p1_seen end,
    p2_seen = case when p2 = me.id then now() else p2_seen end
    where id = p_match and status = 'active' and (p1 = me.id or p2 = me.id);
  m := wh_private.tick(p_match);
  if m.p1 <> me.id and m.p2 is distinct from me.id then raise exception 'Match not found'; end if;
  if m.status = 'done' then return wh_private.state_json(m, me.id); end if;
  if m.status <> 'active' or now() < m.started_at then raise exception 'The match has not started yet'; end if;
  m := wh_private.race_guess(m, me.id, p_country, now());
  m := wh_private.maybe_finish(m);
  return wh_private.state_json(m, me.id);
end $$;

drop function if exists public.wh_find_match(text);
create or replace function public.wh_find_match(p_token text, p_target int default 5) returns json
language plpgsql security definer set search_path = '' as $$
declare me public.players; m public.matches; mid uuid; t int := wh_private.check_target(p_target); ans text[];
begin
  me := wh_private.me(p_token);
  perform wh_private.hit('find:' || me.id, 90, interval '1 hour', 'That''s a lot of matches. Take a short break and try again soon.');
  delete from public.matches where status = 'waiting' and private and p1 = me.id;

  select id into mid from public.matches
    where status in ('waiting', 'active') and (p1 = me.id or p2 = me.id) order by created_at desc limit 1;
  if mid is not null then
    m := wh_private.tick(mid);
    if m.status = 'waiting' and m.target <> t then delete from public.matches where id = m.id;
    elsif m.status <> 'done' then
      if m.status = 'waiting' then update public.matches set p1_ping = now() where id = m.id; end if;
      return json_build_object('match', m.id);
    end if;
  end if;

  delete from public.matches where status = 'waiting' and p1_ping < now() - interval '2 minutes';

  select mm.* into m from public.matches mm join public.players pp on pp.id = mm.p1
    where mm.status = 'waiting' and not mm.private and mm.target = t and mm.p1 <> me.id and mm.p1_ping > now() - interval '6 seconds'
    order by abs(pp.rating - me.rating), mm.created_at
    limit 1 for update of mm skip locked;
  if found then
    m := wh_private.start_race(m.id, me.id, false, true);
    return json_build_object('match', m.id);
  end if;

  ans := wh_private.race_answers(t);
  insert into public.matches(answer, answers, target, p1) values (ans[1], ans, t, me.id) returning * into m;
  return json_build_object('match', m.id);
end $$;
grant execute on function public.wh_find_match(text, int) to anon, authenticated;

drop function if exists public.wh_challenge_create(text);
create or replace function public.wh_challenge_create(p_token text, p_target int default 5) returns json
language plpgsql security definer set search_path = '' as $$
declare me public.players; m public.matches; c text; t int := wh_private.check_target(p_target); ans text[];
begin
  me := wh_private.me(p_token);
  perform wh_private.hit('chal:' || me.id, 30, interval '1 hour', 'That''s a lot of challenge links. Try again soon.');
  delete from public.matches where status = 'waiting' and p1 = me.id;
  ans := wh_private.race_answers(t);
  c := substr(md5(gen_random_uuid()::text), 1, 8);
  insert into public.matches(answer, answers, target, p1, private, rated, code) values (ans[1], ans, t, me.id, true, false, c) returning * into m;
  return json_build_object('match', m.id, 'code', m.code, 'target', t);
end $$;
grant execute on function public.wh_challenge_create(text, int) to anon, authenticated;

create or replace function public.wh_challenge_join(p_token text, p_code text) returns json
language plpgsql security definer set search_path = '' as $$
declare me public.players; m public.matches;
begin
  me := wh_private.me(p_token);
  select * into m from public.matches where code = lower(trim(p_code)) for update;
  if not found then raise exception 'That challenge link is no longer valid'; end if;
  if m.p1 = me.id or m.p2 is not distinct from me.id then return json_build_object('match', m.id); end if;
  if m.status <> 'waiting' then raise exception 'That challenge has already started'; end if;
  m := wh_private.start_race(m.id, me.id, false, false);
  return json_build_object('match', m.id);
end $$;
