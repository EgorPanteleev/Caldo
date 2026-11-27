-- Keep the last turn state while a chat is suspended; it is still the
-- state the chat will be in when its process is thawed.
alter table public.chats add column paused boolean not null default false;

create function public.chats_clear_pause()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.state in ('ended', 'failed') then
    new.paused := false;
  end if;
  return new;
end;
$$;

create trigger chats_clear_pause before update on public.chats
  for each row execute function public.chats_clear_pause();
