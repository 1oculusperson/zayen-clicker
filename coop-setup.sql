-- ════════════════════════════════════════════════════════════════
-- Zayen Clicker — Co-op multiplayer backend (Supabase / Postgres)
-- Run this once in your Supabase project: SQL Editor → New query → paste → Run.
-- ════════════════════════════════════════════════════════════════

-- Shared room state. One row per room code.
create table if not exists public.coop_rooms (
  code         text primary key,
  zayens       double precision not null default 0,
  lifetime     double precision not null default 0,
  clicks       bigint           not null default 0,
  cps          double precision not null default 0,   -- effective per-second (already multiplied)
  click_power  double precision not null default 1,   -- base click power
  multiplier   double precision not null default 1,
  gens         jsonb            not null default '{}',
  ups          jsonb            not null default '{}',
  updated_at   timestamptz      not null default now()
);

-- Anyone with the anon key can read/write (it's a public co-op game; no accounts).
alter table public.coop_rooms enable row level security;
drop policy if exists coop_anon_all on public.coop_rooms;
create policy coop_anon_all on public.coop_rooms
  for all to anon, authenticated using (true) with check (true);

-- Broadcast row changes to subscribed clients in realtime.
alter publication supabase_realtime add table public.coop_rooms;

-- ── Helper: accrue idle income based on elapsed time, then return the row ──
create or replace function public._coop_accrue(p_code text)
returns public.coop_rooms
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.coop_rooms;
  gain double precision;
begin
  select * into r from public.coop_rooms where code = p_code for update;
  if not found then return null; end if;
  gain := r.cps * extract(epoch from (now() - r.updated_at));
  if gain > 0 then
    update public.coop_rooms
      set zayens = zayens + gain, lifetime = lifetime + gain, updated_at = now()
    where code = p_code
    returning * into r;
  end if;
  return r;
end;
$$;

-- ── Get (create if missing) + accrue idle income ──
create or replace function public.coop_get(p_code text)
returns public.coop_rooms
language plpgsql
security definer
set search_path = public
as $$
declare r public.coop_rooms;
begin
  insert into public.coop_rooms(code) values (p_code)
    on conflict (code) do nothing;
  r := public._coop_accrue(p_code);
  return r;
end;
$$;

-- ── Add pooled click power (batched from the client) ──
create or replace function public.coop_click(p_code text, p_amount double precision, p_clicks int)
returns public.coop_rooms
language plpgsql
security definer
set search_path = public
as $$
declare r public.coop_rooms;
begin
  perform public._coop_accrue(p_code);
  update public.coop_rooms
    set zayens   = zayens + greatest(p_amount, 0),
        lifetime = lifetime + greatest(p_amount, 0),
        clicks   = clicks + greatest(p_clicks, 0)
  where code = p_code
  returning * into r;
  return r;
end;
$$;

-- ── Buy a shared upgrade or generator (atomic funds check) ──
create or replace function public.coop_buy(
  p_code text, p_cost double precision, p_kind text, p_id text, p_qty int,
  p_cps double precision, p_click double precision, p_mult double precision)
returns public.coop_rooms
language plpgsql
security definer
set search_path = public
as $$
declare r public.coop_rooms;
begin
  r := public._coop_accrue(p_code);
  if r is null or r.zayens < p_cost or p_qty < 1 then
    return r;  -- not enough; no-op
  end if;
  if p_kind = 'up' then
    update public.coop_rooms set
      zayens      = zayens - p_cost,
      ups         = jsonb_set(ups, array[p_id], to_jsonb(coalesce((ups->>p_id)::int,0) + p_qty), true),
      cps         = p_cps,
      click_power = p_click,
      multiplier  = p_mult,
      updated_at  = now()
    where code = p_code returning * into r;
  else
    update public.coop_rooms set
      zayens      = zayens - p_cost,
      gens        = jsonb_set(gens, array[p_id], to_jsonb(coalesce((gens->>p_id)::int,0) + p_qty), true),
      cps         = p_cps,
      click_power = p_click,
      multiplier  = p_mult,
      updated_at  = now()
    where code = p_code returning * into r;
  end if;
  return r;
end;
$$;

-- Allow the anon (public) key to call these functions.
grant execute on function public.coop_get(text)                                                   to anon, authenticated;
grant execute on function public.coop_click(text, double precision, int)                          to anon, authenticated;
grant execute on function public.coop_buy(text, double precision, text, text, int, double precision, double precision, double precision) to anon, authenticated;
