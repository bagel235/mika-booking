do $$
begin
  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'booking_slots'
  ) then
    alter publication supabase_realtime add table public.booking_slots;
  end if;
end
$$;
