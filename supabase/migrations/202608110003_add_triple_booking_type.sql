-- PostgreSQL enum values must be committed before functions use them.
alter type public.booking_type add value if not exists 'TRIPLE' before 'PRIVATE';
