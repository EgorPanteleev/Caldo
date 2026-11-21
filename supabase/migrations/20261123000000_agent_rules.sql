-- Rules for agents: standing instructions written once in the app ("answer
-- in Russian", "never push", "run the tests before saying done") and
-- chosen for each chat as it is started.
--
-- A chat keeps the rules it was started with, words and all (`chats.rules`,
-- [{name, body}]), not the rules' ids: the worker reads them from the chat
-- alone, a rule changed later does not change what a chat was told, and a
-- rule deleted takes nothing from a chat that had it.

create table public.agent_rules (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  name text not null default '',
  body text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index agent_rules_by_user on public.agent_rules (user_id, name);

create function public.agent_rules_touch()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger agent_rules_touch before update on public.agent_rules
  for each row execute function public.agent_rules_touch();

alter table public.agent_rules enable row level security;

create policy "own rules" on public.agent_rules for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

grant select, insert, update, delete on public.agent_rules to authenticated;

alter table public.chats add column rules jsonb not null default '[]';
