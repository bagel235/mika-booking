-- Phase 2: aggregate occupancy and staff-only historical import.
create or replace function public.public_slot_occupancy(p_from date, p_to date)
returns table(booking_date date, slot_start time, normal_groups integer, has_private boolean)
language sql security definer set search_path=public as $$
  with grid as (
    select d::date booking_date, make_time(h,0,0) slot_start
    from generate_series(p_from,p_to,interval '1 day') d
    cross join generate_series(9,23) h
  )
  select g.booking_date,g.slot_start,
    count(b.id) filter(where b.booking_type <> 'PRIVATE')::integer,
    coalesce(bool_or(b.booking_type='PRIVATE'),false)
  from grid g
  left join booking_slots bs on bs.booking_date=g.booking_date and bs.slot_start=g.slot_start
  left join bookings b on b.id=bs.booking_id and is_active_inventory(b.status,b.hold_expires_at)
  group by g.booking_date,g.slot_start order by g.booking_date,g.slot_start
$$;

create or replace function public.import_booking(
  p_name text,p_contact text,p_date date,p_start time,p_duration integer,
  p_type booking_type,p_companions integer,p_camera boolean,
  p_standard numeric,p_adjustment numeric,p_deposit_paid numeric,
  p_status booking_status,p_notes text default null
) returns table(booking_id uuid,booking_number text)
language plpgsql security definer set search_path=public as $$
declare created record; new_id uuid:=pg_catalog.gen_random_uuid(); number text; e time; dep_rate numeric;
begin
  if not exists(select 1 from profiles where id=auth.uid()) then
    raise exception using errcode='42501',message='STAFF_AUTH_REQUIRED';
  end if;
  if p_status not in ('CONFIRMED','COMPLETED','CANCELLED') then raise exception using errcode='22023',message='INVALID_IMPORT_STATUS'; end if;
  if p_standard<0 or p_standard+p_adjustment<0 or p_deposit_paid<0 then raise exception using errcode='22023',message='INVALID_PRICE'; end if;
  if exists(select 1 from bookings where customer_name=trim(p_name) and contact=trim(p_contact) and booking_date=p_date and start_time=p_start and booking_type=p_type) then
    raise exception using errcode='23505',message='DUPLICATE_BOOKING';
  end if;
  select deposit_rate into dep_rate from system_settings where id=true;
  if p_status='CONFIRMED' then
    select * into created from create_booking_hold('STAFF_MANUAL',p_name,p_contact,p_date,p_start,p_duration,p_type,p_companions,case when p_camera then '不确定，到店再选' else '不需要' end,p_notes,p_adjustment);
    update bookings set standard_price=p_standard,price_adjustment=p_adjustment,deposit_due=round((p_standard+p_adjustment)*dep_rate,2),deposit_paid=p_deposit_paid,status='CONFIRMED',hold_expires_at=null,updated_at=clock_timestamp() where id=created.booking_id;
    return query select created.booking_id,created.booking_number; return;
  end if;
  if p_start<time '09:00' or p_duration<1 or extract(minute from p_start)<>0 or extract(hour from p_start)+p_duration>24 then raise exception using errcode='22023',message='INVALID_BUSINESS_HOURS'; end if;
  e:=(p_start+make_interval(hours=>p_duration))::time;
  insert into slot_inventory select p_date,(p_start+make_interval(hours=>g))::time from generate_series(0,p_duration-1) g on conflict do nothing;
  number:='MIKA-'||to_char(p_date,'YYYYMMDD')||'-'||lpad(nextval('booking_daily_sequence')::text,3,'0');
  insert into bookings(id,booking_number,booking_source,customer_name,contact,booking_date,start_time,end_time,duration_hours,booking_type,companion_count,camera_requested,camera_preference,standard_price,price_adjustment,deposit_due,deposit_paid,status,notes,created_by)
  values(new_id,number,'STAFF_MANUAL',trim(p_name),trim(p_contact),p_date,p_start,e,p_duration,p_type,case when p_type='PRIVATE' then 0 else p_companions end,p_camera,case when p_camera then '不确定，到店再选' else '不需要' end,p_standard,p_adjustment,round((p_standard+p_adjustment)*dep_rate,2),p_deposit_paid,p_status,p_notes,auth.uid());
  insert into booking_slots select new_id,p_date,(p_start+make_interval(hours=>g))::time from generate_series(0,p_duration-1) g;
  return query select new_id,number;
end $$;

revoke execute on function public.public_slot_occupancy(date,date),public.import_booking(text,text,date,time,integer,booking_type,integer,boolean,numeric,numeric,numeric,booking_status,text) from public;
grant execute on function public.public_slot_occupancy(date,date) to anon,authenticated;
grant execute on function public.import_booking(text,text,date,time,integer,booking_type,integer,boolean,numeric,numeric,numeric,booking_status,text) to authenticated;

-- Tighten staff membership: authenticated users cannot add themselves as staff.
drop policy if exists staff_profiles on profiles;
create policy profile_self_read on profiles for select to authenticated using (id=auth.uid());
create policy staff_manage_settings on system_settings for update to authenticated
  using (exists(select 1 from profiles where id=auth.uid()))
  with check (exists(select 1 from profiles where id=auth.uid()));
create policy staff_manage_prices on pricing_rules for all to authenticated
  using (exists(select 1 from profiles where id=auth.uid()))
  with check (exists(select 1 from profiles where id=auth.uid()));
create policy staff_manage_holidays on holidays for all to authenticated
  using (exists(select 1 from profiles where id=auth.uid()))
  with check (exists(select 1 from profiles where id=auth.uid()));
