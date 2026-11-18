-- Bereits auf dem Supabase-Projekt qm-intensivpflege-halle ausgeführt.
-- Erweitert nur die zulässigen Formulararten; bestehende RLS-Regeln bleiben unverändert.
alter table public.qm_form_records
  drop constraint if exists qm_form_records_form_type_check;

alter table public.qm_form_records
  add constraint qm_form_records_form_type_check
  check (form_type = any (array[
    'pflegevisite'::text,
    'begleitung'::text,
    'dienstberatung'::text,
    'fallbesprechung'::text
  ]));
