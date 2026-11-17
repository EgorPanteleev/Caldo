-- supabase test db
begin;
select plan(12);

insert into auth.users (id, email) values
  ('11111111-1111-4111-8111-111111111111', 'admin@caldo.invalid'),
  ('22222222-2222-4222-8222-222222222222', 'someone@caldo.invalid');
insert into public.admins values ('11111111-1111-4111-8111-111111111111');

create function pg_temp.act_as(who uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims',
           json_build_object('sub', who, 'role', 'authenticated')::text, true);
$$;

create function pg_temp.hook(invite text) returns jsonb language sql as $$
  select public.before_user_created(jsonb_build_object(
    'user', jsonb_build_object('user_metadata',
      case when invite is null then '{}'::jsonb
           else jsonb_build_object('invite', invite) end)));
$$;

-- Only an admin makes invites.
select pg_temp.act_as('22222222-2222-4222-8222-222222222222');
select is(public.is_admin(), false, 'someone else is not an admin');
select throws_ok('select public.make_invite()', '42501', null,
  'and cannot make an invite');
reset role;

select pg_temp.act_as('11111111-1111-4111-8111-111111111111');
select is(public.is_admin(), true, 'the admin is one');
create temp table made as select public.make_invite() as code;
select matches((select code from made), '^[A-HJ-NP-Z2-9]{12}$',
  'an invite is twelve unmistakable characters');
reset role;

-- The hook lets through only an unused invite, in any case and spacing.
select is(pg_temp.hook(null) -> 'error' ->> 'http_code', '403',
  'no invite is turned down');
select is(pg_temp.hook('NOTACODE') -> 'error' ->> 'http_code', '403',
  'an unknown one is turned down');
select is(pg_temp.hook(' ' || lower((select code from made)) || ' '), '{}',
  'an unused one passes, typed loosely');

-- Making the account spends it.
insert into auth.users (id, email, raw_user_meta_data) values
  ('33333333-3333-4333-8333-333333333333', 'new@caldo.invalid',
   jsonb_build_object('invite', (select code from made)));
select is(
  (select used_by from public.invites where code = (select code from made)),
  '33333333-3333-4333-8333-333333333333'::uuid,
  'the invite is spent on the account made with it');
select is(pg_temp.hook((select code from made)) -> 'error' ->> 'http_code',
  '403', 'and turned down after');
select throws_ok(
  $$insert into auth.users (id, email, raw_user_meta_data) values
    ('44444444-4444-4444-8444-444444444444', 'late@caldo.invalid',
     jsonb_build_object('invite', (select code from made)))$$,
  '28000', null,
  'a second account on it, past the hook in a race, is rolled back');

-- Neither table is open to a client.
select pg_temp.act_as('22222222-2222-4222-8222-222222222222');
select throws_ok('select * from public.invites', '42501', null,
  'invites cannot be read');
select throws_ok(
  $$insert into public.admins values ('22222222-2222-4222-8222-222222222222')$$,
  '42501', null, 'nor can anyone make themselves an admin');
reset role;

select * from finish();
rollback;
