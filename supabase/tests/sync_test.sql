-- supabase test db
begin;
select plan(16);

insert into auth.users (id, email) values
  ('11111111-1111-4111-8111-111111111111', 'a@caldo.test'),
  ('22222222-2222-4222-8222-222222222222', 'b@caldo.test');

create function pg_temp.act_as(who uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims',
           json_build_object('sub', who, 'role', 'authenticated')::text, true);
$$;

create function pg_temp.row_of(who uuid, id uuid) returns public.sync_rows
language sql as $$
  select * from public.sync_rows where user_id = who and uuid = id;
$$;

-- A pushes two rows and pulls them back.
select pg_temp.act_as('11111111-1111-4111-8111-111111111111');
select is(
  public.sync_push('[
    {"tbl": "lists", "uuid": "00000000-0000-4000-8000-000000000001",
     "data": {"name": "Personal"}, "updated_at": 10},
    {"tbl": "tasks", "uuid": "aaaaaaaa-0000-4000-8000-000000000001",
     "data": {"title": "Ship", "list_uuid": "00000000-0000-4000-8000-000000000001"},
     "updated_at": 10}
  ]'),
  2, 'both rows are written');
select is((select count(*)::int from public.sync_pull(0)), 2, 'and both come back');

-- B shares the default group's uuid but not A's rows.
select pg_temp.act_as('22222222-2222-4222-8222-222222222222');
select is((select count(*)::int from public.sync_pull(0)), 0, 'B pulls none of A''s rows');
select is((select count(*)::int from public.sync_rows), 0, 'nor can B read them');
select is(
  public.sync_push('[{"tbl": "lists", "uuid": "00000000-0000-4000-8000-000000000001",
    "data": {"name": "Mine"}, "updated_at": 5}]'),
  1, 'B''s default group is a row of B''s own');

-- An older edit loses, and the winner comes round again.
select pg_temp.act_as('11111111-1111-4111-8111-111111111111');
create temp table seen as select max(seq) as top from public.sync_pull(0);
select is(
  public.sync_push('[{"tbl": "tasks", "uuid": "aaaaaaaa-0000-4000-8000-000000000001",
    "data": {"title": "Stale"}, "updated_at": 9}]'),
  0, 'an edit older than the row loses');
select results_eq(
  $$ select data ->> 'title' from public.sync_pull((select top from seen)) $$,
  $$ values ('Ship') $$,
  'the row it lost to is handed back on the next pull');

-- A newer edit is laid over the row, keeping what it does not mention.
select public.sync_push('[{"tbl": "tasks", "uuid": "aaaaaaaa-0000-4000-8000-000000000001",
  "data": {"title": "Ship it", "later_column": 1}, "updated_at": 20}]');
select public.sync_push('[{"tbl": "tasks", "uuid": "aaaaaaaa-0000-4000-8000-000000000001",
  "data": {"title": "Shipped"}, "updated_at": 30}]');
reset role;
select is(
  (pg_temp.row_of('11111111-1111-4111-8111-111111111111',
    'aaaaaaaa-0000-4000-8000-000000000001')).data,
  '{"title": "Shipped", "list_uuid": "00000000-0000-4000-8000-000000000001", "later_column": 1}'::jsonb,
  'a column an older device does not know survives its edit');

-- Deleted, and edited again later on another device.
select pg_temp.act_as('11111111-1111-4111-8111-111111111111');
select public.sync_push('[{"tbl": "tasks", "uuid": "aaaaaaaa-0000-4000-8000-000000000001",
  "deleted": true, "updated_at": 40}]');
reset role;
select ok(
  (pg_temp.row_of('11111111-1111-4111-8111-111111111111',
    'aaaaaaaa-0000-4000-8000-000000000001')).deleted
  and (pg_temp.row_of('11111111-1111-4111-8111-111111111111',
    'aaaaaaaa-0000-4000-8000-000000000001')).data is null,
  'a deletion keeps nothing but that the row is gone');
select pg_temp.act_as('11111111-1111-4111-8111-111111111111');
select is(
  public.sync_push('[{"tbl": "tasks", "uuid": "aaaaaaaa-0000-4000-8000-000000000001",
    "data": {"title": "Back"}, "updated_at": 35}]'),
  0, 'an edit made before the deletion does not bring it back');
select public.sync_push('[{"tbl": "tasks", "uuid": "aaaaaaaa-0000-4000-8000-000000000001",
  "data": {"title": "Back"}, "updated_at": 50}]');
reset role;
select is(
  (pg_temp.row_of('11111111-1111-4111-8111-111111111111',
    'aaaaaaaa-0000-4000-8000-000000000001')).data,
  '{"title": "Back"}'::jsonb,
  'one made after it does');

-- A pull pages.
select pg_temp.act_as('11111111-1111-4111-8111-111111111111');
select is((select count(*)::int from public.sync_pull(0, 1)), 1, 'a page is as long as asked');

-- Nobody signed in gets nothing.
select set_config('request.jwt.claims', '{"role": "authenticated"}', true);
select throws_ok(
  $$ select public.sync_push('[]') $$, '28000', 'not signed in',
  'a push with no user is refused');
reset role;
set local role anon;
select throws_ok(
  $$ select public.sync_pull(0) $$, '42501', null,
  'the anonymous key cannot pull');
select throws_ok(
  $$ insert into public.sync_rows (user_id, tbl, uuid, updated_at)
     values ('11111111-1111-4111-8111-111111111111', 'tasks', gen_random_uuid(), 1) $$,
  '42501', null,
  'nor write a row directly');
reset role;

-- Deleting the account takes its rows with it.
select pg_temp.act_as('11111111-1111-4111-8111-111111111111');
select public.delete_account();
reset role;
select is(
  (select count(*)::int from public.sync_rows
   where user_id = '11111111-1111-4111-8111-111111111111'),
  0, 'a deleted account leaves no rows');

select * from finish();
rollback;
