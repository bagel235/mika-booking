alter table public.bookings add column staff_notes text;

alter table public.booking_reschedule_history
  add column new_booking_date date,
  add column new_start_time time,
  add column new_end_time time,
  add column new_duration_hours integer,
  add column previous_booking_type public.booking_type,
  add column new_booking_type public.booking_type,
  add column previous_companion_count integer,
  add column new_companion_count integer,
  add column previous_price_adjustment numeric(10,2),
  add column new_price_adjustment numeric(10,2),
  add column new_standard_price numeric(10,2),
  add column retained_deposit_paid numeric(10,2),
  add column reason text;

drop function public.public_booking_summary(text);

alter table public.bookings drop column balance_due;
alter table public.bookings add column balance_due numeric(10,2)
  generated always as (greatest((standard_price + price_adjustment) - deposit_paid, 0::numeric)) stored;

create function public.public_booking_summary(p_token text)
returns table(
  booking_number text,
  booking_date date,
  start_time time,
  end_time time,
  booking_type booking_type,
  companion_count integer,
  camera_preference text,
  final_price numeric,
  deposit_due numeric,
  deposit_paid numeric,
  balance_due numeric,
  status booking_status,
  hold_expires_at timestamptz,
  payment_instructions text,
  payment_qr_url text
)
language sql
security definer
set search_path=public
as $$
  select b.booking_number,b.booking_date,b.start_time,b.end_time,b.booking_type,
    b.companion_count,b.camera_preference,b.final_price,b.deposit_due,b.deposit_paid,
    b.balance_due,
    case when b.status='HOLD' and b.hold_expires_at<=clock_timestamp()
      then 'EXPIRED'::booking_status else b.status end,
    b.hold_expires_at,s.payment_instructions,s.payment_qr_url
  from bookings b
  cross join system_settings s
  where b.public_access_token=p_token
  limit 1
$$;

drop function public.reschedule_booking(uuid,date,time,integer);

create function public.reschedule_booking(
  p_booking uuid,
  p_date date,
  p_start time,
  p_duration integer,
  p_type public.booking_type,
  p_companions integer,
  p_adjustment numeric,
  p_reason text default null
)
returns table(
  booking_id uuid,
  standard_price numeric,
  final_price numeric,
  deposit_paid numeric,
  balance_due numeric
)
language plpgsql
security definer
set search_path=public
as $$
declare
  old bookings%rowtype;
  price record;
  i integer;
  cap integer;
  dep_rate numeric;
  normal_count integer;
  private_present boolean;
  active_count integer;
  new_end time;
  effective_companions integer;
begin
  if not exists(select 1 from profiles where id=(select auth.uid())) then
    raise exception using errcode='42501',message='STAFF_AUTH_REQUIRED';
  end if;

  select * into old from bookings where id=p_booking and status='CONFIRMED' for update;
  if not found then raise exception using errcode='P0001',message='BOOKING_NOT_CONFIRMED'; end if;
  if p_start<time '09:00' or p_duration<1 or extract(minute from p_start)<>0 or extract(hour from p_start)+p_duration>24 then
    raise exception using errcode='22023',message='INVALID_BUSINESS_HOURS';
  end if;
  if p_companions<0 then raise exception using errcode='22023',message='INVALID_COMPANION_COUNT'; end if;
  if p_adjustment is null then p_adjustment:=old.price_adjustment; end if;

  effective_companions:=case when p_type='PRIVATE' then 0 else p_companions end;
  new_end:=(p_start+make_interval(hours=>p_duration))::time;

  insert into slot_inventory
  select p_date,(p_start+make_interval(hours=>g))::time
  from generate_series(0,p_duration-1) g
  on conflict do nothing;

  perform 1
  from slot_inventory si
  where (si.booking_date=old.booking_date and si.slot_start in (
      select slot_start from booking_slots where booking_id=old.id
    )) or (si.booking_date=p_date and si.slot_start in (
      select (p_start+make_interval(hours=>g))::time from generate_series(0,p_duration-1) g
    ))
  order by si.booking_date,si.slot_start
  for update;

  select max_normal_groups,deposit_rate into cap,dep_rate from system_settings where id=true;
  for i in 0..p_duration-1 loop
    select count(*) filter(where b.booking_type<>'PRIVATE'),
      coalesce(bool_or(b.booking_type='PRIVATE'),false),count(*)
    into normal_count,private_present,active_count
    from booking_slots bs
    join bookings b on b.id=bs.booking_id
    where bs.booking_date=p_date
      and bs.slot_start=(p_start+make_interval(hours=>i))::time
      and b.id<>old.id
      and is_active_inventory(b.status,b.hold_expires_at);

    if (p_type='PRIVATE' and active_count>0)
      or (p_type<>'PRIVATE' and (private_present or normal_count>=cap)) then
      raise exception using errcode='P0001',message='SLOT_UNAVAILABLE';
    end if;
  end loop;

  select * into price from calculate_price(p_date,p_type,p_duration,effective_companions);
  if price.standard_price+p_adjustment<0 then
    raise exception using errcode='22023',message='INVALID_PRICE_ADJUSTMENT';
  end if;

  insert into booking_reschedule_history(
    booking_id,booking_number,previous_booking_date,previous_start_time,previous_end_time,
    previous_duration_hours,previous_standard_price,changed_by,new_booking_date,new_start_time,
    new_end_time,new_duration_hours,previous_booking_type,new_booking_type,
    previous_companion_count,new_companion_count,previous_price_adjustment,new_price_adjustment,
    new_standard_price,retained_deposit_paid,reason
  ) values (
    old.id,old.booking_number,old.booking_date,old.start_time,old.end_time,
    old.duration_hours,old.standard_price,(select auth.uid()),p_date,p_start,
    new_end,p_duration,old.booking_type,p_type,
    old.companion_count,effective_companions,old.price_adjustment,p_adjustment,
    price.standard_price,old.deposit_paid,nullif(trim(p_reason),'')
  );

  delete from booking_slots where booking_id=old.id;
  insert into booking_slots(booking_id,booking_date,slot_start)
  select old.id,p_date,(p_start+make_interval(hours=>g))::time
  from generate_series(0,p_duration-1) g;

  update bookings
  set booking_date=p_date,
      start_time=p_start,
      end_time=new_end,
      duration_hours=p_duration,
      booking_type=p_type,
      companion_count=effective_companions,
      standard_price=price.standard_price,
      price_adjustment=p_adjustment,
      deposit_due=round((price.standard_price+p_adjustment)*dep_rate,2),
      updated_at=clock_timestamp()
  where id=old.id;

  return query
  select b.id,b.standard_price,b.final_price,b.deposit_paid,b.balance_due
  from bookings b where b.id=old.id;
end $$;

revoke execute on function public.public_booking_summary(text),public.reschedule_booking(uuid,date,time,integer,public.booking_type,integer,numeric,text) from public;
grant execute on function public.public_booking_summary(text) to anon,authenticated;
grant execute on function public.reschedule_booking(uuid,date,time,integer,public.booking_type,integer,numeric,text) to authenticated;
