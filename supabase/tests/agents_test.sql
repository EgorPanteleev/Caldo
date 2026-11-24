-- supabase test db
begin;
select plan(35);

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
  $$update public.chats set state = 'finished'$$,
  'a chat says its turn has finished');
select lives_ok(
  $$insert into public.chat_items (chat_id, id, seq, kind, body) values
    ('cccccccc-cccc-4ccc-8ccc-cccccccccccc', 'msg_1:0', 0, 'text',
     '{"text": "Done."}')$$,
  'the worker says what the agent said, as an item');
select lives_ok(
  $$insert into public.chat_in (chat_id, kind, data) values
    ('cccccccc-cccc-4ccc-8ccc-cccccccccccc', 'answer', 'allow ask:1')$$,
  'the app answers its question');
select lives_ok(
  $$insert into public.chat_in (chat_id, kind) values
    ('cccccccc-cccc-4ccc-8ccc-cccccccccccc', 'settings')$$,
  'the app tells the worker its settings changed');
select lives_ok(
  $$insert into public.chat_in (chat_id, kind) values
    ('cccccccc-cccc-4ccc-8ccc-cccccccccccc', 'clear')$$,
  'the app has the worker clear a chat''s context');
select throws_ok(
  $$update public.chats set mode = 'window'$$,
  '23514', null, 'a chat is in its chat or its terminal');
select lives_ok(
  $$insert into public.agent_rules (name, body) values
    ('Tests', 'Run the tests before saying it is done.')$$,
  'a rule is written');
select lives_ok(
  $$update public.chats set usage = '{"turns": 2, "cost": 0.4}'
    where id = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'$$,
  'the worker keeps what a chat has spent');
select is(
  (select (usage->>'turns')::int from public.chats
    where id = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'),
  2, 'and it is read back');
select lives_ok(
  $$insert into public.chat_later (chat_id, data, send_at, key) values
    ('cccccccc-cccc-4ccc-8ccc-cccccccccccc', 'Go on.', now() + interval '1 hour',
     'k1')$$,
  'a message is kept to be said later');
select lives_ok(
  $$insert into public.chat_subscriptions (chat_id, target, events, note) values
    ('cccccccc-cccc-4ccc-8ccc-cccccccccccc', 'EgorPanteleev/Caldo',
     '{opened,pushed}', 'Review it.')$$,
  'a chat is subscribed to pull requests');
select throws_ok(
  $$insert into public.chat_subscriptions (chat_id, events) values
    ('cccccccc-cccc-4ccc-8ccc-cccccccccccc', '{starred}')$$,
  '23514', null, 'only to what can be told');
select throws_ok(
  $$insert into public.chat_subscriptions (chat_id, target) values
    ('cccccccc-cccc-4ccc-8ccc-cccccccccccc', 'not a repo; drop')$$,
  '23514', null, 'in a repository named as GitHub names them');
reset role;

select lives_ok(
  $$insert into public.agent_accounts (id, worker_id, agent, main, state) values
    ('dddddddd-dddd-4ddd-8ddd-dddddddddddd',
     'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'claude', true, 'ready')$$,
  'a worker says which Claude it is signed into');
select throws_ok(
  $$insert into public.agent_accounts (worker_id, agent, main) values
    ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'claude', true)$$,
  '23505', null, 'one login of its own per agent');
select lives_ok(
  $$insert into public.chats (worker_id, agent, account) values
    ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'claude',
     'dddddddd-dddd-4ddd-8ddd-dddddddddddd')$$,
  'a chat runs under an account');
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
select is(
  (select count(*)::int from public.chat_later), 0,
  'nor sees what it will be told later');
select throws_ok(
  $$insert into public.chat_later (chat_id, data, send_at, key, user_id) values
    ('cccccccc-cccc-4ccc-8ccc-cccccccccccc', 'rm -rf ~', now(), 'k2',
     '22222222-2222-4222-8222-222222222222')$$,
  '42501', null, 'nor leaves it a message');
select is(
  (select count(*)::int from public.chat_subscriptions), 0,
  'nor sees what it is subscribed to');
select throws_ok(
  $$insert into public.chat_subscriptions (chat_id, target, user_id) values
    ('cccccccc-cccc-4ccc-8ccc-cccccccccccc', 'a/b',
     '22222222-2222-4222-8222-222222222222')$$,
  '42501', null, 'nor subscribes it to anything');
select is(
  (select count(*)::int from public.agent_accounts), 0,
  'nor sees its accounts');
select throws_ok(
  $$insert into public.agent_accounts (worker_id, agent, user_id) values
    ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'claude',
     '22222222-2222-4222-8222-222222222222')$$,
  '42501', null, 'nor signs its worker into an account of its own');
select is_empty(
  $$update public.agent_accounts set login_code = 'x' returning id$$,
  'nor hands its worker a code');
reset role;

select * from finish();
rollback;
