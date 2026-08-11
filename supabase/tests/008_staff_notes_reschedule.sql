begin;
select plan(19);

insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,raw_app_meta_data,raw_user_meta_data)
values('00000000-0000-0000-0000-000000000000','11111111-1111-1111-1111-111111111111','authenticated','authenticated','staff-reschedule@mika.test','',clock_timestamp(),clock_timestamp(),clock_timestamp(),'{}','{}');
insert into profiles(id,display_name,role) values('11111111-1111-1111-1111-111111111111','Test Staff','STAFF');

select * from create_booking_hold('CUSTOMER_WEB','改期客人','reschedule-main','2026-08-10','09:00',2,'DOUBLE',0);
update bookings set status='CONFIRMED',hold_expires_at=null,deposit_paid=130 where contact='reschedule-main';
select * from create_booking_hold('CUSTOMER_WEB','占位一','reschedule-block-1','2026-08-14','09:00',2,'SINGLE',0);
select * from create_booking_hold('CUSTOMER_WEB','占位二','reschedule-block-2','2026-08-14','09:00',2,'DOUBLE',0);
update bookings set status='CONFIRMED',hold_expires_at=null where contact like 'reschedule-block-%';

select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',true);
set local role authenticated;

update bookings set staff_notes='客人临时有事，定金保留' where contact='reschedule-main';
select is((select staff_notes from bookings where contact='reschedule-main'),'客人临时有事，定金保留','staff notes can be saved');
select throws_ok(
  $$select * from reschedule_booking((select id from bookings where contact='reschedule-main'),'2026-08-14','09:00',2,'DOUBLE',0,0,'冲突测试')$$,
  'P0001','SLOT_UNAVAILABLE','unavailable new slot rolls back'
);
select is((select booking_date from bookings where contact='reschedule-main'),'2026-08-10'::date,'failed reschedule keeps original date');
select is((select count(*) from booking_slots bs join bookings b on b.id=bs.booking_id where b.contact='reschedule-main' and bs.booking_date='2026-08-10'),2::bigint,'failed reschedule keeps original slots');

create temp table original_reference as select booking_number from bookings where contact='reschedule-main';
select lives_ok(
  $$select * from reschedule_booking((select id from bookings where contact='reschedule-main'),'2026-08-14','12:00',2,'DOUBLE',0,0,'保留定金改期')$$,
  'confirmed booking can be rescheduled'
);
select is((select booking_number from bookings where contact='reschedule-main'),(select booking_number from original_reference),'booking number is preserved');
select is((select deposit_paid from bookings where contact='reschedule-main'),130::numeric,'paid deposit is preserved');
select is((select standard_price from bookings where contact='reschedule-main'),280::numeric,'new date uses peak pricing');
select is((select final_price from bookings where contact='reschedule-main'),280::numeric,'new final price is recalculated');
select is((select balance_due from bookings where contact='reschedule-main'),150::numeric,'balance due reflects retained deposit');
select is((select status::text from bookings where contact='reschedule-main'),'CONFIRMED','rescheduled booking remains confirmed');
select is((select count(*) from booking_slots bs join bookings b on b.id=bs.booking_id where b.contact='reschedule-main' and bs.booking_date='2026-08-10'),0::bigint,'successful reschedule releases old slots');
select is((select count(*) from booking_slots bs join bookings b on b.id=bs.booking_id where b.contact='reschedule-main' and bs.booking_date='2026-08-14' and bs.slot_start in ('12:00','13:00')),2::bigint,'successful reschedule occupies new slots');
select ok((select is_active_inventory(status,hold_expires_at) from bookings where contact='reschedule-main'),'active rescheduled booking consumes inventory');
select is((select count(*) from booking_reschedule_history h join bookings b on b.id=h.booking_id where b.contact='reschedule-main' and h.previous_booking_date='2026-08-10' and h.new_booking_date='2026-08-14' and h.retained_deposit_paid=130 and h.reason='保留定金改期'),1::bigint,'reschedule history records old/new schedule, deposit, and reason');
select set_config('test.public_booking_token',(select public_access_token from bookings where contact='reschedule-main'),true);

reset role;
set local role anon;
select throws_ok($$select staff_notes from bookings$$,'42501',null,'staff notes are not anonymously readable');
select ok(not has_function_privilege('anon','public.reschedule_booking(uuid,date,time,integer,booking_type,integer,numeric,text)','execute'),'customer cannot call staff reschedule');
select is((select count(*) from public_booking_summary(current_setting('test.public_booking_token'))),1::bigint,'customer summary remains available after reschedule');
select ok(pg_get_function_result('public.public_booking_summary(text)'::regprocedure) not like '%staff_notes%','customer summary does not expose staff notes');

select * from finish();
rollback;
