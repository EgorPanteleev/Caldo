-- A worker can discover that a chat's process stopped while it was away.
-- Keep the chat's activity time when recording that recovery.
create or replace function public.chats_touch()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  -- An explicit null from recover_chat keeps the old, non-null timestamp.
  if new.updated_at is null then
    new.updated_at := old.updated_at;
  elsif (new.state, new.note, new.title) is distinct from
        (old.state, old.note, old.title) then
    new.updated_at := now();
  end if;
  return new;
end;
$$;

create function public.recover_chat(
  chat uuid, worker uuid, before_state text, next_state text, reason text
)
returns boolean
language plpgsql
set search_path = ''
as $$
begin
  update public.chats
    set state = next_state, note = reason, updated_at = null
    where id = chat and worker_id = worker and state = before_state;
  return found;
end;
$$;

revoke execute on function public.recover_chat(uuid, uuid, text, text, text)
  from public, anon;
grant execute on function public.recover_chat(uuid, uuid, text, text, text)
  to authenticated;
