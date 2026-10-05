-- Custom schema used by the smoke test to check Accept-Profile / Content-Profile handling.
-- The schema is exposed through api.schemas in config.toml.
create schema if not exists smoke_custom;
grant usage on schema smoke_custom to anon, authenticated;

create table if not exists smoke_custom.notes (
	id bigint generated always as identity primary key,
	body text not null
);

alter table smoke_custom.notes enable row level security;

drop policy if exists "notes_read_all" on smoke_custom.notes;
create policy "notes_read_all" on smoke_custom.notes for select to anon, authenticated using (true);

grant select on smoke_custom.notes to anon, authenticated;

insert into smoke_custom.notes (body) values ('hello from smoke_custom');

create or replace function smoke_custom.echo(value text)
returns text
language sql
immutable
as $$ select value $$;

grant execute on function smoke_custom.echo(text) to anon, authenticated;
