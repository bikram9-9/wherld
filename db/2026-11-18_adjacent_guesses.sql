-- Adjacent guesses: a miss that shares a land border with Pi's country.
alter table public.guesses add column if not exists adj boolean not null default false;

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
  insert into public.guesses(match_id, player_id, country, dist_mi, bearing, correct, round, created_at, adj)
    values (m.id, p_player, c.key, round(wh_private.dist_mi(c.lat, c.lon, a.lat, a.lon))::int,
            wh_private.bearing(c.lat, c.lon, a.lat, a.lon), ok, r, p_at,
            not ok and exists (select 1 from wh_private.neighbors nb where nb.a = c.key and nb.b = ans));
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
        'guesses', (select coalesce(json_agg(json_build_object('d', g.dist_mi, 'ok', g.correct, 'adj', g.adj) order by g.id), '[]'::json)
                    from public.guesses g where g.match_id = m.id and g.player_id = opp_id and g.round = opp_round)) end,
    'guesses', (select coalesce(json_agg(json_build_object('key', g.country, 'd', g.dist_mi, 'b', g.bearing, 'ok', g.correct, 'adj', g.adj) order by g.id), '[]'::json)
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
