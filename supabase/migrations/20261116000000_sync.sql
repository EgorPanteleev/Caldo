-- What Caldo syncs: every row of every device's database, one account's to
-- each user, and nothing the server has to understand.
--
-- A row is kept as the JSON of the device's own row (its local id left out,
-- and ids pointing at other rows turned into their uuids), not as columns of
-- its own. The server never reads a task; it only keeps the latest of each
-- row and hands on what changed. So a column added to the app later needs no
-- migration here, and the rows could be sealed before they leave the phone
-- without anything here changing.

create sequence public.sync_seq;

create table public.sync_rows (
  user_id uuid not null references auth.users (id) on delete cascade,
  tbl text not null check (tbl ~ '^[a-z_]+$'),
  uuid uuid not null,
  -- Null once deleted: a tombstone carries nothing but that it is gone.
  data jsonb,
  -- When the device that wrote it last changed it, in epoch millis. Only
  -- decides which of two edits wins; what has changed is read off seq.
  updated_at bigint not null,
  deleted boolean not null default false,
  -- Taken afresh on every write. A device asks for everything past the
  -- last seq it has seen, so a phone whose clock is wrong cannot miss a
  -- change, as it could asking by time.
  seq bigint not null default nextval('public.sync_seq'),
  primary key (user_id, tbl, uuid)
);

create index sync_rows_pull on public.sync_rows (user_id, seq);

-- Written only through sync_push. Reading is allowed so that realtime can
-- tell a signed-in device its own rows have changed.
alter table public.sync_rows enable row level security;
revoke all on public.sync_rows from anon, authenticated;
grant select on public.sync_rows to authenticated;
create policy "own rows" on public.sync_rows
  for select to authenticated
  using (user_id = (select auth.uid()));

alter publication supabase_realtime add table public.sync_rows;

-- Takes a device's changed rows: [{tbl, uuid, data, updated_at, deleted}].
--
-- The later edit of a row wins, by its updated_at. Its JSON is laid over
-- what is kept rather than put in its place, so a device on an older
-- version, which does not know a column a newer one wrote, does not wipe it.
-- An edit that loses is not dropped silently: the row it lost to is given a
-- new seq, so the device that sent it is handed the winner on its next pull.
--
-- One account's pushes are made one at a time (the lock). A seq is taken
-- when a write starts, not when it is committed, so two at once could commit
-- out of order, and a device that had already pulled past the later one
-- would never see the earlier. Pulls are per account, so the lock costs
-- nothing between accounts.
create function public.sync_push(rows jsonb)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  r jsonb;
  gone boolean;
  written integer := 0;
begin
  if me is null then
    raise exception 'not signed in' using errcode = '28000';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(me::text, 0));
  for r in select * from jsonb_array_elements(rows) loop
    gone := coalesce((r ->> 'deleted')::boolean, false);
    insert into public.sync_rows as s (user_id, tbl, uuid, data, updated_at, deleted)
    values (
      me,
      r ->> 'tbl',
      (r ->> 'uuid')::uuid,
      case when gone then null else r -> 'data' end,
      (r ->> 'updated_at')::bigint,
      gone
    )
    on conflict (user_id, tbl, uuid) do update set
      data = case
        when excluded.deleted then null
        else coalesce(s.data, '{}'::jsonb) || excluded.data
      end,
      updated_at = excluded.updated_at,
      deleted = excluded.deleted,
      seq = nextval('public.sync_seq')
    where excluded.updated_at >= s.updated_at;
    if found then
      written := written + 1;
    else
      update public.sync_rows set seq = nextval('public.sync_seq')
      where user_id = me and tbl = r ->> 'tbl' and uuid = (r ->> 'uuid')::uuid;
    end if;
  end loop;
  return written;
end
$$;

-- Everything of the caller's written after seq [since], oldest first, a page
-- at a time: a device asks again from the last seq it was given until a page
-- comes back short.
create function public.sync_pull(since bigint, page integer default 500)
returns table (
  tbl text,
  uuid uuid,
  data jsonb,
  updated_at bigint,
  deleted boolean,
  seq bigint
)
language sql
stable
security definer
set search_path = ''
as $$
  select s.tbl, s.uuid, s.data, s.updated_at, s.deleted, s.seq
  from public.sync_rows s
  where s.user_id = auth.uid() and s.seq > since
  order by s.seq
  limit least(greatest(page, 1), 1000);
$$;

-- Deletes the caller's account and, with it, every row it ever synced.
create function public.delete_account()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'not signed in' using errcode = '28000';
  end if;
  delete from auth.users where id = auth.uid();
end
$$;

revoke execute on function public.sync_push(jsonb) from public, anon;
revoke execute on function public.sync_pull(bigint, integer) from public, anon;
revoke execute on function public.delete_account() from public, anon;
grant execute on function public.sync_push(jsonb) to authenticated;
grant execute on function public.sync_pull(bigint, integer) to authenticated;
grant execute on function public.delete_account() to authenticated;
