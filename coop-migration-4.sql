-- ════════════════════════════════════════════════════════════════
-- Zayen Clicker co-op — migration 4: overflow guard
-- Caps zayens/lifetime/cps/click_power/multiplier at 1e300 so numbers
-- can never reach JavaScript's ~1.8e308 limit and break the room.
-- Hot-swaps three functions (create or replace). No data reset.
-- Run once in Supabase → SQL Editor. Also pulls already-huge rooms
-- back down to the cap on their next action.
-- ════════════════════════════════════════════════════════════════

create or replace function public._coop_accrue(p_code text)
returns public.coop_rooms language plpgsql security definer set search_path = public as $$
declare r public.coop_rooms; gain double precision;
begin
  select * into r from public.coop_rooms where code = p_code for update;
  if not found then return null; end if;
  gain := r.cps * extract(epoch from (now() - r.updated_at));
  if gain > 0 then
    update public.coop_rooms
      set zayens   = least(zayens + gain, 1e300),
          lifetime = least(lifetime + gain, 1e300),
          updated_at = now()
    where code = p_code
    returning * into r;
  end if;
  return r;
end;
$$;

create or replace function public.coop_click(p_code text, p_amount double precision, p_clicks int)
returns public.coop_rooms language plpgsql security definer set search_path = public as $$
declare r public.coop_rooms; v_before bigint; v_after bigint;
begin
  perform public._coop_accrue(p_code);
  select clicks into v_before from public.coop_rooms where code = p_code;
  v_after := v_before + greatest(p_clicks, 0);
  update public.coop_rooms
    set zayens   = least(zayens + greatest(p_amount,0), 1e300),
        lifetime = least(lifetime + greatest(p_amount,0), 1e300),
        clicks   = v_after,
        gems     = gems + (floor(v_after/25.0) - floor(v_before/25.0))
  where code = p_code
  returning * into r;
  return r;
end;
$$;

create or replace function public.coop_buy(
  p_code text, p_cost double precision, p_kind text, p_id text, p_qty int,
  p_cps double precision, p_click double precision, p_mult double precision)
returns public.coop_rooms language plpgsql security definer set search_path = public as $$
declare r public.coop_rooms;
begin
  r := public._coop_accrue(p_code);
  if r is null or p_qty < 1 then return r; end if;
  -- clamp incoming derived stats
  p_cps := least(greatest(p_cps, 0), 1e300);
  p_click := least(greatest(p_click, 0), 1e300);
  p_mult := least(greatest(p_mult, 0), 1e300);

  if p_kind = 'skill' then
    if r.gems < p_cost then return r; end if;
    update public.coop_rooms set
      gems        = gems - p_cost,
      skills      = jsonb_set(skills, array[p_id], 'true'::jsonb, true),
      cps = p_cps, click_power = p_click, multiplier = p_mult, updated_at = now()
    where code = p_code returning * into r;
  elsif r.zayens < p_cost then
    return r;
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
      speed       = jsonb_set(speed, array[p_id], to_jsonb(p_qty), true),
      cps = p_cps, click_power = p_click, multiplier = p_mult, updated_at = now()
    where code = p_code returning * into r;
  end if;
  return r;
end;
$$;
