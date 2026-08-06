-- Osafi Steel workflow upgrade
-- Run once in Supabase SQL Editor before testing this app version.

create extension if not exists pgcrypto;

alter table public.users add column if not exists email text;
alter table public.users add column if not exists phone text;
alter table public.jobs add column if not exists created_by uuid references public.users(id);
alter table public.ncrs add column if not exists reopened_stage text;

create table if not exists public.job_attachments (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  job_id uuid not null references public.jobs(id) on delete cascade,
  uploader_id uuid references public.users(id),
  kind text not null default 'progress',
  file_path text not null,
  file_name text,
  mime_type text,
  note text,
  created_at timestamptz not null default now()
);

create table if not exists public.job_messages (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  job_id uuid not null references public.jobs(id) on delete cascade,
  user_id uuid not null references public.users(id),
  message text not null,
  created_at timestamptz not null default now()
);

create table if not exists public.complaints (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  job_id uuid references public.jobs(id) on delete set null,
  customer_name text not null,
  phone text,
  complaint text not null,
  resolution text,
  status text not null default 'open' check (status in ('open','closed')),
  created_by uuid references public.users(id),
  created_at timestamptz not null default now()
);

create table if not exists public.accounting_entries (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  entry_date date not null default current_date,
  type text not null check (type in ('income','expense')),
  description text not null,
  amount numeric not null default 0,
  created_by uuid references public.users(id),
  created_at timestamptz not null default now()
);

create table if not exists public.job_stage_approval_requests (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  job_id uuid not null references public.jobs(id) on delete cascade,
  requested_by uuid not null references public.users(id),
  stage text not null,
  answers jsonb not null default '[]'::jsonb,
  notes text,
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  reviewed_by uuid references public.users(id),
  reviewed_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.ncr_approval_requests (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  job_id uuid not null references public.jobs(id) on delete cascade,
  requested_by uuid not null references public.users(id),
  category text not null,
  stage_failed_at text,
  root_cause text not null,
  corrective_action text not null,
  reopened_stage text not null,
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  reviewed_by uuid references public.users(id),
  reviewed_at timestamptz,
  created_at timestamptz not null default now()
);

alter table public.job_attachments enable row level security;
alter table public.job_messages enable row level security;
alter table public.complaints enable row level security;
alter table public.accounting_entries enable row level security;
alter table public.job_stage_approval_requests enable row level security;
alter table public.ncr_approval_requests enable row level security;

create or replace function public.osafi_is_manager()
returns boolean language sql stable as $$
  select exists(select 1 from public.users where id = auth.uid() and role = 'ops_manager')
$$;

create or replace function public.osafi_my_business()
returns uuid language sql stable as $$
  select business_id from public.users where id = auth.uid()
$$;

drop policy if exists job_attachments_access on public.job_attachments;
create policy job_attachments_access on public.job_attachments
for all using (
  business_id = public.osafi_my_business()
  and (public.osafi_is_manager() or exists(select 1 from public.jobs j where j.id = job_id and j.technician_id = auth.uid()))
) with check (
  business_id = public.osafi_my_business()
  and (public.osafi_is_manager() or exists(select 1 from public.jobs j where j.id = job_id and j.technician_id = auth.uid()))
);

drop policy if exists job_messages_access on public.job_messages;
create policy job_messages_access on public.job_messages
for all using (
  business_id = public.osafi_my_business()
  and (public.osafi_is_manager() or exists(select 1 from public.jobs j where j.id = job_id and j.technician_id = auth.uid()))
) with check (
  business_id = public.osafi_my_business()
  and (public.osafi_is_manager() or exists(select 1 from public.jobs j where j.id = job_id and j.technician_id = auth.uid()))
);

drop policy if exists complaints_manager_access on public.complaints;
create policy complaints_manager_access on public.complaints
for all using (business_id = public.osafi_my_business() and public.osafi_is_manager())
with check (business_id = public.osafi_my_business() and public.osafi_is_manager());

drop policy if exists accounting_manager_access on public.accounting_entries;
create policy accounting_manager_access on public.accounting_entries
for all using (business_id = public.osafi_my_business() and public.osafi_is_manager())
with check (business_id = public.osafi_my_business() and public.osafi_is_manager());

drop policy if exists stage_approval_access on public.job_stage_approval_requests;
create policy stage_approval_access on public.job_stage_approval_requests
for all using (
  business_id = public.osafi_my_business()
  and (public.osafi_is_manager() or requested_by = auth.uid() or exists(select 1 from public.jobs j where j.id = job_id and j.technician_id = auth.uid()))
) with check (
  business_id = public.osafi_my_business()
  and (public.osafi_is_manager() or requested_by = auth.uid() or exists(select 1 from public.jobs j where j.id = job_id and j.technician_id = auth.uid()))
);

drop policy if exists ncr_approval_access on public.ncr_approval_requests;
create policy ncr_approval_access on public.ncr_approval_requests
for all using (
  business_id = public.osafi_my_business()
  and (public.osafi_is_manager() or requested_by = auth.uid() or exists(select 1 from public.jobs j where j.id = job_id and j.technician_id = auth.uid()))
) with check (
  business_id = public.osafi_my_business()
  and (public.osafi_is_manager() or requested_by = auth.uid() or exists(select 1 from public.jobs j where j.id = job_id and j.technician_id = auth.uid()))
);

insert into storage.buckets (id, name, public)
values ('job-photos', 'job-photos', false)
on conflict (id) do nothing;

drop policy if exists job_photos_read on storage.objects;
create policy job_photos_read on storage.objects
for select using (
  bucket_id = 'job-photos'
  and (storage.foldername(name))[1] = public.osafi_my_business()::text
);

drop policy if exists job_photos_upload on storage.objects;
create policy job_photos_upload on storage.objects
for insert with check (
  bucket_id = 'job-photos'
  and (storage.foldername(name))[1] = public.osafi_my_business()::text
);

create or replace function public.request_stage_approval(
  p_job_id uuid,
  p_stage text,
  p_answers jsonb,
  p_notes text default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_job public.jobs%rowtype;
  v_user public.users%rowtype;
begin
  select * into v_user from public.users where id = auth.uid();
  select * into v_job from public.jobs where id = p_job_id;
  if v_job.id is null or v_user.business_id <> v_job.business_id then
    raise exception 'Job not found';
  end if;
  if v_user.role <> 'technician' or v_job.technician_id <> v_user.id then
    raise exception 'Only the assigned technician can submit this stage';
  end if;
  insert into public.job_stage_approval_requests(business_id, job_id, requested_by, stage, answers, notes)
  values (v_job.business_id, p_job_id, auth.uid(), p_stage, p_answers, p_notes);
end;
$$;

create or replace function public.approve_stage_submission(p_checklist_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_req public.job_stage_approval_requests%rowtype;
  v_user public.users%rowtype;
  v_next text;
begin
  select * into v_user from public.users where id = auth.uid();
  select * into v_req from public.job_stage_approval_requests where id = p_checklist_id;
  if v_req.id is null or v_user.business_id <> v_req.business_id or v_user.role <> 'ops_manager' then
    raise exception 'Only an operations manager can approve this work';
  end if;
  if v_req.status <> 'pending' then
    raise exception 'This request is not pending';
  end if;
  v_next := case v_req.stage
    when 'cutting' then 'welding'
    when 'welding' then 'finishing'
    when 'finishing' then 'qc'
    when 'qc' then 'done'
    else 'done'
  end;
  insert into public.stage_checklists(job_id, user_id, stage, answers, result, notes)
  values (v_req.job_id, v_req.requested_by, v_req.stage, v_req.answers, 'pass', v_req.notes);
  update public.job_stage_approval_requests
  set status = 'approved', reviewed_by = auth.uid(), reviewed_at = now()
  where id = p_checklist_id;
  update public.jobs
  set current_stage = case when v_next = 'done' then 'done' else v_next end,
      status = case when v_next = 'done' then 'completed' else 'in_production' end,
      completed_at = case when v_next = 'done' then now() else completed_at end
  where id = v_req.job_id;
end;
$$;

create or replace function public.request_ncr_approval(
  p_job_id uuid,
  p_category text,
  p_root_cause text,
  p_corrective_action text,
  p_reopened_stage text
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_job public.jobs%rowtype;
  v_user public.users%rowtype;
begin
  select * into v_user from public.users where id = auth.uid();
  select * into v_job from public.jobs where id = p_job_id;
  if v_job.id is null or v_user.business_id <> v_job.business_id then
    raise exception 'Job not found';
  end if;
  if v_user.role <> 'technician' or v_job.technician_id <> v_user.id then
    raise exception 'Only the assigned technician can raise this NCR';
  end if;
  insert into public.ncr_approval_requests(
    business_id, job_id, requested_by, category, stage_failed_at,
    root_cause, corrective_action, reopened_stage
  ) values (
    v_job.business_id, p_job_id, auth.uid(), p_category, v_job.current_stage,
    p_root_cause, p_corrective_action, p_reopened_stage
  );
end;
$$;

create or replace function public.approve_ncr(p_ncr_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_req public.ncr_approval_requests%rowtype;
  v_user public.users%rowtype;
begin
  select * into v_user from public.users where id = auth.uid();
  select * into v_req from public.ncr_approval_requests where id = p_ncr_id;
  if v_req.id is null or v_user.business_id <> v_req.business_id or v_user.role <> 'ops_manager' then
    raise exception 'Only an operations manager can approve NCRs';
  end if;
  if v_req.status <> 'pending' then
    raise exception 'This NCR request is not pending';
  end if;
  insert into public.ncrs(
    business_id, job_id, category, stage_failed_at, root_cause,
    corrective_action, reopened_stage, status
  ) values (
    v_req.business_id, v_req.job_id, v_req.category, v_req.stage_failed_at,
    v_req.root_cause, v_req.corrective_action, v_req.reopened_stage, 'open'
  );
  update public.ncr_approval_requests
  set status = 'approved', reviewed_by = auth.uid(), reviewed_at = now()
  where id = p_ncr_id;
  update public.jobs
  set status = 'rework', current_stage = v_req.reopened_stage
  where id = v_req.job_id;
end;
$$;

grant execute on function public.request_stage_approval(uuid,text,jsonb,text) to authenticated;
grant execute on function public.approve_stage_submission(uuid) to authenticated;
grant execute on function public.request_ncr_approval(uuid,text,text,text,text) to authenticated;
grant execute on function public.approve_ncr(uuid) to authenticated;
