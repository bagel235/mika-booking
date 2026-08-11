alter table public.bookings
  add column cancelled_at timestamptz,
  add column cancelled_by text check (cancelled_by in ('CUSTOMER','STAFF'));

create or replace function public.cancel_booking(p_booking uuid)
returns void
language plpgsql
security definer
set search_path=public
as $$
begin
  if not exists(select 1 from profiles where id=auth.uid()) then
    raise exception using errcode='42501',message='STAFF_AUTH_REQUIRED';
  end if;

  update bookings
  set status='CANCELLED',
      cancelled_at=clock_timestamp(),
      cancelled_by='STAFF',
      updated_at=clock_timestamp()
  where id=p_booking and status in ('HOLD','CONFIRMED');

  if not found then raise exception 'BOOKING_NOT_ACTIVE'; end if;
end $$;

create or replace function public.cancel_booking_by_token(p_token text)
returns boolean
language plpgsql
security definer
set search_path=public
as $$
begin
  update bookings
  set status='CANCELLED',
      cancelled_at=clock_timestamp(),
      cancelled_by='CUSTOMER',
      updated_at=clock_timestamp()
  where public_access_token=p_token
    and status='HOLD'
    and hold_expires_at>clock_timestamp();

  return found;
end $$;

drop function public.public_booking_summary(text);

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

revoke execute on function public.cancel_booking_by_token(text),public.public_booking_summary(text) from public;
grant execute on function public.cancel_booking_by_token(text),public.public_booking_summary(text) to anon,authenticated;
