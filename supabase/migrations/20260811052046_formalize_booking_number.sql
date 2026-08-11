create table public.booking_number_counters (
  booking_date date primary key,
  last_value integer not null check (last_value >= 1)
);

insert into public.booking_number_counters(booking_date,last_value)
select to_date(substring(booking_number from 6 for 8),'YYYYMMDD'),max(right(booking_number,3)::integer)
from public.bookings
where booking_number ~ '^MIKA-[0-9]{8}-[0-9]{3}$'
group by to_date(substring(booking_number from 6 for 8),'YYYYMMDD')
on conflict (booking_date) do update set last_value=greatest(booking_number_counters.last_value,excluded.last_value);

create or replace function public.next_booking_number(p_booking_date date)
returns text language plpgsql security definer set search_path=public as $$
declare next_value integer;
begin
  insert into booking_number_counters(booking_date,last_value)
  values(p_booking_date,1)
  on conflict (booking_date) do update set last_value=booking_number_counters.last_value+1
  returning last_value into next_value;
  if next_value>999 then raise exception using errcode='22003',message='DAILY_BOOKING_NUMBER_LIMIT_REACHED'; end if;
  return 'MIKA-'||to_char(p_booking_date,'YYYYMMDD')||'-'||lpad(next_value::text,3,'0');
end $$;

create or replace function public.prevent_booking_number_change()
returns trigger language plpgsql set search_path=public as $$
begin
  if new.booking_number is distinct from old.booking_number then
    raise exception using errcode='23514',message='BOOKING_NUMBER_IMMUTABLE';
  end if;
  return new;
end $$;

create trigger booking_number_immutable
before update of booking_number on public.bookings
for each row execute function public.prevent_booking_number_change();

alter table public.bookings add constraint bookings_booking_number_format
check (booking_number ~ '^MIKA-[0-9]{8}-[0-9]{3}$');

create table public.booking_reschedule_history (
  id bigint generated always as identity primary key,
  booking_id uuid not null references public.bookings(id) on delete cascade,
  booking_number text not null,
  previous_booking_date date not null,
  previous_start_time time not null,
  previous_end_time time not null,
  previous_duration_hours integer not null,
  previous_standard_price numeric(10,2) not null,
  changed_by uuid not null references auth.users(id),
  changed_at timestamptz not null default clock_timestamp()
);
alter table public.booking_number_counters enable row level security;
alter table public.booking_reschedule_history enable row level security;
create policy staff_reschedule_history on public.booking_reschedule_history for select to authenticated
using (exists(select 1 from public.profiles where id=(select auth.uid())));

create or replace function public.create_booking_hold(p_source public.booking_source,p_name text,p_contact text,p_date date,p_start time,p_duration integer,p_type public.booking_type,p_companions integer default 0,p_camera text default '不需要',p_notes text default null,p_adjustment numeric default 0)
returns table(booking_id uuid,booking_number text,public_access_token text,hold_expires_at timestamptz)
language plpgsql security definer set search_path=public as $$
declare i integer; e time; cap integer; holds integer; dep_rate numeric; price record; n integer; priv boolean; active_count integer; new_id uuid:=pg_catalog.gen_random_uuid(); token text:=pg_catalog.encode(extensions.gen_random_bytes(32),'hex'); number text; expiry timestamptz; actor uuid:=auth.uid();
begin
 if p_source='CUSTOMER_WEB' and (p_adjustment<>0 or actor is not null) then p_adjustment:=0; end if;
 if p_source='STAFF_MANUAL' and not exists(select 1 from profiles where id=actor) then raise exception using errcode='42501',message='STAFF_AUTH_REQUIRED'; end if;
 if p_start<time '09:00' or p_duration<1 or extract(minute from p_start)<>0 or extract(hour from p_start)+p_duration>24 then raise exception using errcode='22023',message='INVALID_BUSINESS_HOURS'; end if;
 e:=(p_start+make_interval(hours=>p_duration))::time;
 insert into slot_inventory select p_date,(p_start+make_interval(hours=>g))::time from generate_series(0,p_duration-1) g on conflict do nothing;
 perform 1 from slot_inventory where booking_date=p_date and slot_start>=p_start and slot_start<(p_start+make_interval(hours=>p_duration))::time order by slot_start for update;
 select max_normal_groups,hold_minutes,deposit_rate into cap,holds,dep_rate from system_settings where id=true; expiry:=clock_timestamp()+make_interval(mins=>holds);
 for i in 0..p_duration-1 loop
   select count(*) filter(where b.booking_type<>'PRIVATE'),coalesce(bool_or(b.booking_type='PRIVATE'),false),count(*) into n,priv,active_count
   from booking_slots bs join bookings b on b.id=bs.booking_id where bs.booking_date=p_date and bs.slot_start=(p_start+make_interval(hours=>i))::time and is_active_inventory(b.status,b.hold_expires_at);
   if (p_type='PRIVATE' and active_count>0) or (p_type<>'PRIVATE' and (priv or n>=cap)) then raise exception using errcode='P0001',message='SLOT_UNAVAILABLE'; end if;
 end loop;
 select * into price from calculate_price(p_date,p_type,p_duration,p_companions);
 number:=next_booking_number(p_date);
 insert into bookings(id,booking_number,booking_source,customer_name,contact,booking_date,start_time,end_time,duration_hours,booking_type,companion_count,camera_requested,camera_preference,standard_price,price_adjustment,deposit_due,status,hold_expires_at,notes,public_access_token,created_by)
 values(new_id,number,p_source,trim(p_name),trim(p_contact),p_date,p_start,e,p_duration,p_type,case when p_type='PRIVATE' then 0 else p_companions end,p_camera<>'不需要',p_camera,price.standard_price,p_adjustment,round((price.standard_price+p_adjustment)*dep_rate,2),'HOLD',expiry,p_notes,token,actor);
 insert into booking_slots select new_id,p_date,(p_start+make_interval(hours=>g))::time from generate_series(0,p_duration-1) g;
 return query select new_id,number,token,expiry;
end $$;

create or replace function public.import_booking(p_name text,p_contact text,p_date date,p_start time,p_duration integer,p_type booking_type,p_companions integer,p_camera boolean,p_standard numeric,p_adjustment numeric,p_deposit_paid numeric,p_status booking_status,p_notes text default null)
returns table(booking_id uuid,booking_number text)
language plpgsql security definer set search_path=public as $$
declare created record; new_id uuid:=pg_catalog.gen_random_uuid(); number text; e time; dep_rate numeric;
begin
  if not exists(select 1 from profiles where id=auth.uid()) then raise exception using errcode='42501',message='STAFF_AUTH_REQUIRED'; end if;
  if p_status not in ('CONFIRMED','COMPLETED','CANCELLED') then raise exception using errcode='22023',message='INVALID_IMPORT_STATUS'; end if;
  if p_standard<0 or p_standard+p_adjustment<0 or p_deposit_paid<0 then raise exception using errcode='22023',message='INVALID_PRICE'; end if;
  if exists(select 1 from bookings where customer_name=trim(p_name) and contact=trim(p_contact) and booking_date=p_date and start_time=p_start and booking_type=p_type) then raise exception using errcode='23505',message='DUPLICATE_BOOKING'; end if;
  select deposit_rate into dep_rate from system_settings where id=true;
  if p_status='CONFIRMED' then
    select * into created from create_booking_hold('STAFF_MANUAL',p_name,p_contact,p_date,p_start,p_duration,p_type,p_companions,case when p_camera then '不确定，到店再选' else '不需要' end,p_notes,p_adjustment);
    update bookings set standard_price=p_standard,price_adjustment=p_adjustment,deposit_due=round((p_standard+p_adjustment)*dep_rate,2),deposit_paid=p_deposit_paid,status='CONFIRMED',hold_expires_at=null,updated_at=clock_timestamp() where id=created.booking_id;
    return query select created.booking_id,created.booking_number; return;
  end if;
  if p_start<time '09:00' or p_duration<1 or extract(minute from p_start)<>0 or extract(hour from p_start)+p_duration>24 then raise exception using errcode='22023',message='INVALID_BUSINESS_HOURS'; end if;
  e:=(p_start+make_interval(hours=>p_duration))::time;
  insert into slot_inventory select p_date,(p_start+make_interval(hours=>g))::time from generate_series(0,p_duration-1) g on conflict do nothing;
  number:=next_booking_number(p_date);
  insert into bookings(id,booking_number,booking_source,customer_name,contact,booking_date,start_time,end_time,duration_hours,booking_type,companion_count,camera_requested,camera_preference,standard_price,price_adjustment,deposit_due,deposit_paid,status,notes,created_by)
  values(new_id,number,'STAFF_MANUAL',trim(p_name),trim(p_contact),p_date,p_start,e,p_duration,p_type,case when p_type='PRIVATE' then 0 else p_companions end,p_camera,case when p_camera then '不确定，到店再选' else '不需要' end,p_standard,p_adjustment,round((p_standard+p_adjustment)*dep_rate,2),p_deposit_paid,p_status,p_notes,auth.uid());
  insert into booking_slots select new_id,p_date,(p_start+make_interval(hours=>g))::time from generate_series(0,p_duration-1) g;
  return query select new_id,number;
end $$;

create or replace function public.reschedule_booking(p_booking uuid,p_date date,p_start time,p_duration integer)
returns uuid language plpgsql security definer set search_path=public as $$
declare old bookings%rowtype; price record; i integer; cap integer; holds integer; dep_rate numeric; n integer; priv boolean; active_count integer; new_end time;
begin
 if not exists(select 1 from profiles where id=auth.uid()) then raise exception using errcode='42501',message='STAFF_AUTH_REQUIRED'; end if;
 select * into old from bookings where id=p_booking and status in ('HOLD','CONFIRMED') for update; if not found then raise exception 'BOOKING_NOT_ACTIVE'; end if;
 if p_start<time '09:00' or p_duration<1 or extract(minute from p_start)<>0 or extract(hour from p_start)+p_duration>24 then raise exception using errcode='22023',message='INVALID_BUSINESS_HOURS'; end if;
 new_end:=(p_start+make_interval(hours=>p_duration))::time;
 insert into slot_inventory select p_date,(p_start+make_interval(hours=>g))::time from generate_series(0,p_duration-1) g on conflict do nothing;
 perform 1 from slot_inventory si where (si.booking_date=old.booking_date and si.slot_start in(select slot_start from booking_slots where booking_id=old.id)) or (si.booking_date=p_date and si.slot_start in(select (p_start+make_interval(hours=>g))::time from generate_series(0,p_duration-1) g)) order by booking_date,slot_start for update;
 select max_normal_groups,hold_minutes,deposit_rate into cap,holds,dep_rate from system_settings where id=true;
 for i in 0..p_duration-1 loop
   select count(*) filter(where b.booking_type<>'PRIVATE'),coalesce(bool_or(b.booking_type='PRIVATE'),false),count(*) into n,priv,active_count
   from booking_slots bs join bookings b on b.id=bs.booking_id
   where bs.booking_date=p_date and bs.slot_start=(p_start+make_interval(hours=>i))::time and b.id<>old.id and is_active_inventory(b.status,b.hold_expires_at);
   if (old.booking_type='PRIVATE' and active_count>0) or (old.booking_type<>'PRIVATE' and (priv or n>=cap)) then raise exception using errcode='P0001',message='SLOT_UNAVAILABLE'; end if;
 end loop;
 select * into price from calculate_price(p_date,old.booking_type,p_duration,old.companion_count);
 insert into booking_reschedule_history(booking_id,booking_number,previous_booking_date,previous_start_time,previous_end_time,previous_duration_hours,previous_standard_price,changed_by)
 values(old.id,old.booking_number,old.booking_date,old.start_time,old.end_time,old.duration_hours,old.standard_price,auth.uid());
 delete from booking_slots where booking_id=old.id;
 insert into booking_slots select old.id,p_date,(p_start+make_interval(hours=>g))::time from generate_series(0,p_duration-1) g;
 update bookings set booking_date=p_date,start_time=p_start,end_time=new_end,duration_hours=p_duration,standard_price=price.standard_price,deposit_due=round((price.standard_price+old.price_adjustment)*dep_rate,2),hold_expires_at=case when old.status='HOLD' then clock_timestamp()+make_interval(mins=>holds) else null end,updated_at=clock_timestamp() where id=old.id;
 return old.id;
end $$;

revoke execute on function public.next_booking_number(date) from public;
revoke execute on function public.create_booking_hold(booking_source,text,text,date,time,integer,booking_type,integer,text,text,numeric),public.import_booking(text,text,date,time,integer,booking_type,integer,boolean,numeric,numeric,numeric,booking_status,text),public.reschedule_booking(uuid,date,time,integer) from public;
grant execute on function public.create_booking_hold(booking_source,text,text,date,time,integer,booking_type,integer,text,text,numeric) to anon,authenticated;
grant execute on function public.import_booking(text,text,date,time,integer,booking_type,integer,boolean,numeric,numeric,numeric,booking_status,text),public.reschedule_booking(uuid,date,time,integer) to authenticated;

drop sequence if exists public.booking_daily_sequence;
