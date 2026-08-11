create extension if not exists pgcrypto with schema extensions;

create type public.booking_type as enum ('SINGLE','DOUBLE','PRIVATE');
create type public.booking_status as enum ('HOLD','CONFIRMED','COMPLETED','CANCELLED','EXPIRED','RESCHEDULED');
create type public.booking_source as enum ('CUSTOMER_WEB','STAFF_MANUAL');
create type public.day_type as enum ('WEEKDAY','PEAK');

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null,
  role text not null default 'STAFF' check (role in ('STAFF','ADMIN')),
  created_at timestamptz not null default now()
);

create table public.system_settings (
  id boolean primary key default true check (id),
  business_open time not null default '09:00',
  business_close time not null default '00:00',
  max_normal_groups integer not null default 2 check (max_normal_groups > 0),
  hold_minutes integer not null default 15 check (hold_minutes between 1 and 120),
  deposit_rate numeric(5,4) not null default .5 check (deposit_rate between 0 and 1),
  payment_instructions text not null default '请扫码支付定金，付款后请联系店员确认。',
  payment_qr_url text,
  updated_at timestamptz not null default now()
);
insert into public.system_settings(id) values (true);

create table public.pricing_rules (
  id bigint generated always as identity primary key,
  day_category public.day_type not null,
  booking_type public.booking_type not null,
  one_hour numeric(10,2),
  two_hours numeric(10,2),
  hourly_rate numeric(10,2),
  companion_price numeric(10,2) not null default 0,
  unique(day_category, booking_type),
  check ((booking_type = 'PRIVATE' and hourly_rate is not null) or
         (booking_type <> 'PRIVATE' and one_hour is not null and two_hours is not null))
);
insert into public.pricing_rules(day_category,booking_type,one_hour,two_hours,hourly_rate,companion_price) values
('WEEKDAY','SINGLE',78,135,null,30), ('WEEKDAY','DOUBLE',135,260,null,30),
('WEEKDAY','PRIVATE',null,null,299,0), ('PEAK','SINGLE',88,150,null,40),
('PEAK','DOUBLE',150,280,null,40), ('PEAK','PRIVATE',null,null,350,0);

create table public.holidays (
  holiday_date date primary key,
  name text not null,
  created_at timestamptz not null default now()
);

create table public.bookings (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  booking_number text not null unique,
  booking_source public.booking_source not null,
  customer_name text not null check (length(trim(customer_name)) > 0),
  contact text not null check (length(trim(contact)) > 0),
  booking_date date not null,
  start_time time not null,
  end_time time not null,
  duration_hours integer not null check (duration_hours > 0 and duration_hours <= 15),
  booking_type public.booking_type not null,
  companion_count integer not null default 0 check (companion_count >= 0),
  camera_requested boolean not null default false,
  camera_preference text,
  standard_price numeric(10,2) not null check (standard_price >= 0),
  price_adjustment numeric(10,2) not null default 0,
  final_price numeric(10,2) generated always as (standard_price + price_adjustment) stored,
  deposit_due numeric(10,2) not null check (deposit_due >= 0),
  deposit_paid numeric(10,2) not null default 0 check (deposit_paid >= 0),
  balance_due numeric(10,2) generated always as ((standard_price + price_adjustment) - deposit_paid) stored,
  status public.booking_status not null,
  hold_expires_at timestamptz,
  notes text,
  public_access_token text not null unique default pg_catalog.encode(extensions.gen_random_bytes(32),'hex'),
  created_by uuid references auth.users(id),
  rescheduled_from uuid references public.bookings(id),
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  check (extract(minute from start_time) = 0 and extract(second from start_time) = 0),
  check (extract(minute from end_time) = 0 and extract(second from end_time) = 0),
  check (start_time >= time '09:00'),
  check (extract(hour from start_time)::integer + duration_hours <= 24),
  check (end_time = (start_time + make_interval(hours => duration_hours))::time),
  check (booking_type <> 'PRIVATE' or companion_count = 0),
  check (status <> 'HOLD' or hold_expires_at is not null)
);

create table public.slot_inventory (
  booking_date date not null,
  slot_start time not null check (slot_start >= time '09:00' and slot_start <= time '23:00'),
  primary key (booking_date, slot_start)
);
create table public.booking_slots (
  booking_id uuid not null references public.bookings(id) on delete cascade,
  booking_date date not null,
  slot_start time not null,
  primary key (booking_id, booking_date, slot_start),
  foreign key (booking_date, slot_start) references public.slot_inventory(booking_date, slot_start)
);
create index booking_slots_lookup on public.booking_slots(booking_date,slot_start);
create index bookings_status_expiry on public.bookings(status,hold_expires_at);
create sequence public.booking_daily_sequence;

create or replace function public.is_active_inventory(p_status public.booking_status, p_expiry timestamptz)
returns boolean language sql stable as $$ select p_status='CONFIRMED' or (p_status='HOLD' and p_expiry > clock_timestamp()) $$;

create or replace function public.calculate_price(p_date date,p_type public.booking_type,p_duration integer,p_companions integer default 0)
returns table(day_category public.day_type,base_price numeric,companion_total numeric,standard_price numeric,deposit_due numeric)
language plpgsql security definer set search_path=public as $$
declare r pricing_rules%rowtype; s system_settings%rowtype;
begin
  if p_duration < 1 or p_duration > 15 or p_companions < 0 then raise exception using errcode='22023', message='INVALID_BOOKING_INPUT'; end if;
  day_category := case when extract(isodow from p_date) in (5,6,7) or exists(select 1 from holidays where holiday_date=p_date) then 'PEAK'::day_type else 'WEEKDAY'::day_type end;
  select * into r from pricing_rules where pricing_rules.day_category=calculate_price.day_category and booking_type=p_type;
  select * into s from system_settings where id=true;
  base_price := case when p_type='PRIVATE' then r.hourly_rate*p_duration when p_duration=1 then r.one_hour when p_duration=2 then r.two_hours else (r.two_hours/2)*p_duration end;
  companion_total := case when p_type='PRIVATE' then 0 else r.companion_price*p_companions end;
  standard_price := base_price+companion_total; deposit_due := round(standard_price*s.deposit_rate,2); return next;
end $$;

create or replace function public.slot_availability(p_date date,p_type public.booking_type,p_duration integer)
returns table(start_time time,availability text,normal_groups integer)
language plpgsql security definer set search_path=public as $$
declare h integer; i integer; normal_count integer; any_private boolean; any_active boolean; ok boolean; min_remaining integer:=99; cap integer;
begin
 select max_normal_groups into cap from system_settings where id=true;
 for h in 9..23 loop
   if h+p_duration > 24 then continue; end if; ok:=true; min_remaining:=cap;
   for i in 0..p_duration-1 loop
     select count(*) filter(where b.booking_type<>'PRIVATE'), bool_or(b.booking_type='PRIVATE'), count(*)>0
       into normal_count,any_private,any_active from booking_slots bs join bookings b on b.id=bs.booking_id
       where bs.booking_date=p_date and bs.slot_start=make_time(h+i,0,0) and is_active_inventory(b.status,b.hold_expires_at);
     normal_count:=coalesce(normal_count,0); any_private:=coalesce(any_private,false); any_active:=coalesce(any_active,false);
     if (p_type='PRIVATE' and any_active) or (p_type<>'PRIVATE' and (any_private or normal_count>=cap)) then ok:=false; end if;
     min_remaining:=least(min_remaining,cap-normal_count);
   end loop;
   start_time:=make_time(h,0,0); normal_groups:=cap-min_remaining;
   availability:=case when not ok then 'FULL' when p_type<>'PRIVATE' and min_remaining=1 then 'ONE_LEFT' else 'AVAILABLE' end; return next;
 end loop;
end $$;

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
 number:='MIKA-'||to_char(p_date,'YYYYMMDD')||'-'||lpad(nextval('booking_daily_sequence')::text,3,'0');
 insert into bookings(id,booking_number,booking_source,customer_name,contact,booking_date,start_time,end_time,duration_hours,booking_type,companion_count,camera_requested,camera_preference,standard_price,price_adjustment,deposit_due,status,hold_expires_at,notes,public_access_token,created_by)
 values(new_id,number,p_source,trim(p_name),trim(p_contact),p_date,p_start,e,p_duration,p_type,case when p_type='PRIVATE' then 0 else p_companions end,p_camera<>'不需要',p_camera,price.standard_price,p_adjustment,round((price.standard_price+p_adjustment)*dep_rate,2),'HOLD',expiry,p_notes,token,actor);
 insert into booking_slots select new_id,p_date,(p_start+make_interval(hours=>g))::time from generate_series(0,p_duration-1) g;
 return query select new_id,number,token,expiry;
end $$;

create or replace function public.confirm_booking_payment(p_booking uuid,p_paid numeric)
returns void language plpgsql security definer set search_path=public as $$ begin
 if not exists(select 1 from profiles where id=auth.uid()) then raise exception using errcode='42501',message='STAFF_AUTH_REQUIRED'; end if;
 if p_paid<0 then raise exception 'INVALID_PAYMENT'; end if;
 update bookings set status='CONFIRMED',deposit_paid=p_paid,hold_expires_at=null,updated_at=clock_timestamp() where id=p_booking and status='HOLD';
 if not found then raise exception 'BOOKING_NOT_HOLD'; end if;
end $$;
create or replace function public.cancel_booking(p_booking uuid) returns void language plpgsql security definer set search_path=public as $$ begin
 if not exists(select 1 from profiles where id=auth.uid()) then raise exception using errcode='42501',message='STAFF_AUTH_REQUIRED'; end if;
 update bookings set status='CANCELLED',updated_at=clock_timestamp() where id=p_booking and status in ('HOLD','CONFIRMED'); if not found then raise exception 'BOOKING_NOT_ACTIVE'; end if;
end $$;

create or replace function public.public_booking_summary(p_token text)
returns table(booking_number text,booking_date date,start_time time,end_time time,booking_type booking_type,companion_count integer,final_price numeric,deposit_due numeric,status booking_status,hold_expires_at timestamptz,payment_instructions text,payment_qr_url text)
language sql security definer set search_path=public as $$
 select b.booking_number,b.booking_date,b.start_time,b.end_time,b.booking_type,b.companion_count,b.final_price,b.deposit_due,
 case when b.status='HOLD' and b.hold_expires_at<=clock_timestamp() then 'EXPIRED'::booking_status else b.status end,b.hold_expires_at,s.payment_instructions,s.payment_qr_url
 from bookings b cross join system_settings s where b.public_access_token=p_token limit 1 $$;

create or replace function public.reschedule_booking(p_booking uuid,p_date date,p_start time,p_duration integer)
returns uuid language plpgsql security definer set search_path=public as $$
declare old bookings%rowtype; created record;
begin
 if not exists(select 1 from profiles where id=auth.uid()) then raise exception using errcode='42501',message='STAFF_AUTH_REQUIRED'; end if;
 select * into old from bookings where id=p_booking and status in ('HOLD','CONFIRMED') for update; if not found then raise exception 'BOOKING_NOT_ACTIVE'; end if;
 insert into slot_inventory select d,t from (select distinct d,t from (select old.booking_date d,bs.slot_start t from booking_slots bs where bs.booking_id=old.id union all select p_date,(p_start+make_interval(hours=>g))::time from generate_series(0,p_duration-1) g) q) z on conflict do nothing;
 perform 1 from slot_inventory si where (si.booking_date=old.booking_date and si.slot_start in(select slot_start from booking_slots where booking_id=old.id)) or (si.booking_date=p_date and si.slot_start>=p_start and si.slot_start<(p_start+make_interval(hours=>p_duration))::time) order by booking_date,slot_start for update;
 update bookings set status='RESCHEDULED',updated_at=clock_timestamp() where id=old.id;
 select * into created from create_booking_hold('STAFF_MANUAL',old.customer_name,old.contact,p_date,p_start,p_duration,old.booking_type,old.companion_count,old.camera_preference,old.notes,old.price_adjustment);
 update bookings set rescheduled_from=old.id where id=created.booking_id; return created.booking_id;
exception when others then raise; end $$;

alter table profiles enable row level security; alter table bookings enable row level security; alter table booking_slots enable row level security; alter table slot_inventory enable row level security; alter table pricing_rules enable row level security; alter table holidays enable row level security; alter table system_settings enable row level security;
create policy staff_profiles on profiles for all to authenticated using (true) with check (true);
create policy staff_bookings on bookings for all to authenticated using (exists(select 1 from profiles where id=auth.uid())) with check (exists(select 1 from profiles where id=auth.uid()));
create policy staff_slots on booking_slots for all to authenticated using (exists(select 1 from profiles where id=auth.uid())) with check (exists(select 1 from profiles where id=auth.uid()));
create policy staff_inventory on slot_inventory for select to authenticated using (exists(select 1 from profiles where id=auth.uid()));
create policy public_prices on pricing_rules for select using (true);
create policy public_holidays on holidays for select using (true);
create policy public_settings on system_settings for select using (true);
revoke execute on function calculate_price(date,booking_type,integer,integer),slot_availability(date,booking_type,integer),create_booking_hold(booking_source,text,text,date,time,integer,booking_type,integer,text,text,numeric),public_booking_summary(text),confirm_booking_payment(uuid,numeric),cancel_booking(uuid),reschedule_booking(uuid,date,time,integer) from public;
grant execute on function calculate_price(date,booking_type,integer,integer) to anon,authenticated;
grant execute on function slot_availability(date,booking_type,integer) to anon,authenticated;
grant execute on function create_booking_hold(booking_source,text,text,date,time,integer,booking_type,integer,text,text,numeric) to anon,authenticated;
grant execute on function public_booking_summary(text) to anon,authenticated;
grant execute on function confirm_booking_payment(uuid,numeric),cancel_booking(uuid),reschedule_booking(uuid,date,time,integer) to authenticated;

alter publication supabase_realtime add table public.bookings;
