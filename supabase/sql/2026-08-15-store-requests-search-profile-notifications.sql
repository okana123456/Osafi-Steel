-- Osafi Steel collaboration upgrade (2026-08-15)
-- Safe job linking for Store Manager, technician material requests,
-- team identity fields, profile photos and role-based notifications.

create extension if not exists pgcrypto;

alter table public.users
  add column if not exists location text,
  add column if not exists id_number text,
  add column if not exists profile_photo_path text;

create unique index if not exists users_business_id_number_unique
  on public.users (business_id, lower(id_number))
  where id_number is not null and length(trim(id_number)) > 0;

-- Store staff need a job reference while issuing stock, but do not need access
-- to customer prices, costing or other private job columns.
create or replace function public.list_inventory_jobs()
returns table(id uuid, product_type text, deadline date, status text)
language plpgsql
security definer
set search_path = public
as $$
declare v_user public.users%rowtype;
begin
  select * into v_user from public.users where users.id = auth.uid();
  if v_user.id is null or v_user.role::text not in ('ops_manager','store_manager') then
    raise exception 'Only the Store Manager or Administrator can view inventory job references';
  end if;
  return query
    select j.id, j.product_type, j.deadline, j.status::text
    from public.jobs j
    where j.business_id = v_user.business_id
      and j.status::text not in ('delivered','cancelled')
    order by j.deadline nulls last, j.created_at desc;
end;
$$;

create table if not exists public.material_requests (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  job_id uuid not null references public.jobs(id) on delete cascade,
  technician_id uuid not null references public.users(id),
  inventory_item_id uuid not null references public.inventory_items(id),
  qty numeric not null check (qty > 0),
  notes text,
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  reviewed_by uuid references public.users(id),
  reviewed_at timestamptz,
  review_notes text,
  created_at timestamptz not null default now()
);

create index if not exists material_requests_business_status_idx
  on public.material_requests(business_id,status,created_at desc);
create index if not exists material_requests_technician_idx
  on public.material_requests(technician_id,created_at desc);

alter table public.material_requests enable row level security;
drop policy if exists material_requests_read on public.material_requests;
create policy material_requests_read on public.material_requests
for select using (
  business_id = public.osafi_my_business()
  and (
    technician_id = auth.uid()
    or public.osafi_has_role('ops_manager','store_manager')
  )
);

create or replace function public.list_material_requests()
returns table(
  id uuid, job_id uuid, technician_id uuid, inventory_item_id uuid,
  qty numeric, notes text, status text, created_at timestamptz,
  technician_name text, item_name text, item_unit text, job_name text
)
language plpgsql
security definer
set search_path = public
as $$
declare v_user public.users%rowtype;
begin
  select * into v_user from public.users where users.id=auth.uid();
  if v_user.id is null or v_user.role::text not in ('ops_manager','store_manager','technician') then
    raise exception 'You do not have access to material requests';
  end if;
  return query
    select r.id,r.job_id,r.technician_id,r.inventory_item_id,r.qty,r.notes,r.status,
      r.created_at,u.full_name,i.name,i.unit,j.product_type
    from public.material_requests r
    join public.users u on u.id=r.technician_id
    join public.inventory_items i on i.id=r.inventory_item_id
    join public.jobs j on j.id=r.job_id
    where r.business_id=v_user.business_id
      and (v_user.role::text in ('ops_manager','store_manager') or r.technician_id=v_user.id)
    order by r.created_at desc;
end;
$$;

create or replace function public.list_requestable_inventory()
returns table(id uuid, name text, size_grade text, unit text, qty_on_hand numeric)
language plpgsql
security definer
set search_path = public
as $$
declare v_user public.users%rowtype;
begin
  select * into v_user from public.users where users.id = auth.uid();
  if v_user.id is null or v_user.role::text <> 'technician' then
    raise exception 'Only technicians can request job materials';
  end if;
  return query
    select i.id, i.name, i.size_grade, i.unit, i.qty_on_hand
    from public.inventory_items i
    where i.business_id = v_user.business_id
    order by i.name, i.size_grade;
end;
$$;

create or replace function public.request_job_material(
  p_job_id uuid,
  p_item_id uuid,
  p_qty numeric,
  p_notes text default null
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user public.users%rowtype;
  v_job public.jobs%rowtype;
  v_item public.inventory_items%rowtype;
  v_id uuid;
begin
  select * into v_user from public.users where users.id = auth.uid();
  select * into v_job from public.jobs where jobs.id = p_job_id;
  select * into v_item from public.inventory_items where inventory_items.id = p_item_id;
  if v_user.id is null or v_user.role::text <> 'technician' then
    raise exception 'Only technicians can request materials';
  end if;
  if v_job.id is null or v_job.business_id <> v_user.business_id or v_job.technician_id <> v_user.id then
    raise exception 'You can request materials only for a job assigned to you';
  end if;
  if v_item.id is null or v_item.business_id <> v_user.business_id then
    raise exception 'Inventory item was not found';
  end if;
  if p_qty is null or p_qty <= 0 then raise exception 'Enter a valid quantity'; end if;
  if exists (
    select 1 from public.material_requests r
    where r.job_id=p_job_id and r.inventory_item_id=p_item_id
      and r.technician_id=v_user.id and r.status='pending'
  ) then
    raise exception 'A request for this material is already waiting for approval';
  end if;
  insert into public.material_requests(business_id,job_id,technician_id,inventory_item_id,qty,notes)
  values(v_user.business_id,p_job_id,v_user.id,p_item_id,p_qty,nullif(trim(p_notes),''))
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.review_material_request(
  p_request_id uuid,
  p_approve boolean,
  p_notes text default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user public.users%rowtype;
  v_request public.material_requests%rowtype;
begin
  select * into v_user from public.users where users.id=auth.uid();
  select * into v_request from public.material_requests where id=p_request_id for update;
  if v_user.id is null or v_user.role::text not in ('ops_manager','store_manager') then
    raise exception 'Only the Store Manager or Administrator can review material requests';
  end if;
  if v_request.id is null or v_request.business_id <> v_user.business_id then
    raise exception 'Material request was not found';
  end if;
  if v_request.status <> 'pending' then raise exception 'This request has already been reviewed'; end if;
  if p_approve then
    perform public.move_inventory_department(
      v_request.inventory_item_id,'out',v_request.qty,v_request.job_id,
      'Approved technician request ' || left(v_request.id::text,8)
    );
  end if;
  update public.material_requests
  set status=case when p_approve then 'approved' else 'rejected' end,
      reviewed_by=v_user.id, reviewed_at=now(), review_notes=nullif(trim(p_notes),'')
  where id=p_request_id;
end;
$$;

create or replace function public.set_my_profile_photo(p_path text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_user public.users%rowtype;
begin
  select * into v_user from public.users where users.id=auth.uid();
  if v_user.id is null then raise exception 'Sign in required'; end if;
  if p_path is null or split_part(p_path,'/',1) <> v_user.business_id::text
     or split_part(p_path,'/',2) <> v_user.id::text then
    raise exception 'Invalid profile photo path';
  end if;
  update public.users set profile_photo_path=p_path where id=v_user.id;
end;
$$;

insert into storage.buckets(id,name,public)
values('profile-photos','profile-photos',false)
on conflict(id) do update set public=false;

drop policy if exists profile_photos_read on storage.objects;
create policy profile_photos_read on storage.objects for select using (
  bucket_id='profile-photos'
  and (storage.foldername(name))[1]=public.osafi_my_business()::text
);
drop policy if exists profile_photos_insert on storage.objects;
create policy profile_photos_insert on storage.objects for insert with check (
  bucket_id='profile-photos'
  and (storage.foldername(name))[1]=public.osafi_my_business()::text
  and (storage.foldername(name))[2]=auth.uid()::text
);
drop policy if exists profile_photos_update on storage.objects;
create policy profile_photos_update on storage.objects for update using (
  bucket_id='profile-photos'
  and (storage.foldername(name))[1]=public.osafi_my_business()::text
  and (storage.foldername(name))[2]=auth.uid()::text
) with check (
  bucket_id='profile-photos'
  and (storage.foldername(name))[1]=public.osafi_my_business()::text
  and (storage.foldername(name))[2]=auth.uid()::text
);

-- A single safe feed drives the notification bell without exposing unrelated rows.
create or replace function public.get_role_notifications()
returns table(kind text, title text, detail text, target_id uuid, created_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
declare v_user public.users%rowtype;
begin
  select * into v_user from public.users where users.id=auth.uid();
  if v_user.id is null then return; end if;

  if v_user.role::text in ('ops_manager','store_manager') then
    return query select 'material_request'::text, 'Material request'::text,
      (u.full_name || ' requested ' || r.qty || ' ' || i.unit || ' of ' || i.name)::text,
      r.id, r.created_at
    from public.material_requests r
    join public.users u on u.id=r.technician_id
    join public.inventory_items i on i.id=r.inventory_item_id
    where r.business_id=v_user.business_id and r.status='pending';
  end if;

  if v_user.role::text in ('ops_manager','operations_manager') then
    return query select 'stage_approval'::text, 'Stage approval waiting'::text,
      (j.product_type || ' - ' || a.stage::text)::text, a.id, a.created_at
    from public.job_stage_approval_requests a join public.jobs j on j.id=a.job_id
    where a.business_id=v_user.business_id and a.status='pending'
      and (v_user.role::text='ops_manager' or j.created_by=v_user.id);
    return query select 'ncr_approval'::text, 'NCR approval waiting'::text,
      (j.product_type || ' - ' || n.category::text)::text, n.id, n.created_at
    from public.ncr_approval_requests n join public.jobs j on j.id=n.job_id
    where n.business_id=v_user.business_id and n.status='pending'
      and (v_user.role::text='ops_manager' or j.created_by=v_user.id);
  end if;

  if v_user.role::text='accountant' then
    return query select 'technician_payment'::text, 'Technician payment due'::text,
      (u.full_name || ' - ' || p.amount)::text, p.id, p.created_at
    from public.technician_payments p join public.users u on u.id=p.technician_id
    where p.business_id=v_user.business_id and p.status='pending';
  end if;

  if v_user.role::text='technician' then
    return query select 'job_deadline'::text, 'Job action required'::text,
      (j.product_type || ' - due ' || coalesce(j.deadline::text,'not set'))::text,
      j.id, j.created_at
    from public.jobs j
    where j.business_id=v_user.business_id and j.technician_id=v_user.id
      and j.status::text not in ('completed','delivered')
    order by j.deadline nulls last;
  end if;
end;
$$;

grant execute on function public.list_inventory_jobs() to authenticated;
grant execute on function public.list_material_requests() to authenticated;
grant execute on function public.list_requestable_inventory() to authenticated;
grant execute on function public.request_job_material(uuid,uuid,numeric,text) to authenticated;
grant execute on function public.review_material_request(uuid,boolean,text) to authenticated;
grant execute on function public.set_my_profile_photo(text) to authenticated;
grant execute on function public.get_role_notifications() to authenticated;
