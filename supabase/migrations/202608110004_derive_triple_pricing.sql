create or replace function public.calculate_price(
  p_date date,
  p_type public.booking_type,
  p_duration integer,
  p_companions integer default 0
)
returns table(day_category public.day_type,base_price numeric,companion_total numeric,standard_price numeric,deposit_due numeric)
language plpgsql security definer set search_path=public as $$
declare r pricing_rules%rowtype; s system_settings%rowtype; pricing_type booking_type; type_multiplier numeric := 1;
begin
  if p_duration < 1 or p_duration > 15 or p_companions < 0 then raise exception using errcode='22023',message='INVALID_BOOKING_INPUT'; end if;
  day_category := case when extract(isodow from p_date) in (5,6,7) or exists(select 1 from holidays where holiday_date=p_date) then 'PEAK'::day_type else 'WEEKDAY'::day_type end;
  -- TRIPLE has no pricing row: current DOUBLE prices remain its source of truth.
  pricing_type := case when p_type='TRIPLE' then 'DOUBLE'::booking_type else p_type end;
  type_multiplier := case when p_type='TRIPLE' then 1.5 else 1 end;
  select * into r from pricing_rules where pricing_rules.day_category=calculate_price.day_category and booking_type=pricing_type;
  select * into s from system_settings where id=true;
  base_price := case when p_type='PRIVATE' then r.hourly_rate*p_duration when p_duration=1 then r.one_hour*type_multiplier when p_duration=2 then r.two_hours*type_multiplier else ((r.two_hours*type_multiplier)/2)*p_duration end;
  companion_total := case when p_type='PRIVATE' then 0 else r.companion_price*p_companions end;
  standard_price := base_price+companion_total; deposit_due := round(standard_price*s.deposit_rate,2); return next;
end $$;
revoke execute on function public.calculate_price(date,booking_type,integer,integer) from public;
grant execute on function public.calculate_price(date,booking_type,integer,integer) to anon,authenticated;
