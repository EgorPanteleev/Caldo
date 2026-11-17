-- supabase test db
begin;
select plan(5);

insert into auth.users (id, email) values
  ('11111111-1111-4111-8111-111111111111', 'one@caldo.invalid'),
  ('22222222-2222-4222-8222-222222222222', 'two@caldo.invalid');

create function pg_temp.act_as(who uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims',
           json_build_object('sub', who, 'role', 'authenticated')::text, true);
$$;

select is(
  (select public from storage.buckets where id = 'attachments'), false,
  'the bucket is private');

select pg_temp.act_as('11111111-1111-4111-8111-111111111111');
select lives_ok(
  $$insert into storage.objects (bucket_id, name) values
    ('attachments', '11111111-1111-4111-8111-111111111111/a')$$,
  'an account puts a file in its own folder');
select throws_ok(
  $$insert into storage.objects (bucket_id, name) values
    ('attachments', '22222222-2222-4222-8222-222222222222/b')$$,
  '42501', null, 'and not in another''s');
select is(
  (select count(*)::int from storage.objects where bucket_id = 'attachments'),
  1, 'and sees its own');
reset role;

select pg_temp.act_as('22222222-2222-4222-8222-222222222222');
select is(
  (select count(*)::int from storage.objects where bucket_id = 'attachments'),
  0, 'another account sees none of them');
reset role;

select * from finish();
rollback;
