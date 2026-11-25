-- Projects for agents: what a chat is about, written once in the app. Each
-- is a name, a colour the chat list wears it in, the words the agent is told
-- of it, and the folders on a worker it works on (`sources`, written from
-- `~`). A project may sit under another, to any depth: a subproject is told
-- its parents' words before its own and works on their folders as well.
--
-- A chat keeps its project as it was when the chat began (`chats.project`,
-- {name, colour, context: [{name, body}], sources}), as it keeps its rules:
-- its worker reads it from the chat alone, and a project changed later does
-- not change what a chat was told. `chats.project_id` is only for the list,
-- to colour and sort chats by the project as it is now.
--
-- Every chat begun in the app has a workspace of its own on its worker
-- (`chats.workspace`): the app asks with {}, and the worker makes it and
-- writes down where it is ({root, places: [{source, path, branch?}]}), a
-- git worktree for each source that is a repository. Null for the chats
-- from before, and a task's watcher's, which run in `dir`.

create table public.agent_projects (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  parent_id uuid references public.agent_projects (id) on delete cascade,
  name text not null default '',
  colour text,
  context text not null default '',
  sources jsonb not null default '[]',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index agent_projects_by_user on public.agent_projects (user_id, name);
create index agent_projects_by_parent on public.agent_projects (parent_id);

-- Stamped, and kept a tree of one user's own: a parent of someone else's
-- would be deleted from under it by them, and a project under its own
-- child would be a loop no chat could read to its root.
create function public.agent_projects_check()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  above uuid := new.parent_id;
  steps int := 0;
begin
  new.updated_at := now();
  if new.parent_id is null then
    return new;
  end if;
  if not exists (
    select 1 from public.agent_projects
    where id = new.parent_id and user_id = new.user_id
  ) then
    raise exception 'no such project to put it under'
      using errcode = '23503';
  end if;
  while above is not null loop
    if above = new.id or steps > 100 then
      raise exception 'a project cannot be under itself'
        using errcode = '23514';
    end if;
    select parent_id into above from public.agent_projects where id = above;
    steps := steps + 1;
  end loop;
  return new;
end;
$$;

create trigger agent_projects_check before insert or update on public.agent_projects
  for each row execute function public.agent_projects_check();

alter table public.agent_projects enable row level security;

create policy "own projects" on public.agent_projects for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

grant select, insert, update, delete on public.agent_projects to authenticated;

alter table public.chats
  add column project_id uuid references public.agent_projects (id) on delete set null,
  add column project jsonb,
  add column workspace jsonb;

create index chats_by_project on public.chats (project_id);
