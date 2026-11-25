-- supabase test db
begin;
select plan(9);

insert into auth.users (id, email) values
  ('11111111-1111-4111-8111-111111111111', 'one@caldo.invalid'),
  ('22222222-2222-4222-8222-222222222222', 'two@caldo.invalid');

create function pg_temp.act_as(who uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims',
           json_build_object('sub', who, 'role', 'authenticated')::text, true);
$$;

select pg_temp.act_as('11111111-1111-4111-8111-111111111111');
select lives_ok(
  $$select public.keep_push_token('phone-token', 'Pixel')$$,
  'a phone keeps its token');
select lives_ok(
  $$select public.keep_push_token('phone-token', 'Pixel 8')$$,
  'and keeps it again, as it is renewed');
select is(
  (select count(*)::int from public.push_tokens), 1,
  'one row a token');
select throws_ok(
  $$insert into public.push_tokens (token) values ('other')$$,
  '42501', null, 'only through keep_push_token');
select lives_ok(
  $$insert into public.chats (id, agent) values
    ('cccccccc-cccc-4ccc-8ccc-cccccccccccc', 'claude')$$,
  'a chat');
select is(
  (select muted from public.chats), false,
  'is not muted to begin with');

-- The phone signed into another account: the token goes with it.
select pg_temp.act_as('22222222-2222-4222-8222-222222222222');
select is(
  (select count(*)::int from public.push_tokens), 0,
  'another account sees no token of the first');
select lives_ok(
  $$select public.keep_push_token('phone-token', 'Pixel 8')$$,
  'the same phone signed into it keeps the token');
select pg_temp.act_as('11111111-1111-4111-8111-111111111111');
select is(
  (select count(*)::int from public.push_tokens), 0,
  'which the first account no longer has');
reset role;

select * from finish();
rollback;
