-- Both the timeout and the skip button fill the same locked match.
create or replace function wh_private.start_bot(m public.matches) returns public.matches
language plpgsql set search_path = '' as $$
declare
  bot_id uuid;
  player_rating int;
  ranked_bot_games int;
begin
  select rating into player_rating from public.players where id = m.p1;
  select id into bot_id from public.players where is_bot
    order by abs(rating - player_rating) + random() * 200 limit 1;
  if not found then return m; end if;

  select count(*) into ranked_bot_games from public.matches
    where p1 = m.p1 and status = 'done' and rated and bot_next_at is not null
      and finished_at >= date_trunc('day', now());
  return wh_private.start_race(m.id, bot_id, true, ranked_bot_games < 15);
end $$;
revoke execute on function wh_private.start_bot(public.matches) from public, anon, authenticated;

CREATE OR REPLACE FUNCTION wh_private.tick(p_match uuid)
 RETURNS public.matches
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  m public.matches; a public.countries;
  n int; r int; ans text; target text; radius float8; skill float8; g1 boolean; g2 boolean;
begin
  select * into m from public.matches where id = p_match for update;
  if not found then raise exception 'Match not found'; end if;

  -- Fill the public queue with a bot after 10 seconds when nobody joins.
  if m.status = 'waiting' and not m.private and m.created_at < now() - interval '10 seconds' then
    m := wh_private.start_bot(m);
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
    if m.status = 'active' and m.bot_next_at is null and now() > m.started_at + interval '15 seconds' then
      g1 := coalesce(m.p1_seen, m.started_at) < now() - interval '25 seconds';
      g2 := coalesce(m.p2_seen, m.started_at) < now() - interval '25 seconds';
      if g1 and not g2 then m := wh_private.finish(m, m.p2, 'abandon');
      elsif g2 and not g1 then m := wh_private.finish(m, m.p1, 'abandon'); end if;
    end if;
  end if;
  return m;
end $function$;

create or replace function public.wh_play_bot(p_token text, p_match uuid) returns json
language plpgsql security definer set search_path = '' as $$
declare
  me public.players;
  m public.matches;
begin
  me := wh_private.me(p_token);
  select * into m from public.matches where id = p_match for update;
  if not found or m.private or (m.p1 <> me.id and m.p2 is distinct from me.id) then
    raise exception 'Match not found';
  end if;

  -- If matchmaking won the lock first, return that race as-is.
  if m.status = 'waiting' then
    m := wh_private.start_bot(m);
    if m.status = 'waiting' then raise exception 'No bots are available right now.'; end if;
  end if;
  return wh_private.state_json(m, me.id);
end $$;
revoke execute on function public.wh_play_bot(text, uuid) from public;
grant execute on function public.wh_play_bot(text, uuid) to anon, authenticated;

notify pgrst, 'reload schema';
