-- Latest host readings from a worker's heartbeat, covered by its existing RLS.
alter table public.workers add column resources jsonb;
