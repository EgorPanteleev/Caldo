-- supabase test db
begin;
select plan(8);

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
  $$insert into public.agent_projects (id, name, colour, context, sources) values
    ('a0000000-0000-4000-8000-000000000001', 'Caldo', 'teal',
     'A calendar app.', '["~/dev/src/Caldo"]')$$,
  'a project is made');
select hasnt_column(
  'public', 'agent_projects', 'parent_id',
  'and none sits under another');

insert into public.workers (id, name) values
  ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'desk');
select lives_ok(
  $$insert into public.chats (id, worker_id, agent, project_id, project, workspace)
    values ('cccccccc-cccc-4ccc-8ccc-cccccccccccc',
     'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'claude',
     'a0000000-0000-4000-8000-000000000001',
     '{"name": "Caldo", "sources": ["~/dev/src/Caldo"]}', '{}')$$,
  'a chat is begun in a project, with a workspace of its own');

select pg_temp.act_as('22222222-2222-4222-8222-222222222222');
select is_empty(
  $$select id from public.agent_projects$$,
  'another sees none of them');
select lives_ok(
  $$delete from public.agent_projects$$,
  'nor deletes them (nothing is theirs to)');

select pg_temp.act_as('11111111-1111-4111-8111-111111111111');
select is(
  (select count(*) from public.agent_projects)::int, 1,
  'it is still there');
select lives_ok(
  $$delete from public.agent_projects
    where id = 'a0000000-0000-4000-8000-000000000001'$$,
  'a project is deleted');
select is(
  (select (project_id is null and project->>'name' = 'Caldo')
   from public.chats where id = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'),
  true,
  'its chat keeps the copy it began with');

select * from finish();
rollback;
