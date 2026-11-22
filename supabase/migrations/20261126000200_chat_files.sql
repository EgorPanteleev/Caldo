-- Photos and files sent with a chat's message. The app puts each in this
-- bucket, under the account's folder and then the chat's, before the
-- message goes; the message names them (`files`, [{key, name, mime,
-- size}], each key the object's name after the account's folder), and the
-- chat's worker takes each down onto its computer, where the agent reads
-- it, and deletes it here. Apart from `attachments`, whose files are
-- tasks' and are kept in step with every device.
--
-- 50MB at most, the free tier's own ceiling.
insert into storage.buckets (id, name, public, file_size_limit)
values ('chat-files', 'chat-files', false, 52428800)
on conflict (id) do nothing;

create policy "own chat files" on storage.objects
  for all to authenticated
  using (
    bucket_id = 'chat-files'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  )
  with check (
    bucket_id = 'chat-files'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

alter table public.chat_in add column files jsonb;
