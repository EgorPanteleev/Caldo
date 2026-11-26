-- A project's info is written from several places now (asked 2026-11-26):
-- the app, an agent's update_project_info, and each worker saving an
-- edit made to the project's file on its computer. So every change is
-- numbered, says who made it, and is kept — the last 20 — to look back
-- on and restore from the app.
--
-- `version` goes up by one with each change of `context`, set here and not
-- by whoever writes: a worker saves an edit only where the version is the
-- one it last saw (`... where version = n`), so it never writes over a
-- change it has not seen. `changed_by` says who: `app`, `restore`,
-- `computer:<name>` or `chat:<id>`, kept with the version.

alter table public.agent_projects
  add column version int not null default 1,
  add column changed_by text not null default 'app';

create table public.agent_project_versions (
  id bigint generated always as identity primary key,
  project_id uuid not null references public.agent_projects (id) on delete cascade,
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  version int not null,
  context text not null,
  changed_by text not null default 'app',
  -- A worker's edit that could not be merged with a change made meanwhile:
  -- kept here to restore, not made the info.
  unmerged boolean not null default false,
  created_at timestamptz not null default now()
);

create index agent_project_versions_by_project
  on public.agent_project_versions (project_id, id desc);

create function public.agent_projects_version()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    new.version := 1;
  elsif new.context is distinct from old.context then
    new.version := old.version + 1;
  else
    new.version := old.version;
    new.changed_by := old.changed_by;
  end if;
  return new;
end;
$$;

create trigger agent_projects_version before insert or update on public.agent_projects
  for each row execute function public.agent_projects_version();

-- Each version kept as it is made, and only the last 20 of a project.
create function public.agent_projects_keep()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' and new.version = old.version then
    return new;
  end if;
  insert into public.agent_project_versions
    (project_id, user_id, version, context, changed_by)
  values (new.id, new.user_id, new.version, new.context, new.changed_by);
  return new;
end;
$$;

create trigger agent_projects_keep after insert or update on public.agent_projects
  for each row execute function public.agent_projects_keep();

create function public.agent_project_versions_trim()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from public.agent_project_versions v
  where v.project_id = new.project_id
    and v.id not in (
      select id from public.agent_project_versions
      where project_id = new.project_id
      order by id desc
      limit 20
    );
  return null;
end;
$$;

create trigger agent_project_versions_trim after insert on public.agent_project_versions
  for each row execute function public.agent_project_versions_trim();

-- What there is now is its first version.
insert into public.agent_project_versions
  (project_id, user_id, version, context, changed_by)
select id, user_id, version, context, changed_by from public.agent_projects;

alter table public.agent_project_versions enable row level security;

create policy "own project versions" on public.agent_project_versions
  for select to authenticated using (user_id = (select auth.uid()));

-- A worker keeps an edit it could not merge, on a project of the user's.
create policy "own unmerged edits" on public.agent_project_versions
  for insert to authenticated with check (
    user_id = (select auth.uid()) and unmerged and exists (
      select 1 from public.agent_projects p
      where p.id = project_id and p.user_id = (select auth.uid())
    )
  );

grant select, insert on public.agent_project_versions to authenticated;
