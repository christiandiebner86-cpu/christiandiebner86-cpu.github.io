-- Monthly team draft workflow: admin prepares and releases a team schedule,
-- employees/team leaders confirm or request changes, admin finalizes after all confirmations.
create table if not exists public.dutyplan_team_drafts (
  team text not null,
  month text not null,
  entries jsonb not null default '{}'::jsonb check (jsonb_typeof(entries) = 'object'),
  responses jsonb not null default '{}'::jsonb check (jsonb_typeof(responses) = 'object'),
  status text not null default 'draft' check (status in ('draft','released','finalized')),
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  released_by uuid references public.profiles(id),
  released_at timestamptz,
  finalized_by uuid references public.profiles(id),
  finalized_at timestamptz,
  updated_at timestamptz not null default now(),
  primary key (team, month),
  check (month ~ '^\d{4}-(0[1-9]|1[0-2])$')
);
alter table public.dutyplan_team_drafts enable row level security;
revoke all on public.dutyplan_team_drafts from public, anon, authenticated;

create or replace function public.get_dutyplan_team_draft(p_team text, p_month text)
returns jsonb language plpgsql security definer set search_path = public
as $function$
declare v_profile public.profiles%rowtype; v_result jsonb;
begin
  select * into v_profile from public.profiles where id=auth.uid() and active=true;
  if not found then raise exception 'Nicht angemeldet oder inaktives Profil'; end if;
  if v_profile.role not in ('admin','admin_teamleitung') and coalesce(v_profile.team,'') <> coalesce(p_team,'') then
    raise exception 'Kein Zugriff auf dieses Team';
  end if;
  select to_jsonb(d) into v_result from public.dutyplan_team_drafts d where d.team=p_team and d.month=p_month;
  return coalesce(v_result, jsonb_build_object('team',p_team,'month',p_month,'entries','{}'::jsonb,'responses','{}'::jsonb,'status','empty'));
end $function$;

create or replace function public.save_dutyplan_team_draft(p_team text, p_month text, p_entries jsonb, p_release boolean default false)
returns jsonb language plpgsql security definer set search_path = public
as $function$
declare v_profile public.profiles%rowtype; v_existing public.dutyplan_team_drafts%rowtype; v_result jsonb;
begin
  select * into v_profile from public.profiles where id=auth.uid() and active=true;
  if not found or v_profile.role not in ('admin','admin_teamleitung') then raise exception 'Nur die Administration darf den Team-Entwurf bearbeiten'; end if;
  if p_team is null or btrim(p_team)='' or p_month !~ '^\d{4}-(0[1-9]|1[0-2])$' or jsonb_typeof(p_entries)<>'object' then
    raise exception 'Ungültiger Teamplan';
  end if;
  select * into v_existing from public.dutyplan_team_drafts where team=p_team and month=p_month for update;
  if found and v_existing.status='finalized' then raise exception 'Der endgültige Dienstplan ist gesperrt'; end if;
  insert into public.dutyplan_team_drafts(team,month,entries,responses,status,created_by,released_by,released_at,finalized_by,finalized_at,updated_at)
  values (p_team,p_month,p_entries,'{}'::jsonb,case when p_release then 'released' else 'draft' end,
          coalesce(v_existing.created_by,auth.uid()),case when p_release then auth.uid() else null end,
          case when p_release then now() else null end,null,null,now())
  on conflict(team,month) do update set entries=excluded.entries,responses='{}'::jsonb,
    status=excluded.status,released_by=excluded.released_by,released_at=excluded.released_at,
    finalized_by=null,finalized_at=null,updated_at=now();
  select to_jsonb(d) into v_result from public.dutyplan_team_drafts d where d.team=p_team and d.month=p_month;
  return v_result;
end $function$;

create or replace function public.respond_dutyplan_team_draft(p_team text, p_month text, p_status text, p_note text default '')
returns jsonb language plpgsql security definer set search_path = public
as $function$
declare v_profile public.profiles%rowtype; v_draft public.dutyplan_team_drafts%rowtype; v_responses jsonb; v_result jsonb;
begin
  select * into v_profile from public.profiles where id=auth.uid() and active=true;
  if not found or coalesce(v_profile.team,'') <> coalesce(p_team,'') or v_profile.role not in ('mitarbeiter','teamleitung') then
    raise exception 'Kein Zugriff auf diesen Teamplan';
  end if;
  if p_status not in ('confirmed','change_requested') then raise exception 'Ungültige Rückmeldung'; end if;
  select * into v_draft from public.dutyplan_team_drafts where team=p_team and month=p_month for update;
  if not found or v_draft.status <> 'released' then raise exception 'Der Teamplan ist aktuell nicht zur Rückmeldung freigegeben'; end if;
  v_responses := coalesce(v_draft.responses,'{}'::jsonb) || jsonb_build_object(auth.uid()::text,
    jsonb_build_object('status',p_status,'note',left(coalesce(p_note,''),1000),'responded_at',now(),'employee_name',v_profile.name));
  update public.dutyplan_team_drafts set responses=v_responses,updated_at=now()
    where team=p_team and month=p_month returning to_jsonb(dutyplan_team_drafts) into v_result;
  return v_result;
end $function$;

create or replace function public.finalize_dutyplan_team_draft(p_team text, p_month text)
returns jsonb language plpgsql security definer set search_path = public
as $function$
declare v_profile public.profiles%rowtype; v_draft public.dutyplan_team_drafts%rowtype; v_missing text; v_result jsonb;
begin
  select * into v_profile from public.profiles where id=auth.uid() and active=true;
  if not found or v_profile.role not in ('admin','admin_teamleitung') then raise exception 'Nur die Administration darf den endgültigen Dienstplan freigeben'; end if;
  select * into v_draft from public.dutyplan_team_drafts where team=p_team and month=p_month for update;
  if not found or v_draft.status <> 'released' then raise exception 'Der Teamplan ist nicht zur Rückmeldung freigegeben'; end if;
  select string_agg(p.name, ', ' order by p.name) into v_missing
  from public.profiles p
  where p.active=true and coalesce(p.team,'')=p_team
    and p.role in ('mitarbeiter','teamleitung')
    and coalesce(v_draft.responses->p.id::text->>'status','') <> 'confirmed';
  if v_missing is not null then raise exception 'Noch nicht alle bestätigt (offen oder Änderungswunsch): %',v_missing; end if;
  update public.dutyplan_team_drafts set status='finalized',finalized_by=auth.uid(),finalized_at=now(),updated_at=now()
    where team=p_team and month=p_month returning to_jsonb(dutyplan_team_drafts) into v_result;
  return v_result;
end $function$;

revoke all on function public.get_dutyplan_team_draft(text,text) from public, anon;
revoke all on function public.save_dutyplan_team_draft(text,text,jsonb,boolean) from public, anon;
revoke all on function public.respond_dutyplan_team_draft(text,text,text,text) from public, anon;
revoke all on function public.finalize_dutyplan_team_draft(text,text) from public, anon;
grant execute on function public.get_dutyplan_team_draft(text,text) to authenticated;
grant execute on function public.save_dutyplan_team_draft(text,text,jsonb,boolean) to authenticated;
grant execute on function public.respond_dutyplan_team_draft(text,text,text,text) to authenticated;
grant execute on function public.finalize_dutyplan_team_draft(text,text) to authenticated;
