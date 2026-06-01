-- ════════════════════════════════════════════════════════════════
-- Zayen Clicker co-op — migration 2: generator speed, areas, shared gems + skills
-- Safe & additive: adds columns if missing and hot-swaps two functions.
-- Existing rooms keep ALL progress. Run once in Supabase → SQL Editor.
-- ════════════════════════════════════════════════════════════════

alter table public.coop_rooms add column if not exists speed  jsonb            not null default '{}';
alter table public.coop_rooms add column if not exists area   text             not null default 'classroom';
alter table public.coop_rooms add column if not exists gems   double precision not null default 0;
alter table public.coop_rooms add column if not exists skills jsonb            not null default '{}';

-- Clicks now also earn shared gems: 1 gem per 25 total clicks.
create or replace function public.coop_click(p_code text, p_amount double precision, p_clicks int)
returns public.coop_rooms language plpgsql security definer set search_path = public as $$
declare r public.coop_rooms; v_before bigint; v_after bigint;
begin
  perform public._coop_accrue(p_code);
  select clicks into v_before from public.coop_rooms where code = p_code;
  v_after := v_before + greatest(p_clicks, 0);
  update public.coop_rooms
    set zayens   = zayens + greatest(p_amount,0),
        lifetime = lifetime + greatest(p_amount,0),
        clicks   = v_after,
        gems     = gems + (floor(v_after/25.0) - floor(v_before/25.0))
  where code = p_code
  returning * into r;
  return r;
end;
$$;

-- coop_buy now also handles 'speed' (paid in Zayens) and 'skill' (paid in gems).
create or replace function public.coop_buy(
  p_code text, p_cost double precision, p_kind text, p_id text, p_qty int,
  p_cps double precision, p_click double precision, p_mult double precision)
returns public.coop_rooms language plpgsql security definer set search_path = public as $$
declare r public.coop_rooms;
begin
  r := public._coop_accrue(p_code);
  if r is null or p_qty < 1 then return r; end if;

  if p_kind = 'skill' then
    if r.gems < p_cost then return r; end if;
    update public.coop_rooms set
      gems        = gems - p_cost,
      skills      = jsonb_set(skills, array[p_id], 'true'::jsonb, true),
      cps = p_cps, click_power = p_click, multiplier = p_mult, updated_at = now()
    where code = p_code returning * into r;

  elsif r.zayens < p_cost then
    return r;  -- not enough Zayens

  elsif p_kind = 'up' then
    update public.coop_rooms set
      zayens      = zayens - p_cost,
      ups         = jsonb_set(ups, array[p_id], to_jsonb(coalesce((ups->>p_id)::int,0) + p_qty), true),
      cps = p_cps, click_power = p_click, multiplier = p_mult, updated_at = now()
    where code = p_code returning * into r;

  elsif p_kind = 'gen' then
    update public.coop_rooms set
      zayens      = zayens - p_cost,
      gens        = jsonb_set(gens, array[p_id], to_jsonb(coalesce((gens->>p_id)::int,0) + p_qty), true),
      cps = p_cps, click_power = p_click, multiplier = p_mult, updated_at = now()
    where code = p_code returning * into r;

  elsif p_kind = 'speed' then
    update public.coop_rooms set
      zayens      = zayens - p_cost,
      speed       = jsonb_set(speed, array[p_id], to_jsonb(p_qty), true),  -- p_qty = new speed level
      cps = p_cps, click_power = p_click, multiplier = p_mult, updated_at = now()
    where code = p_code returning * into r;
  end if;

  return r;
end;
$$;
