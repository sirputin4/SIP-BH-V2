create extension if not exists pgcrypto;
create table if not exists public.obhs(
 id uuid primary key default gen_random_uuid(), name text not null unique, address text,
 region text not null, accreditation_status text not null default 'Belum Terakreditasi'
 check(accreditation_status in('Terakreditasi','Belum Terakreditasi')),
 is_active boolean not null default true, created_at timestamptz not null default now()
);
create table if not exists public.profiles(
 id uuid primary key references auth.users(id) on delete cascade, full_name text not null default '',
 role text not null default 'obh' check(role in('admin','obh')),
 account_status text not null default 'pending' check(account_status in('pending','active','rejected')),
 obh_id uuid references public.obhs(id), created_at timestamptz not null default now()
);
create table if not exists public.assistance_records(
 id uuid primary key default gen_random_uuid(), registration_no text not null unique,
 obh_id uuid not null references public.obhs(id), created_by uuid not null references auth.users(id),
 service_date date not null, service_type text not null check(service_type in('Litigasi','Nonlitigasi')),
 category text not null, region text not null, beneficiary_code text not null, summary text not null,
 status text not null default 'submitted' check(status in('submitted','verified','rejected','revision')),
 admin_note text, verified_at timestamptz, verified_by uuid references auth.users(id),
 created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table if not exists public.evaluations(
 id uuid primary key default gen_random_uuid(), assistance_record_id uuid not null unique references public.assistance_records(id) on delete cascade,
 evaluated_by uuid not null references auth.users(id), rating integer not null check(rating between 1 and 5),
 notes text, created_at timestamptz not null default now()
);
create index if not exists idx_records_obh on public.assistance_records(obh_id);
create index if not exists idx_records_status on public.assistance_records(status);
create index if not exists idx_records_date on public.assistance_records(service_date);

create or replace function public.handle_new_user() returns trigger language plpgsql security definer set search_path=''
as $$
begin
 insert into public.profiles(id,full_name,role,account_status,obh_id)
 values(new.id,coalesce(new.raw_user_meta_data->>'full_name',''),'obh','pending',nullif(new.raw_user_meta_data->>'obh_id','')::uuid);
 return new;
end;$$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute procedure public.handle_new_user();

create or replace function public.is_admin() returns boolean language sql stable security definer set search_path=''
as $$ select exists(select 1 from public.profiles p where p.id=(select auth.uid()) and p.role='admin' and p.account_status='active'); $$;
create or replace function public.current_obh_id() returns uuid language sql stable security definer set search_path=''
as $$ select obh_id from public.profiles where id=(select auth.uid()) and role='obh' and account_status='active'; $$;

create or replace function public.protect_record_admin_fields() returns trigger language plpgsql security definer set search_path=''
as $$
begin
 if not public.is_admin() then
  if new.status is distinct from old.status or new.admin_note is distinct from old.admin_note
   or new.verified_at is distinct from old.verified_at or new.verified_by is distinct from old.verified_by
   or new.obh_id is distinct from old.obh_id or new.created_by is distinct from old.created_by
   or new.registration_no is distinct from old.registration_no then
   raise exception 'Only Admin Kanwil can change verification fields.';
  end if;
 else
  if new.status='verified' then new.verified_at=coalesce(new.verified_at,now());new.verified_by=auth.uid();end if;
 end if;
 new.updated_at=now();return new;
end;$$;
drop trigger if exists protect_assistance_record_fields on public.assistance_records;
create trigger protect_assistance_record_fields before update on public.assistance_records for each row execute procedure public.protect_record_admin_fields();

alter table public.obhs enable row level security;
alter table public.profiles enable row level security;
alter table public.assistance_records enable row level security;
alter table public.evaluations enable row level security;

drop policy if exists "read active OBHs" on public.obhs;
create policy "read active OBHs" on public.obhs for select to authenticated using(is_active=true or public.is_admin());
drop policy if exists "admin manage OBHs" on public.obhs;
create policy "admin manage OBHs" on public.obhs for all to authenticated using(public.is_admin()) with check(public.is_admin());

drop policy if exists "read own profile or admin" on public.profiles;
create policy "read own profile or admin" on public.profiles for select to authenticated using(id=(select auth.uid()) or public.is_admin());
drop policy if exists "admin update profiles" on public.profiles;
create policy "admin update profiles" on public.profiles for update to authenticated using(public.is_admin()) with check(public.is_admin());

drop policy if exists "admin or own OBH read records" on public.assistance_records;
create policy "admin or own OBH read records" on public.assistance_records for select to authenticated using(public.is_admin() or obh_id=public.current_obh_id());
drop policy if exists "active OBH create own records" on public.assistance_records;
create policy "active OBH create own records" on public.assistance_records for insert to authenticated with check(created_by=(select auth.uid()) and obh_id=public.current_obh_id() and status='submitted');
drop policy if exists "admin or owner update records" on public.assistance_records;
create policy "admin or owner update records" on public.assistance_records for update to authenticated using(public.is_admin() or (created_by=(select auth.uid()) and obh_id=public.current_obh_id() and status in('submitted','revision'))) with check(public.is_admin() or (created_by=(select auth.uid()) and obh_id=public.current_obh_id() and status in('submitted','revision')));
drop policy if exists "admin delete records" on public.assistance_records;
create policy "admin delete records" on public.assistance_records for delete to authenticated using(public.is_admin());

drop policy if exists "read evaluations" on public.evaluations;
create policy "read evaluations" on public.evaluations for select to authenticated using(public.is_admin() or exists(select 1 from public.assistance_records r where r.id=assistance_record_id and r.obh_id=public.current_obh_id()));
drop policy if exists "admin create evaluations" on public.evaluations;
create policy "admin create evaluations" on public.evaluations for insert to authenticated with check(public.is_admin() and evaluated_by=(select auth.uid()));
drop policy if exists "admin update evaluations" on public.evaluations;
create policy "admin update evaluations" on public.evaluations for update to authenticated using(public.is_admin()) with check(public.is_admin());
drop policy if exists "admin delete evaluations" on public.evaluations;
create policy "admin delete evaluations" on public.evaluations for delete to authenticated using(public.is_admin());

insert into public.obhs(name,region,accreditation_status) values
('OBH Demo Banda Aceh','Banda Aceh','Terakreditasi'),
('OBH Demo Aceh Besar','Aceh Besar','Belum Terakreditasi'),
('OBH Demo Bireuen','Bireuen','Terakreditasi')
on conflict(name) do nothing;

-- After registering your own account, promote it to Admin (replace email):
-- update public.profiles p set role='admin',account_status='active',obh_id=null
-- from auth.users u where p.id=u.id and u.email='your-admin-email@example.com';
