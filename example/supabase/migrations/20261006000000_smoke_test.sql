-- Objects used by example/smoke_test.script (public schema, Realtime publication, Storage bucket).
-- Applied with: tools/setup_supabase.sh remote | local

create table if not exists public.todos (
	id bigint generated always as identity primary key,
	user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
	title text not null,
	done boolean not null default false,
	created_at timestamptz not null default now()
);

alter table public.todos enable row level security;

drop policy if exists "todos_select_own" on public.todos;
create policy "todos_select_own" on public.todos for select to authenticated using (user_id = auth.uid());
drop policy if exists "todos_insert_own" on public.todos;
create policy "todos_insert_own" on public.todos for insert to authenticated with check (user_id = auth.uid());
drop policy if exists "todos_update_own" on public.todos;
create policy "todos_update_own" on public.todos for update to authenticated using (user_id = auth.uid());
drop policy if exists "todos_delete_own" on public.todos;
create policy "todos_delete_own" on public.todos for delete to authenticated using (user_id = auth.uid());

grant select, insert, update, delete on public.todos to authenticated;

create or replace function public.add_numbers(a integer, b integer)
returns integer
language sql
immutable
as $$ select a + b $$;

grant execute on function public.add_numbers(integer, integer) to anon, authenticated;

-- Realtime: broadcast row changes of todos (RLS still decides who receives them)
do $$
begin
	if not exists (
		select 1 from pg_publication_tables
		where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'todos'
	) then
		alter publication supabase_realtime add table public.todos;
	end if;
end $$;

-- Storage: private bucket where each user may only touch files under "<user id>/"
insert into storage.buckets (id, name, public)
values ('smoke-test', 'smoke-test', false)
on conflict (id) do nothing;

drop policy if exists "smoke_test_own_files" on storage.objects;
create policy "smoke_test_own_files" on storage.objects for all to authenticated
	using (bucket_id = 'smoke-test' and (storage.foldername(name))[1] = auth.uid()::text)
	with check (bucket_id = 'smoke-test' and (storage.foldername(name))[1] = auth.uid()::text);
