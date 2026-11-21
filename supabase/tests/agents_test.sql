-- supabase test db
begin;
select plan(16);

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
  $$insert into public.workers (id, name) values
    ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'desk')$$,
  'a worker says it is there');
select lives_ok(
  $$insert into public.chats (id, worker_id, agent) values
    ('cccccccc-cccc-4ccc-8ccc-cccccccccccc',
     'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'claude')$$,
  'the app asks it for a chat');
select lives_ok(
  $$insert into public.chat_out (chat_id, seq, data) values
    ('cccccccc-cccc-4ccc-8ccc-cccccccccccc', 0, 'hi')$$,
  'the worker writes what the terminal shows');
select lives_ok(
  $$insert into public.chat_in (chat_id, kind, data) values
    ('cccccccc-cccc-4ccc-8ccc-cccccccccccc', 'keys', 'ls')$$,
  'the app types into it');
select throws_ok(
  $$update public.chats set state = 'gone'$$,
  '23514', null, 'a chat is only in a known state');
select lives_ok(
  $$insert into public.chat_items (chat_id, id, seq, kind, body) values
    ('cccccccc-cccc-4ccc-8ccc-cccccccccccc', 'msg_1:0', 0, 'text',
     '{"text": "Done."}')$$,
  'the worker says what the agent said, as an item');
select lives_ok(
  $$insert into public.chat_in (chat_id, kind, data) values
    ('cccccccc-cccc-4ccc-8ccc-cccccccccccc', 'answer', 'allow ask:1')$$,
  'the app answers its question');
select throws_ok(
  $$update public.chats set mode = 'window'$$,
  '23514', null, 'a chat is in its chat or its terminal');
select lives_ok(
  $$insert into public.agent_rules (name, body) values
    ('Tests', 'Run the tests before saying it is done.')$$,
  'a rule is written');
reset role;

select pg_temp.act_as('22222222-2222-4222-8222-222222222222');
select is(
  (select count(*)::int from public.chats) + (select count(*)::int from public.chat_out)
    + (select count(*)::int from public.workers),
  0, 'another account sees none of it');
select throws_ok(
  $$insert into public.chat_in (chat_id, kind, data) values
    ('cccccccc-cccc-4ccc-8ccc-cccccccccccc', 'keys', 'rm -rf ~')$$,
  '42501', null, 'and cannot type into it');
select throws_ok(
  $$insert into public.chat_out (chat_id, seq, data, user_id) values
    ('cccccccc-cccc-4ccc-8ccc-cccccccccccc', 1, 'x',
     '22222222-2222-4222-8222-222222222222')$$,
  '42501', null, 'nor write into its terminal');
select is(
  (select count(*)::int from public.chat_items), 0,
  'nor sees what was said in it');
select is(
  (select count(*)::int from public.agent_rules), 0,
  'nor reads its rules');
select throws_ok(
  $$insert into public.agent_rules (name, user_id) values
    ('x', '11111111-1111-4111-8111-111111111111')$$,
  '42501', null, 'nor writes one for it');
select throws_ok(
  $$insert into public.chat_items (chat_id, id, seq, kind, user_id) values
    ('cccccccc-cccc-4ccc-8ccc-cccccccccccc', 'x', 1, 'text',
     '22222222-2222-4222-8222-222222222222')$$,
  '42501', null, 'nor puts words in its mouth');
reset role;

select * from finish();
rollback;
