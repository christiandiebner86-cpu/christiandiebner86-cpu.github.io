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
