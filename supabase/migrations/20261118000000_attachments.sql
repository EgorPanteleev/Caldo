-- The files attached to tasks. A task's row says which files it has; the
-- files themselves are kept here, in one private bucket, each account's in
-- a folder named by its id, each file under the folder its copy sits in on
-- the device — a uuid made when it was attached, the same wherever the row
-- goes.
--
-- 50MB at most, the free tier's own ceiling: a bigger file stays on the
-- device it was attached on.
insert into storage.buckets (id, name, public, file_size_limit)
values ('attachments', 'attachments', false, 52428800)
on conflict (id) do nothing;

-- An account reaches its own folder and nothing else. Writing over a file
-- (an upload sent again after a lost answer) needs the update as well as
-- the insert, and both need the select.
create policy "own attachments" on storage.objects
  for all to authenticated
  using (
    bucket_id = 'attachments'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  )
  with check (
    bucket_id = 'attachments'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );
