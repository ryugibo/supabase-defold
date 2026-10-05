-- Objects used by example/smoke_test.script. Run once in the Supabase SQL Editor (safe to re-run).
-- Also enable Authentication -> Sign In / Providers -> "Allow anonymous sign-ins".

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
