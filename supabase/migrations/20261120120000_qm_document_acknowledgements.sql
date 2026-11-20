alter table public.qm_document_reads
  add column if not exists acknowledged_version integer not null default 0,
  add column if not exists acknowledged_at timestamptz;

create or replace function public.acknowledge_qm_document(p_path text, p_version integer)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  me public.profiles%rowtype;
  current_version integer;
begin
  select * into me from public.profiles where id = auth.uid();
  if not found or me.active is distinct from true then
    raise exception 'Nicht berechtigt';
  end if;

  select version into current_version
  from public.qm_documents
  where path = p_path;

  if not found then
    raise exception 'Dokument nicht gefunden';
  end if;

  if p_version is distinct from current_version then
    raise exception 'Das Dokument wurde inzwischen aktualisiert. Bitte erneut öffnen.';
  end if;

  insert into public.qm_document_reads
    (user_id, path, seen_version, seen_at, acknowledged_version, acknowledged_at)
  values
    (auth.uid(), p_path, current_version, now(), current_version, now())
  on conflict (user_id, path) do update
  set acknowledged_version = excluded.acknowledged_version,
      acknowledged_at = excluded.acknowledged_at;
end;
$$;

create or replace function public.get_qm_document_ack_status()
returns table (
  path text,
  version integer,
  employee_id uuid,
  employee_name text,
  team text,
  acknowledged_version integer,
  acknowledged_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
declare
  me public.profiles%rowtype;
begin
  select * into me from public.profiles where id = auth.uid();
  if not found or me.active is distinct from true or me.role <> 'admin' then
    raise exception 'Nur aktive Administratoren';
  end if;

  return query
  select d.path, d.version, p.id,
         coalesce(nullif(p.name, ''), 'Unbenannt')::text,
         p.team,
         coalesce(r.acknowledged_version, 0),
         r.acknowledged_at
  from public.qm_documents d
  cross join public.profiles p
  left join public.qm_document_reads r
    on r.path = d.path and r.user_id = p.id
  where p.active is true
    and p.role <> 'admin'
    and (
      lower(d.path) like '%.pdf'
      or lower(d.path) like '%.doc'
      or lower(d.path) like '%.docx'
      or lower(d.path) like '%.xls'
      or lower(d.path) like '%.xlsx'
      or lower(d.path) like '%.odt'
      or lower(d.path) like '%.ods'
      or lower(d.path) like '%.ppt'
      or lower(d.path) like '%.pptx'
      or lower(d.path) like '%.rtf'
      or lower(d.path) like '%.txt'
    )
  order by d.path, p.name;
end;
$$;

revoke all on function public.acknowledge_qm_document(text, integer) from public, anon;
grant execute on function public.acknowledge_qm_document(text, integer) to authenticated;
revoke all on function public.get_qm_document_ack_status() from public, anon;
grant execute on function public.get_qm_document_ack_status() to authenticated;

create or replace function public.get_qm_document_versions()
returns table(path text, version integer)
language plpgsql
security definer
set search_path = public
as $$
declare
  me public.profiles%rowtype;
begin
  select * into me from public.profiles where id = auth.uid();
  if not found or me.active is distinct from true then
    raise exception 'Nicht berechtigt';
  end if;
  return query
  select d.path, d.version
  from public.qm_documents d
  where lower(d.path) ~ '\\.(pdf|doc|docx|xls|xlsx|odt|ods|ppt|pptx|rtf|txt)$'
  order by d.path;
end;
$$;
revoke all on function public.get_qm_document_versions() from public, anon;
grant execute on function public.get_qm_document_versions() to authenticated;

create or replace function public.sync_qm_documents(p_documents jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  me public.profiles%rowtype;
  item jsonb;
  v_path text;
  v_sha text;
  old_sha text;
begin
  select * into me from public.profiles where id = auth.uid();
  if not found or me.active is distinct from true or me.role <> 'admin' then
    raise exception 'Nur aktive Administratoren';
  end if;
  if jsonb_typeof(coalesce(p_documents, '[]'::jsonb)) <> 'array' then
    raise exception 'Ungültige Dokumentliste';
  end if;
  for item in select value from jsonb_array_elements(coalesce(p_documents, '[]'::jsonb))
  loop
    v_path := nullif(trim(item->>'path'), '');
    v_sha := coalesce(item->>'sha', '');
    if v_path is null or lower(v_path) !~ '\\.(pdf|doc|docx|xls|xlsx|odt|ods|ppt|pptx|rtf|txt)$' then
      continue;
    end if;
    select d.sha into old_sha from public.qm_documents d where d.path = v_path for update;
    if not found then
      insert into public.qm_documents(path, sha, version, discovered_at, updated_at)
      values(v_path, v_sha, 1, now(), now());
    elsif old_sha is distinct from v_sha then
      update public.qm_documents
      set sha = v_sha, version = version + 1, updated_at = now()
      where path = v_path;
    end if;
  end loop;
end;
$$;
