-- Subchats (asked for 2026-11-26: "each subchat is the same as chat, but
-- must have parent chat context and his own"): a chat begun from another
-- to take on a part of its work. Its worker begins it from the parent's
-- session where the agent can carry that on (Claude's --fork-session,
-- Codex's thread/fork), else tells it the words said there; it works in
-- the parent's folder. Deleted with its parent, as a subtask is.

alter table public.chats
  add column parent_id uuid references public.chats (id) on delete cascade;

create index chats_by_parent on public.chats (parent_id);

-- A parent is one of the user's own chats, set when the subchat is made:
-- one of someone else's would be deleted from under it by them, and one
-- changed later could make a loop no list could draw.
create function public.chats_parent_check()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' then
    if new.parent_id is distinct from old.parent_id then
      raise exception 'a chat''s parent is set when it is made'
        using errcode = '23514';
    end if;
    return new;
  end if;
  if new.parent_id is not null and not exists (
    select 1 from public.chats
    where id = new.parent_id and user_id = new.user_id
  ) then
    raise exception 'no such chat to begin it from'
      using errcode = '23503';
  end if;
  return new;
end;
$$;

create trigger chats_parent_check before insert or update of parent_id
  on public.chats
  for each row execute function public.chats_parent_check();
