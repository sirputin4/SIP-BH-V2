-- SIP-BH V2 MIGRATION
-- Run this in Supabase SQL Editor on the EXISTING project.
-- Idempotent for repeat execution. Does not drop V1 tables or accounts.

create extension if not exists pgcrypto;

-- 1) Extend existing organization table without deleting V1 data.
alter table public.obhs add column if not exists phone text;
alter table public.obhs add column if not exists email text;
alter table public.obhs add column if not exists accreditation_year integer;
alter table public.obhs add column if not exists contact_person text;
alter table public.obhs add column if not exists updated_at timestamptz not null default now();

-- Keep profile role / account structure compatible with V1.
alter table public.profiles add column if not exists phone text;

-- 2) OBH personnel.
create table if not exists public.obh_members (
  id uuid primary key default gen_random_uuid(),
  obh_id uuid not null references public.obhs(id) on delete cascade,
  full_name text not null,
  position text,
  phone text,
  email text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- 3) Beneficiaries. NIK is optional and must be handled as restricted personal data.
create table if not exists public.beneficiaries (
  id uuid primary key default gen_random_uuid(),
  obh_id uuid not null references public.obhs(id) on delete restrict,
  beneficiary_code text not null,
  full_name text not null,
  birth_place text,
  birth_date date,
  education text,
  nik text,
  region text not null,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(obh_id, beneficiary_code)
);
create index if not exists idx_beneficiaries_obh on public.beneficiaries(obh_id);

-- 4) Main assistance service table. One beneficiary can receive multiple services.
create table if not exists public.assistance_services (
  id uuid primary key default gen_random_uuid(),
  registration_no text not null unique,
  obh_id uuid not null references public.obhs(id) on delete restrict,
  beneficiary_id uuid not null references public.beneficiaries(id) on delete restrict,
  created_by uuid not null references auth.users(id),
  entry_source text not null default 'obh' check(entry_source in ('obh','admin')),
  service_date date not null,
  service_type text not null check(service_type in ('Litigasi','Nonlitigasi')),
  case_type text check(case_type in ('Perdata','Pidana','PTUN','Belum Diklasifikasikan')),
  activity_type text check(activity_type in ('Drafting Dokumen','Investigasi Kasus','Konsultasi Hukum','Mediasi','Negosiasi','Pemberdayaan Masyarakat','Pendampingan di Luar Pengadilan','Penelitian Hukum','Penyuluhan Hukum','Belum Diklasifikasikan')),
  region text not null,
  summary text not null,
  service_amount numeric(14,2) not null default 0 check(service_amount >= 0),
  current_stage text,
  status text not null default 'submitted' check(status in ('draft','submitted','revision','verified','rejected')),
  admin_note text,
  verified_at timestamptz,
  verified_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint service_type_category_check check (
    (service_type='Litigasi' and case_type is not null and activity_type is null) or
    (service_type='Nonlitigasi' and activity_type is not null and case_type is null)
  )
);
create index if not exists idx_services_obh on public.assistance_services(obh_id);
create index if not exists idx_services_date on public.assistance_services(service_date);
create index if not exists idx_services_status on public.assistance_services(status);
create index if not exists idx_services_beneficiary on public.assistance_services(beneficiary_id);

-- 5) Append-only service progress history.
create table if not exists public.service_progress (
  id uuid primary key default gen_random_uuid(),
  service_id uuid not null references public.assistance_services(id) on delete cascade,
  progress_date date not null,
  stage text not null,
  description text not null,
  entered_by uuid not null references auth.users(id),
  attachment_path text,
  created_at timestamptz not null default now()
);
create index if not exists idx_progress_service on public.service_progress(service_id, progress_date);

-- 6) Evaluation header and detailed criteria scores.
create table if not exists public.service_evaluations (
  id uuid primary key default gen_random_uuid(),
  service_id uuid not null unique references public.assistance_services(id) on delete cascade,
  evaluated_by uuid not null references auth.users(id),
  evaluation_date date not null default current_date,
  notes text,
  created_at timestamptz not null default now()
);
create table if not exists public.evaluation_scores (
  id uuid primary key default gen_random_uuid(),
  evaluation_id uuid not null references public.service_evaluations(id) on delete cascade,
  criterion text not null,
  score integer not null check(score between 1 and 5),
  notes text,
  unique(evaluation_id, criterion)
);

-- 7) Periodic reports and uploaded files.
create table if not exists public.report_submissions (
  id uuid primary key default gen_random_uuid(),
  obh_id uuid not null references public.obhs(id) on delete restrict,
  submitted_by uuid not null references auth.users(id),
  period_type text not null check(period_type in ('Triwulan','Semester','Tahunan')),
  period_year integer not null check(period_year between 2000 and 2100),
  period_number integer check(period_number between 1 and 4),
  title text not null,
  description text,
  file_path text,
  status text not null default 'submitted' check(status in ('submitted','revision','accepted','rejected')),
  admin_note text,
  reviewed_by uuid references auth.users(id),
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint report_period_number_check check (
    (period_type='Triwulan' and period_number is not null) or
    (period_type='Semester' and period_number in (1,2)) or
    (period_type='Tahunan' and period_number is null)
  )
);
create index if not exists idx_reports_obh on public.report_submissions(obh_id);

-- 8) Audit trail for sensitive workflow events.
create table if not exists public.audit_logs (
  id bigint generated always as identity primary key,
  actor_id uuid references auth.users(id),
  action text not null,
  table_name text not null,
  record_id text,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

-- 9) Migrate V1 assistance records. Existing rows are preserved in the old table too.
-- The V1 beneficiary_code is reused as a beneficiary code; the system does not invent real identity data.
do $$
declare r record; b_id uuid; new_id uuid; normalized_case text;
begin
  for r in select * from public.assistance_records loop
    if not exists(select 1 from public.assistance_services s where s.registration_no=r.registration_no) then
      select id into b_id from public.beneficiaries where obh_id=r.obh_id and beneficiary_code=r.beneficiary_code limit 1;
      if b_id is null then
        insert into public.beneficiaries(obh_id,beneficiary_code,full_name,region,created_by)
        values(r.obh_id,r.beneficiary_code,r.beneficiary_code,r.region,r.created_by)
        returning id into b_id;
      end if;
      normalized_case := case
        when lower(r.category) in ('perdata') then 'Perdata'
        when lower(r.category) in ('pidana') then 'Pidana'
        when lower(r.category) in ('ptun','tata usaha negara') then 'PTUN'
        else null end;
      insert into public.assistance_services(
        registration_no,obh_id,beneficiary_id,created_by,entry_source,service_date,service_type,
        case_type,activity_type,region,summary,service_amount,status,admin_note,verified_at,verified_by
      ) values (
        r.registration_no,r.obh_id,b_id,r.created_by,'obh',r.service_date,r.service_type,
        case when r.service_type='Litigasi' then coalesce(normalized_case,'Belum Diklasifikasikan') else null end,
        case when r.service_type='Nonlitigasi' then
          case when r.category in ('Drafting Dokumen','Investigasi Kasus','Konsultasi Hukum','Mediasi','Negosiasi','Pemberdayaan Masyarakat','Pendampingan di Luar Pengadilan','Penelitian Hukum','Penyuluhan Hukum') then r.category else 'Belum Diklasifikasikan' end
        else null end,
        r.region,case when r.category not in ('Perdata','Pidana','PTUN','Tata Usaha Negara','Drafting Dokumen','Investigasi Kasus','Konsultasi Hukum','Mediasi','Negosiasi','Pemberdayaan Masyarakat','Pendampingan di Luar Pengadilan','Penelitian Hukum','Penyuluhan Hukum') then 'Kategori V1: '||r.category||' — '||r.summary else r.summary end,0,
        case r.status when 'verified' then 'verified' when 'rejected' then 'rejected' when 'revision' then 'revision' else 'submitted' end,
        r.admin_note,r.verified_at,r.verified_by
      );
    end if;
  end loop;
end $$;

-- 10) Helper functions for RLS. SECURITY DEFINER avoids recursive profile policies.
create or replace function public.sipbh_is_admin() returns boolean
language sql stable security definer set search_path=public,auth
as $$ select exists(select 1 from public.profiles p where p.id=auth.uid() and p.role='admin' and p.account_status='active'); $$;
create or replace function public.sipbh_current_obh() returns uuid
language sql stable security definer set search_path=public,auth
as $$ select p.obh_id from public.profiles p where p.id=auth.uid() and p.role='obh' and p.account_status='active' limit 1; $$;

-- 11) RLS enablement.
alter table public.obhs enable row level security;
alter table public.profiles enable row level security;
alter table public.obh_members enable row level security;
alter table public.beneficiaries enable row level security;
alter table public.assistance_services enable row level security;
alter table public.service_progress enable row level security;
alter table public.service_evaluations enable row level security;
alter table public.evaluation_scores enable row level security;
alter table public.report_submissions enable row level security;
alter table public.audit_logs enable row level security;

-- Table privileges (RLS still determines which rows/actions are allowed).
grant usage on schema public to anon, authenticated;
grant select on public.obhs to anon;
grant select,insert,update,delete on public.obhs,public.obh_members,public.beneficiaries,public.assistance_services,public.service_progress,public.service_evaluations,public.evaluation_scores,public.report_submissions to authenticated;
grant select on public.profiles to authenticated;
grant update on public.profiles to authenticated;
grant select,insert on public.audit_logs to authenticated;
grant usage,select on sequence public.audit_logs_id_seq to authenticated;

-- OBH directory: public visitors can see active organizations only.
drop policy if exists obhs_public_active_read on public.obhs;
create policy obhs_public_active_read on public.obhs for select to anon using(is_active=true);
drop policy if exists obhs_authenticated_read on public.obhs;
create policy obhs_authenticated_read on public.obhs for select to authenticated using(is_active=true or public.sipbh_is_admin());
drop policy if exists obhs_admin_manage on public.obhs;
create policy obhs_admin_manage on public.obhs for all to authenticated using(public.sipbh_is_admin()) with check(public.sipbh_is_admin());

-- Profiles: self can read own row; Admin can read/update all. Self-service role escalation is blocked by RLS.
drop policy if exists profiles_self_or_admin_read on public.profiles;
create policy profiles_self_or_admin_read on public.profiles for select to authenticated using(id=auth.uid() or public.sipbh_is_admin());
drop policy if exists profiles_admin_update on public.profiles;
create policy profiles_admin_update on public.profiles for update to authenticated using(public.sipbh_is_admin()) with check(public.sipbh_is_admin());

-- Organization members.
drop policy if exists members_read_scope on public.obh_members;
create policy members_read_scope on public.obh_members for select to authenticated using(public.sipbh_is_admin() or obh_id=public.sipbh_current_obh());
drop policy if exists members_admin_manage on public.obh_members;
create policy members_admin_manage on public.obh_members for all to authenticated using(public.sipbh_is_admin()) with check(public.sipbh_is_admin());
drop policy if exists members_obh_manage on public.obh_members;
create policy members_obh_manage on public.obh_members for all to authenticated using(obh_id=public.sipbh_current_obh()) with check(obh_id=public.sipbh_current_obh());

-- Beneficiaries.
drop policy if exists beneficiaries_scope_read on public.beneficiaries;
create policy beneficiaries_scope_read on public.beneficiaries for select to authenticated using(public.sipbh_is_admin() or obh_id=public.sipbh_current_obh());
drop policy if exists beneficiaries_scope_insert on public.beneficiaries;
create policy beneficiaries_scope_insert on public.beneficiaries for insert to authenticated with check((public.sipbh_is_admin() or obh_id=public.sipbh_current_obh()) and created_by=auth.uid());
drop policy if exists beneficiaries_scope_update on public.beneficiaries;
create policy beneficiaries_scope_update on public.beneficiaries for update to authenticated using(public.sipbh_is_admin() or obh_id=public.sipbh_current_obh()) with check(public.sipbh_is_admin() or obh_id=public.sipbh_current_obh());
drop policy if exists beneficiaries_admin_delete on public.beneficiaries;
create policy beneficiaries_admin_delete on public.beneficiaries for delete to authenticated using(public.sipbh_is_admin());

-- Services: both roles can create. OBH is limited to own organization; Admin can record for any OBH.
drop policy if exists services_scope_read on public.assistance_services;
create policy services_scope_read on public.assistance_services for select to authenticated using(public.sipbh_is_admin() or obh_id=public.sipbh_current_obh());
drop policy if exists services_scope_insert on public.assistance_services;
create policy services_scope_insert on public.assistance_services for insert to authenticated with check(
  created_by=auth.uid() and ((public.sipbh_is_admin()) or (obh_id=public.sipbh_current_obh() and entry_source='obh' and status in ('draft','submitted')))
);
drop policy if exists services_scope_update on public.assistance_services;
create policy services_scope_update on public.assistance_services for update to authenticated using(
  public.sipbh_is_admin() or (obh_id=public.sipbh_current_obh() and created_by=auth.uid() and status in ('draft','revision','submitted'))
) with check(public.sipbh_is_admin() or (obh_id=public.sipbh_current_obh() and created_by=auth.uid() and status in ('draft','revision','submitted')));
drop policy if exists services_admin_delete on public.assistance_services;
create policy services_admin_delete on public.assistance_services for delete to authenticated using(public.sipbh_is_admin());

-- Progress history.
drop policy if exists progress_scope_read on public.service_progress;
create policy progress_scope_read on public.service_progress for select to authenticated using(exists(select 1 from public.assistance_services s where s.id=service_id and (public.sipbh_is_admin() or s.obh_id=public.sipbh_current_obh())));
drop policy if exists progress_scope_insert on public.service_progress;
create policy progress_scope_insert on public.service_progress for insert to authenticated with check(entered_by=auth.uid() and exists(select 1 from public.assistance_services s where s.id=service_id and (public.sipbh_is_admin() or s.obh_id=public.sipbh_current_obh())));
drop policy if exists progress_admin_update on public.service_progress;
create policy progress_admin_update on public.service_progress for update to authenticated using(public.sipbh_is_admin()) with check(public.sipbh_is_admin());
drop policy if exists progress_admin_delete on public.service_progress;
create policy progress_admin_delete on public.service_progress for delete to authenticated using(public.sipbh_is_admin());

-- Evaluations: Admin only creates and manages scores; both roles can read within scope.
drop policy if exists evaluations_scope_read on public.service_evaluations;
create policy evaluations_scope_read on public.service_evaluations for select to authenticated using(public.sipbh_is_admin() or exists(select 1 from public.assistance_services s where s.id=service_id and s.obh_id=public.sipbh_current_obh()));
drop policy if exists evaluations_admin_manage on public.service_evaluations;
create policy evaluations_admin_manage on public.service_evaluations for all to authenticated using(public.sipbh_is_admin()) with check(public.sipbh_is_admin());
drop policy if exists scores_scope_read on public.evaluation_scores;
create policy scores_scope_read on public.evaluation_scores for select to authenticated using(exists(select 1 from public.service_evaluations e join public.assistance_services s on s.id=e.service_id where e.id=evaluation_id and (public.sipbh_is_admin() or s.obh_id=public.sipbh_current_obh())));
drop policy if exists scores_admin_manage on public.evaluation_scores;
create policy scores_admin_manage on public.evaluation_scores for all to authenticated using(public.sipbh_is_admin()) with check(public.sipbh_is_admin());

-- Reports.
drop policy if exists reports_scope_read on public.report_submissions;
create policy reports_scope_read on public.report_submissions for select to authenticated using(public.sipbh_is_admin() or obh_id=public.sipbh_current_obh());
drop policy if exists reports_scope_insert on public.report_submissions;
create policy reports_scope_insert on public.report_submissions for insert to authenticated with check(submitted_by=auth.uid() and (public.sipbh_is_admin() or obh_id=public.sipbh_current_obh()));
drop policy if exists reports_scope_update on public.report_submissions;
create policy reports_scope_update on public.report_submissions for update to authenticated using(public.sipbh_is_admin() or (obh_id=public.sipbh_current_obh() and status in ('submitted','revision'))) with check(public.sipbh_is_admin() or obh_id=public.sipbh_current_obh());
drop policy if exists reports_admin_delete on public.report_submissions;
create policy reports_admin_delete on public.report_submissions for delete to authenticated using(public.sipbh_is_admin());

-- Audit logs are admin-readable. Inserts are allowed to authenticated users, but not updates/deletes.
drop policy if exists audit_admin_read on public.audit_logs;
create policy audit_admin_read on public.audit_logs for select to authenticated using(public.sipbh_is_admin());
drop policy if exists audit_authenticated_insert on public.audit_logs;
create policy audit_authenticated_insert on public.audit_logs for insert to authenticated with check(actor_id=auth.uid());

-- Private storage bucket for reports and progress attachments.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('sipbh-private','sipbh-private',false,10485760,array['application/pdf','application/vnd.openxmlformats-officedocument.spreadsheetml.sheet','application/vnd.ms-excel'])
on conflict(id) do update set public=false, file_size_limit=10485760, allowed_mime_types=excluded.allowed_mime_types;

drop policy if exists sipbh_storage_read on storage.objects;
create policy sipbh_storage_read on storage.objects for select to authenticated using(
 bucket_id='sipbh-private' and (public.sipbh_is_admin() or (storage.foldername(name))[1]=public.sipbh_current_obh()::text)
);
drop policy if exists sipbh_storage_insert on storage.objects;
create policy sipbh_storage_insert on storage.objects for insert to authenticated with check(
 bucket_id='sipbh-private' and (public.sipbh_is_admin() or (storage.foldername(name))[1]=public.sipbh_current_obh()::text)
);
drop policy if exists sipbh_storage_update on storage.objects;
create policy sipbh_storage_update on storage.objects for update to authenticated using(
 bucket_id='sipbh-private' and (public.sipbh_is_admin() or (storage.foldername(name))[1]=public.sipbh_current_obh()::text)
) with check(bucket_id='sipbh-private' and (public.sipbh_is_admin() or (storage.foldername(name))[1]=public.sipbh_current_obh()::text));
drop policy if exists sipbh_storage_delete on storage.objects;
create policy sipbh_storage_delete on storage.objects for delete to authenticated using(
 bucket_id='sipbh-private' and (public.sipbh_is_admin() or (storage.foldername(name))[1]=public.sipbh_current_obh()::text)
);

-- End migration. Promote the first Admin separately using the README instructions.

-- OBH may update only its public contact/profile fields. Accreditation and activation
-- remain controlled by Admin Kanwil through column-level privileges and RLS.
grant update on public.obhs to authenticated;
drop policy if exists obhs_own_profile_update on public.obhs;
create policy obhs_own_profile_update on public.obhs for update to authenticated
using(id=public.sipbh_current_obh())
with check(id=public.sipbh_current_obh());


-- Protect accreditation and organization activation fields from OBH self-editing.
create or replace function public.sipbh_protect_obh_admin_fields() returns trigger
language plpgsql security definer set search_path=public,auth
as $$
begin
  if not public.sipbh_is_admin() then
    if new.name is distinct from old.name
      or new.accreditation_status is distinct from old.accreditation_status
      or new.accreditation_year is distinct from old.accreditation_year
      or new.is_active is distinct from old.is_active then
      raise exception 'Perubahan nama resmi, akreditasi, dan status aktif hanya dapat dilakukan Admin Kanwil.';
    end if;
  end if;
  new.updated_at=now();
  return new;
end $$;
drop trigger if exists sipbh_protect_obh_fields on public.obhs;
create trigger sipbh_protect_obh_fields before update on public.obhs
for each row execute function public.sipbh_protect_obh_admin_fields();

-- OBH users cannot mark a service verified/rejected or edit Admin verification fields.
create or replace function public.sipbh_protect_service_admin_fields() returns trigger
language plpgsql security definer set search_path=public,auth
as $$
begin
  if not public.sipbh_is_admin() then
    if new.status not in ('draft','submitted','revision')
      or new.admin_note is distinct from old.admin_note
      or new.verified_at is distinct from old.verified_at
      or new.verified_by is distinct from old.verified_by
      or new.obh_id is distinct from old.obh_id
      or new.created_by is distinct from old.created_by
      or new.entry_source is distinct from old.entry_source
      or new.registration_no is distinct from old.registration_no then
      raise exception 'Status verifikasi dan metadata administrasi hanya dapat diubah Admin Kanwil.';
    end if;
  end if;
  if public.sipbh_is_admin() and new.status='verified' then
    new.verified_at=coalesce(new.verified_at,now());
    new.verified_by=auth.uid();
  end if;
  new.updated_at=now();
  return new;
end $$;
drop trigger if exists sipbh_protect_service_fields on public.assistance_services;
create trigger sipbh_protect_service_fields before update on public.assistance_services
for each row execute function public.sipbh_protect_service_admin_fields();

-- Protect report review fields from OBH self-editing.
create or replace function public.sipbh_protect_report_review_fields() returns trigger
language plpgsql security definer set search_path=public,auth
as $$
begin
  if not public.sipbh_is_admin() then
    if new.status is distinct from old.status
      or new.admin_note is distinct from old.admin_note
      or new.reviewed_by is distinct from old.reviewed_by
      or new.reviewed_at is distinct from old.reviewed_at
      or new.obh_id is distinct from old.obh_id
      or new.submitted_by is distinct from old.submitted_by then
      raise exception 'Status verifikasi laporan hanya dapat diubah Admin Kanwil.';
    end if;
  end if;
  new.updated_at=now();
  return new;
end $$;
drop trigger if exists sipbh_protect_report_fields on public.report_submissions;
create trigger sipbh_protect_report_fields before update on public.report_submissions
for each row execute function public.sipbh_protect_report_review_fields();

-- Add audit events without copying sensitive beneficiary or case contents into the log.
create or replace function public.sipbh_write_audit_log() returns trigger
language plpgsql security definer set search_path=public,auth
as $$
declare rid text;
begin
  if TG_OP='DELETE' then rid=old.id::text; else rid=new.id::text; end if;
  insert into public.audit_logs(actor_id,action,table_name,record_id,details)
  values(auth.uid(),lower(TG_OP),TG_TABLE_NAME,rid,jsonb_build_object('event_time',now()));
  if TG_OP='DELETE' then return old; else return new; end if;
end $$;
drop trigger if exists sipbh_audit_services on public.assistance_services;
create trigger sipbh_audit_services after insert or update or delete on public.assistance_services
for each row execute function public.sipbh_write_audit_log();
drop trigger if exists sipbh_audit_progress on public.service_progress;
create trigger sipbh_audit_progress after insert or update or delete on public.service_progress
for each row execute function public.sipbh_write_audit_log();
drop trigger if exists sipbh_audit_reports on public.report_submissions;
create trigger sipbh_audit_reports after insert or update or delete on public.report_submissions
for each row execute function public.sipbh_write_audit_log();
drop trigger if exists sipbh_audit_obhs on public.obhs;
create trigger sipbh_audit_obhs after insert or update or delete on public.obhs
for each row execute function public.sipbh_write_audit_log();


-- Keep the latest stage available on the service row for quick list/dashboard views.
create or replace function public.sipbh_sync_current_stage() returns trigger
language plpgsql security definer set search_path=public,auth
as $$
begin
  update public.assistance_services set current_stage=new.stage, updated_at=now() where id=new.service_id;
  return new;
end $$;
drop trigger if exists sipbh_sync_progress_stage on public.service_progress;
create trigger sipbh_sync_progress_stage after insert on public.service_progress
for each row execute function public.sipbh_sync_current_stage();

-- OBH users may still view their own organization record if it is inactive.
drop policy if exists obhs_owner_read on public.obhs;
create policy obhs_owner_read on public.obhs for select to authenticated using(id=public.sipbh_current_obh());

-- Preserve V1 evaluation headers and scores where a matching service was migrated.
do $$
declare r record; eval_id uuid;
begin
  for r in
    select e.*, s.id as new_service_id
    from public.evaluations e
    join public.assistance_records oldr on oldr.id=e.assistance_record_id
    join public.assistance_services s on s.registration_no=oldr.registration_no
  loop
    if not exists(select 1 from public.service_evaluations where service_id=r.new_service_id) then
      insert into public.service_evaluations(service_id,evaluated_by,evaluation_date,notes)
      values(r.new_service_id,r.evaluated_by,r.created_at::date,r.notes)
      returning id into eval_id;
      insert into public.evaluation_scores(evaluation_id,criterion,score,notes)
      values(eval_id,'Penilaian umum V1',r.rating,r.notes)
      on conflict(evaluation_id,criterion) do nothing;
    end if;
  end loop;
end $$;

-- Mark migrated V1 services with an honest placeholder progress item because V1
-- did not store a detailed stage history.
insert into public.service_progress(service_id,progress_date,stage,description,entered_by)
select s.id,s.service_date,'Data migrasi V1','Riwayat tahapan rinci belum tersedia pada data V1.',s.created_by
from public.assistance_services s
where s.registration_no like 'BH-%'
  and not exists(select 1 from public.service_progress p where p.service_id=s.id);
