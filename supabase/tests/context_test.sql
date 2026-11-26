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

select pg_temp.act_as('11111111-1111-4111-8111-111111111111');
insert into public.workers (id, name) values
  ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'desk');
select lives_ok(
  $$insert into public.agent_context_asks (id, worker_id, kind, sources) values
    ('c0000000-0000-4000-8000-000000000001',
     'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'read', '["~/dev/src/Caldo"]')$$,
  'a worker is asked for a project''s files');
select lives_ok(
  $$update public.agent_context_asks
    set files = '[{"path": "~/.claude/CLAUDE.md", "kind": "user", "body": null}]',
        done_at = now()
    where id = 'c0000000-0000-4000-8000-000000000001'$$,
  'and answers on the same row');
select throws_ok(
  $$insert into public.agent_context_asks (worker_id, kind, path) values
    ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'rename', '~/x')$$,
  '23514', null, 'only to read, write or take away');

select pg_temp.act_as('22222222-2222-4222-8222-222222222222');
select is_empty(
  $$select id from public.agent_context_asks$$,
  'another sees none of it');
select throws_ok(
  $$insert into public.agent_context_asks (worker_id, kind, path, body) values
    ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'write', '~/CLAUDE.md', 'x')$$,
  '42501', null, 'nor asks another''s worker to write');

select * from finish();
rollback;
