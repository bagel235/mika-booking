begin;select plan(5);
set local role anon;
select throws_ok($$select * from bookings$$,'42501',null,'anonymous cannot read bookings');
select is((select count(*) from public_booking_summary('invalid-token')),0::bigint,'invalid token returns nothing');
select throws_ok($$select * from create_booking_hold('STAFF_MANUAL','x','x','2032-01-01','10:00',1,'SINGLE',0)$$,'42501','STAFF_AUTH_REQUIRED','anonymous cannot spoof staff source');
select has_function_privilege('anon','public.slot_availability(date,booking_type,integer)','execute'),'anonymous can query minimal availability');
select ok(not has_function_privilege('anon','public.confirm_booking_payment(uuid,numeric)','execute'),'anonymous cannot confirm payment');
select * from finish();rollback;
