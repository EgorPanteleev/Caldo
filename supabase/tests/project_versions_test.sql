-- supabase test db
begin;
select plan(10);

insert into auth.users (id, email) values
  ('11111111-1111-4111-8111-111111111111', 'one@caldo.invalid'),
  ('22222222-2222-4222-8222-222222222222', 'two@caldo.invalid');

create function pg_temp.act_as(who uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims',
           json_build_object('sub', who, 'role', 'authenticated')::text, true);
$$;

select pg_temp.act_as('11111111-1111-4111-8111-111111111111');
insert into public.agent_projects (id, name, context) values
  ('a0000000-0000-4000-8000-000000000001', 'Caldo', 'One.');
select is(
  (select version from public.agent_projects), 1, 'a project starts at 1');

update public.agent_projects
  set context = 'Two.', changed_by = 'computer:desk', version = 40;
select is(
  (select version from public.agent_projects), 2,
  'a change counts one up, whatever was written');
update public.agent_projects set name = 'Caldo app', changed_by = 'chat:x';
select results_eq(
  $$select version, changed_by from public.agent_projects$$,
  $$values (2, 'computer:desk')$$,
  'a rename is no new version');

-- A worker's save holds only on the version it saw.
update public.agent_projects set context = 'Stale.' where version = 1;
select is(
  (select context from public.agent_projects), 'Two.',
  'a save on an old version changes nothing');

select results_eq(
  $$select version, context, changed_by from public.agent_project_versions
    order by id$$,
  $$values (1, 'One.', 'app'), (2, 'Two.', 'computer:desk')$$,
  'each version is kept, with who made it');

do $$
begin
  for i in 3..30 loop
    update public.agent_projects set context = 'v' || i;
  end loop;
end;
$$;
select is(
  (select count(*)::int from public.agent_project_versions), 20,
  'only the last 20 are kept');
select is(
  (select min(version) from public.agent_project_versions), 11,
  'the oldest go');

select lives_ok(
  $$insert into public.agent_project_versions
    (project_id, version, context, changed_by, unmerged) values
    ('a0000000-0000-4000-8000-000000000001', 30, 'Mine.', 'computer:desk',
     true)$$,
  'an edit that could not be merged is kept');
select throws_ok(
  $$insert into public.agent_project_versions
    (project_id, version, context) values
    ('a0000000-0000-4000-8000-000000000001', 31, 'Forged.')$$,
  '42501', null, 'but no other version is written by hand');

select pg_temp.act_as('22222222-2222-4222-8222-222222222222');
select is_empty(
  $$select id from public.agent_project_versions$$,
  'another sees none of them');

select * from finish();
rollback;
