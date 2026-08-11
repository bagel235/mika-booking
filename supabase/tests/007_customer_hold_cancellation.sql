begin;
select plan(12);

select * from create_booking_hold('CUSTOMER_WEB','取消测试 A','cancel-a','2035-03-01','09:00',1,'SINGLE',0);
select * from create_booking_hold('CUSTOMER_WEB','取消测试 B','cancel-b','2035-03-01','09:00',1,'SINGLE',0);

select is(
  cancel_booking_by_token((select public_access_token from bookings where contact='cancel-a')),
  true,
  'customer can cancel an active unpaid hold'
);
select is((select status::text from bookings where contact='cancel-a'),'CANCELLED','cancelled hold status is recorded');
select is((select cancelled_by from bookings where contact='cancel-a'),'CUSTOMER','customer cancellation is attributed');
select ok((select cancelled_at is not null from bookings where contact='cancel-a'),'customer cancellation has a timestamp');
select is((select count(*) from slot_availability('2035-03-01','SINGLE',1) where start_time='09:00' and available),1::bigint,'cancellation immediately releases capacity');
select is(cancel_booking_by_token('not-a-real-token'),false,'invalid token cannot cancel a booking');
select is((select status::text from bookings where contact='cancel-b'),'HOLD','another booking remains unchanged');

update bookings set status='CONFIRMED',hold_expires_at=null where contact='cancel-b';
select is(cancel_booking_by_token((select public_access_token from bookings where contact='cancel-b')),false,'confirmed booking cannot be self-cancelled');
select is((select status::text from bookings where contact='cancel-b'),'CONFIRMED','confirmed booking remains confirmed');

select * from create_booking_hold('CUSTOMER_WEB','取消测试 C','cancel-c','2035-03-02','10:00',1,'SINGLE',0);
update bookings set hold_expires_at=clock_timestamp()-interval '1 minute' where contact='cancel-c';
select is(cancel_booking_by_token((select public_access_token from bookings where contact='cancel-c')),false,'expired hold cannot be self-cancelled');
select is((select status::text from bookings where contact='cancel-c'),'HOLD','expired hold is not rewritten as cancelled');

select is(
  (select array_agg(column_name::text order by ordinal_position) from information_schema.columns where table_schema='public' and table_name='bookings' and column_name in ('cancelled_at','cancelled_by')),
  array['cancelled_at','cancelled_by']::text[],
  'cancellation audit columns exist'
);

select * from finish();
rollback;
