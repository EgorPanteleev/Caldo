-- Projects sit side by side, none under another (asked for 2026-11-25):
-- what a piece of the work needs to be told of the whole is now its task's
-- to say, a subtask being told its parents'. A subproject there was comes
-- up to the top as it is; chats keep the copy they began with.

drop trigger agent_projects_check on public.agent_projects;
drop function public.agent_projects_check();
drop index public.agent_projects_by_parent;
alter table public.agent_projects drop column parent_id;

create function public.agent_projects_stamp()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger agent_projects_stamp before insert or update on public.agent_projects
  for each row execute function public.agent_projects_stamp();
