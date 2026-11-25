-- Notifications from the Agents tab on the phone, as Firebase pushes
-- (asked for 2026-11-25): a chat waiting on the user, or an agent's own
-- word through the MCP tool `notify`. The worker or the MCP server asks
-- the Edge Function `push` as the user; it reads these rows under the
-- user's own rights and sends to every phone of theirs.

-- A muted chat's waiting is not told; what its agent says with `notify`
-- still is, as a mention gets through a muted chat elsewhere. Not news for
-- the list: `chats_touch` stamps only a change of state, note or title.
alter table public.chats add column if not exists muted boolean not null default false;

-- Each phone's Firebase token, kept by the app while signed in. A token is
-- the phone's, not the account's: signed into another account, it moves
-- (`keep_push_token`), or one phone would be told another's chats.
create table public.push_tokens (
  token text primary key check (length(token) between 1 and 4096),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  device text,
  updated_at timestamptz not null default now()
);

create index push_tokens_by_user on public.push_tokens (user_id);

alter table public.push_tokens enable row level security;

create policy "own push tokens" on public.push_tokens for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

-- Read (the push function, as the user) and let go of (signing out); kept
-- only through `keep_push_token`. Supabase grants every new table whole.
revoke all on public.push_tokens from anon, authenticated;
grant select, delete on public.push_tokens to authenticated;

-- The token taken by whoever is signed in, from anyone it was with: a row
-- of another account's can't be reached through the policy above.
create function public.keep_push_token(token text, device text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
begin
  if me is null then
    raise exception 'not signed in' using errcode = '28000';
  end if;
  insert into public.push_tokens as t (token, user_id, device, updated_at)
  values (keep_push_token.token, me, keep_push_token.device, now())
  on conflict on constraint push_tokens_pkey do update
    set user_id = excluded.user_id, device = excluded.device, updated_at = now();
end;
$$;

revoke execute on function public.keep_push_token(text, text) from public, anon;
grant execute on function public.keep_push_token(text, text) to authenticated;
