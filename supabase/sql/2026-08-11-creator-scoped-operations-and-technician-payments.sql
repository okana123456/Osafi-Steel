-- Osafi Steel: creator-scoped Operations Manager workflow, audit stamps and
-- accountant-controlled technician payments.
-- Run this entire file once in the Supabase SQL Editor.

-- `ops_manager` is the business owner. `operations_manager` is a delegated
-- manager who may manage only jobs they personally created.
create or replace function public.osafi_is_manager()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.osafi_has_role('ops_manager')
$$;

create or replace function public.osafi_can_manage_job(p_job_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.jobs j
    join public.users u on u.id = auth.uid()
    where j.id = p_job_id
      and j.business_id = u.business_id
      and coalesce(u.is_active, true)
      and (
        u.role::text = 'ops_manager'
        or (u.role::text = 'operations_manager' and j.created_by = u.id)
      )
  )
$$;

grant execute on function public.osafi_is_manager() to authenticated;
grant execute on function public.osafi_can_manage_job(uuid) to authenticated;

alter table public.jobs
  add column if not exists quote_approved_by uuid references public.users(id),
  add column if not exists quote_approved_at timestamptz,
  add column if not exists production_started_by uuid references public.users(id),
  add column if not exists production_started_at timestamptz;

create table if not exists public.job_audit_log (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  job_id uuid not null references public.jobs(id) on delete cascade,
  actor_id uuid references public.users(id),
  action text not null,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists job_audit_log_job_idx
  on public.job_audit_log(job_id, created_at desc);
alter table public.job_audit_log enable row level security;

drop policy if exists job_audit_log_read on public.job_audit_log;
create policy job_audit_log_read on public.job_audit_log
for select to authenticated
using (
  business_id = public.osafi_my_business()
  and (
    public.osafi_can_manage_job(job_id)
    or public.osafi_has_role('accountant')
    or exists (
      select 1 from public.jobs j
      where j.id = job_id and j.technician_id = auth.uid()
    )
  )
);
revoke insert, update, delete on public.job_audit_log from authenticated;
grant select on public.job_audit_log to authenticated;

-- Remove the former all-jobs Operations Manager rules and replace them with
-- owner-wide / creator-only rules. Technician and accountant policies remain.
drop policy if exists jobs_operations_management_all on public.jobs;
create policy jobs_operations_management_all on public.jobs
for all to authenticated
using (
  business_id = public.osafi_my_business()
  and (
    public.osafi_has_role('ops_manager')
    or (public.osafi_has_role('operations_manager') and created_by = auth.uid())
  )
)
with check (
  business_id = public.osafi_my_business()
  and (
    public.osafi_has_role('ops_manager')
    or (public.osafi_has_role('operations_manager') and created_by = auth.uid())
  )
);

drop policy if exists costing_operations_management_all on public.job_costing;
create policy costing_operations_management_all on public.job_costing
for all to authenticated
using (business_id = public.osafi_my_business() and public.osafi_can_manage_job(job_id))
with check (business_id = public.osafi_my_business() and public.osafi_can_manage_job(job_id));

drop policy if exists job_material_items_management_all on public.job_material_items;
create policy job_material_items_management_all on public.job_material_items
for all to authenticated
using (business_id = public.osafi_my_business() and public.osafi_can_manage_job(job_id))
with check (business_id = public.osafi_my_business() and public.osafi_can_manage_job(job_id));

drop policy if exists checklists_operations_management_all on public.stage_checklists;
create policy checklists_operations_management_all on public.stage_checklists
for all to authenticated
using (business_id = public.osafi_my_business() and public.osafi_can_manage_job(job_id))
with check (business_id = public.osafi_my_business() and public.osafi_can_manage_job(job_id));

drop policy if exists ncrs_operations_management_all on public.ncrs;
create policy ncrs_operations_management_all on public.ncrs
for all to authenticated
using (business_id = public.osafi_my_business() and public.osafi_can_manage_job(job_id))
with check (business_id = public.osafi_my_business() and public.osafi_can_manage_job(job_id));

drop policy if exists deliveries_operations_management_all on public.deliveries;
create policy deliveries_operations_management_all on public.deliveries
for all to authenticated
using (business_id = public.osafi_my_business() and public.osafi_can_manage_job(job_id))
with check (business_id = public.osafi_my_business() and public.osafi_can_manage_job(job_id));

drop policy if exists invoices_operations_management_all on public.invoices;
create policy invoices_operations_management_all on public.invoices
for all to authenticated
using (business_id = public.osafi_my_business() and public.osafi_can_manage_job(job_id))
with check (business_id = public.osafi_my_business() and public.osafi_can_manage_job(job_id));

drop policy if exists attachments_operations_management_all on public.job_attachments;
create policy attachments_operations_management_all on public.job_attachments
for all to authenticated
using (business_id = public.osafi_my_business() and public.osafi_can_manage_job(job_id))
with check (business_id = public.osafi_my_business() and public.osafi_can_manage_job(job_id));

drop policy if exists messages_operations_management_all on public.job_messages;
create policy messages_operations_management_all on public.job_messages
for all to authenticated
using (business_id = public.osafi_my_business() and public.osafi_can_manage_job(job_id))
with check (business_id = public.osafi_my_business() and public.osafi_can_manage_job(job_id));

drop policy if exists complaints_operations_management_all on public.complaints;
create policy complaints_operations_management_all on public.complaints
for all to authenticated
using (business_id = public.osafi_my_business() and public.osafi_can_manage_job(job_id))
with check (business_id = public.osafi_my_business() and public.osafi_can_manage_job(job_id));

drop policy if exists stage_requests_operations_management_all on public.job_stage_approval_requests;
create policy stage_requests_operations_management_all on public.job_stage_approval_requests
for all to authenticated
using (business_id = public.osafi_my_business() and public.osafi_can_manage_job(job_id))
with check (business_id = public.osafi_my_business() and public.osafi_can_manage_job(job_id));

drop policy if exists ncr_requests_operations_management_all on public.ncr_approval_requests;
create policy ncr_requests_operations_management_all on public.ncr_approval_requests
for all to authenticated
using (business_id = public.osafi_my_business() and public.osafi_can_manage_job(job_id))
with check (business_id = public.osafi_my_business() and public.osafi_can_manage_job(job_id));

drop policy if exists technician_quotes_access on public.technician_quotes;
create policy technician_quotes_access on public.technician_quotes
for select to authenticated
using (
  business_id = public.osafi_my_business()
  and (
    technician_id = auth.uid()
    or public.osafi_can_manage_job(job_id)
    or public.osafi_has_role('accountant')
  )
);

-- Storage paths are business/job/file. Keep job media under the same creator
-- or assigned-technician boundary as the database attachment rows.
drop policy if exists job_photos_read on storage.objects;
create policy job_photos_read on storage.objects
for select to authenticated
using (
  bucket_id='job-photos'
  and (storage.foldername(name))[1]=public.osafi_my_business()::text
  and exists (
    select 1 from public.jobs j
    where j.id::text=(storage.foldername(name))[2]
      and (public.osafi_can_manage_job(j.id) or j.technician_id=auth.uid())
  )
);
drop policy if exists job_photos_upload on storage.objects;
create policy job_photos_upload on storage.objects
for insert to authenticated
with check (
  bucket_id='job-photos'
  and (storage.foldername(name))[1]=public.osafi_my_business()::text
  and exists (
    select 1 from public.jobs j
    where j.id::text=(storage.foldername(name))[2]
      and (public.osafi_can_manage_job(j.id) or j.technician_id=auth.uid())
  )
);

-- Separate customer receipt from technician settlement. The agreed labour
-- value is copied into the payment record for a stable accounting audit.
create table if not exists public.technician_payments (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  job_id uuid not null unique references public.jobs(id) on delete cascade,
  technician_id uuid not null references public.users(id),
  amount numeric(14,2) not null check (amount >= 0),
  status text not null default 'pending' check (status in ('pending','paid')),
  paid_by uuid references public.users(id),
  paid_at timestamptz,
  payment_reference text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists technician_payments_business_status_idx
  on public.technician_payments(business_id, status, created_at desc);
alter table public.technician_payments enable row level security;

drop policy if exists technician_payments_read on public.technician_payments;
create policy technician_payments_read on public.technician_payments
for select to authenticated
using (
  business_id = public.osafi_my_business()
  and (
    public.osafi_has_role('ops_manager','accountant')
    or technician_id = auth.uid()
    or (public.osafi_has_role('operations_manager') and public.osafi_can_manage_job(job_id))
  )
);
revoke insert, update, delete on public.technician_payments from authenticated;
grant select on public.technician_payments to authenticated;

create or replace function public.osafi_sync_technician_payment(p_job_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_job public.jobs%rowtype;
  v_amount numeric;
begin
  select * into v_job from public.jobs where id = p_job_id;
  if v_job.id is null or v_job.technician_id is null or v_job.completed_at is null then return; end if;
  if not exists (
    select 1 from public.invoices i
    where i.job_id = p_job_id and i.status::text = 'paid'
  ) then return; end if;
  select agreed_amount into v_amount
  from public.technician_quotes where job_id = p_job_id;
  if coalesce(v_amount, 0) <= 0 then return; end if;

  insert into public.technician_payments(
    business_id, job_id, technician_id, amount, status, updated_at
  ) values (
    v_job.business_id, v_job.id, v_job.technician_id, v_amount, 'pending', now()
  )
  on conflict (job_id) do update set
    technician_id = excluded.technician_id,
    amount = case when public.technician_payments.status = 'pending' then excluded.amount else public.technician_payments.amount end,
    updated_at = now();
end;
$$;
revoke all on function public.osafi_sync_technician_payment(uuid) from public;

create or replace function public.advance_job_by_manager(p_job_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_job public.jobs%rowtype;
begin
  select * into v_job from public.jobs where id = p_job_id for update;
  if v_job.id is null or not public.osafi_can_manage_job(p_job_id) then
    raise exception 'You can only advance jobs you are permitted to manage';
  end if;
  if v_job.status::text = 'quoted' then
    update public.jobs set status='approved',quote_approved_by=auth.uid(),quote_approved_at=now()
    where id=p_job_id;
    insert into public.job_audit_log(business_id,job_id,actor_id,action)
    values(v_job.business_id,p_job_id,auth.uid(),'quote_approved');
  elsif v_job.status::text = 'approved' then
    update public.jobs set status='in_production',current_stage='cutting',
      production_started_by=auth.uid(),production_started_at=coalesce(production_started_at,now())
    where id=p_job_id;
    insert into public.job_audit_log(business_id,job_id,actor_id,action)
    values(v_job.business_id,p_job_id,auth.uid(),'production_started');
  else
    raise exception 'This job cannot be advanced from its current status';
  end if;
end;
$$;

create or replace function public.mark_technician_paid(
  p_payment_id uuid,
  p_reference text default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_user public.users%rowtype; v_payment public.technician_payments%rowtype;
begin
  select * into v_user from public.users where id=auth.uid();
  select * into v_payment from public.technician_payments where id=p_payment_id for update;
  if v_user.id is null or v_user.role::text not in ('ops_manager','accountant') then
    raise exception 'Only the accountant or business owner can pay a technician';
  end if;
  if v_payment.id is null or v_payment.business_id <> v_user.business_id then
    raise exception 'Technician payment not found for this business';
  end if;
  if v_payment.status = 'paid' then raise exception 'This technician has already been paid'; end if;
  update public.technician_payments set status='paid',paid_by=auth.uid(),paid_at=now(),
    payment_reference=nullif(trim(p_reference),''),updated_at=now()
  where id=p_payment_id;
  insert into public.job_audit_log(business_id,job_id,actor_id,action,details)
  values(v_payment.business_id,v_payment.job_id,auth.uid(),'technician_paid',
    jsonb_build_object('amount',v_payment.amount,'reference',nullif(trim(p_reference),'')));
end;
$$;

grant execute on function public.advance_job_by_manager(uuid) to authenticated;
grant execute on function public.mark_technician_paid(uuid,text) to authenticated;

create or replace function public.osafi_audit_job_created()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.job_audit_log(business_id,job_id,actor_id,action)
  values(new.business_id,new.id,new.created_by,'job_created');
  return new;
end;
$$;
drop trigger if exists osafi_audit_job_created on public.jobs;
create trigger osafi_audit_job_created
after insert on public.jobs
for each row execute function public.osafi_audit_job_created();

-- Restrict agreed labour changes to the owner or creator of the job.
create or replace function public.set_agreed_labour_quote(p_job_id uuid,p_amount numeric)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_user public.users%rowtype; v_job public.jobs%rowtype;
begin
  select * into v_user from public.users where id=auth.uid();
  select * into v_job from public.jobs where id=p_job_id;
  if v_job.id is null or not public.osafi_can_manage_job(p_job_id) then
    raise exception 'You can only agree labour for jobs you manage';
  end if;
  if v_job.technician_id is null then return; end if;
  if p_amount is null or p_amount < 0 then raise exception 'Enter a valid labour price'; end if;
  insert into public.technician_quotes(business_id,job_id,technician_id,agreed_amount,status,updated_at)
  values(v_user.business_id,p_job_id,v_job.technician_id,p_amount,'agreed',now())
  on conflict(job_id) do update set technician_id=excluded.technician_id,
    agreed_amount=excluded.agreed_amount,status='agreed',updated_at=now();
  insert into public.job_audit_log(business_id,job_id,actor_id,action,details)
  values(v_job.business_id,p_job_id,auth.uid(),'labour_agreed',jsonb_build_object('amount',p_amount));
  perform public.osafi_sync_technician_payment(p_job_id);
end;
$$;

-- Restrict costing changes to the owner or creator. Existing item validation,
-- generated totals and quotation calculation remain unchanged.
create or replace function public.save_job_costing_with_materials(
  p_job_id uuid,
  p_materials_cost numeric,
  p_labor_cost numeric,
  p_overhead_cost numeric,
  p_margin_percent numeric,
  p_material_items jsonb default '[]'::jsonb
) returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user public.users%rowtype;
  v_job public.jobs%rowtype;
  v_materials numeric := greatest(coalesce(p_materials_cost, 0), 0);
  v_labor numeric := greatest(coalesce(p_labor_cost, 0), 0);
  v_overhead numeric := greatest(coalesce(p_overhead_cost, 0), 0);
  v_margin numeric := greatest(coalesce(p_margin_percent, 0), 0);
  v_item_total numeric := 0;
  v_selling numeric;
begin
  select * into v_user from public.users where id = auth.uid();
  select * into v_job from public.jobs where id = p_job_id;
  if v_user.id is null or coalesce(v_user.is_active, true) is false
     or v_job.id is null or not public.osafi_can_manage_job(p_job_id) then
    raise exception 'You can only cost jobs you manage';
  end if;
  delete from public.job_material_items where job_id = p_job_id;
  v_item_total := public.osafi_insert_material_items(v_user.business_id,p_job_id,coalesce(p_material_items,'[]'::jsonb));
  if jsonb_array_length(coalesce(p_material_items,'[]'::jsonb)) > 0 then v_materials := v_item_total; end if;
  v_selling := round((v_materials+v_labor+v_overhead)*(1+v_margin/100),2);
  insert into public.job_costing(business_id,job_id,materials_cost,labor_cost,overhead_cost,margin_percent)
  values(v_user.business_id,p_job_id,v_materials,v_labor,v_overhead,v_margin)
  on conflict(job_id) do update set materials_cost=excluded.materials_cost,labor_cost=excluded.labor_cost,
    overhead_cost=excluded.overhead_cost,margin_percent=excluded.margin_percent,updated_at=now();
  update public.jobs set quoted_price=v_selling where id=p_job_id;
  insert into public.job_audit_log(business_id,job_id,actor_id,action,details)
  values(v_job.business_id,p_job_id,auth.uid(),'quotation_updated',jsonb_build_object('total',v_selling));
  return v_selling;
end;
$$;

-- Approval RPCs now enforce creator ownership and retain the named reviewer.
create or replace function public.approve_stage_submission(p_checklist_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_req public.job_stage_approval_requests%rowtype;
  v_stage public.job_stage;
  v_next public.job_stage;
begin
  select * into v_req from public.job_stage_approval_requests where id=p_checklist_id for update;
  if v_req.id is null or not public.osafi_can_manage_job(v_req.job_id) then
    raise exception 'You can only approve stages for jobs you manage';
  end if;
  if v_req.status <> 'pending' then raise exception 'This request is not pending'; end if;
  if v_req.stage not in ('cutting','welding','finishing','qc') then raise exception 'Invalid production stage'; end if;
  v_stage := v_req.stage::public.job_stage;
  v_next := case v_stage when 'cutting' then 'welding' when 'welding' then 'finishing' when 'finishing' then 'qc' else 'done' end;
  insert into public.stage_checklists(business_id,job_id,technician_id,stage,checklist_answers,result,notes)
  values(v_req.business_id,v_req.job_id,v_req.requested_by,v_stage,coalesce(v_req.answers,'[]'::jsonb),'pass',v_req.notes);
  update public.job_stage_approval_requests set status='approved',reviewed_by=auth.uid(),reviewed_at=now() where id=p_checklist_id;
  update public.jobs set current_stage=v_next,status=case when v_next='done' then 'completed' when v_next='qc' then 'qc' else 'in_production' end,
    completed_at=case when v_next='done' then now() else completed_at end where id=v_req.job_id;
  insert into public.job_audit_log(business_id,job_id,actor_id,action,details)
  values(v_req.business_id,v_req.job_id,auth.uid(),'stage_approved',jsonb_build_object('stage',v_req.stage,'next_stage',v_next::text));
  perform public.osafi_sync_technician_payment(v_req.job_id);
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
  v_failed public.job_stage;
  v_reopened public.job_stage;
begin
  select * into v_req from public.ncr_approval_requests where id=p_ncr_id for update;
  if v_req.id is null or not public.osafi_can_manage_job(v_req.job_id) then
    raise exception 'You can only approve NCRs for jobs you manage';
  end if;
  if v_req.status <> 'pending' then raise exception 'This NCR request is not pending'; end if;
  if v_req.reopened_stage not in ('cutting','welding','finishing','qc') then raise exception 'Invalid reopened stage'; end if;
  if coalesce(v_req.stage_failed_at,'') not in ('cutting','welding','finishing','qc') then raise exception 'Invalid failed stage'; end if;
  v_failed := v_req.stage_failed_at::public.job_stage;
  v_reopened := v_req.reopened_stage::public.job_stage;
  insert into public.ncrs(business_id,job_id,category,stage_failed_at,root_cause,corrective_action,reopened_at_stage,reopened_stage,status)
  values(v_req.business_id,v_req.job_id,v_req.category,v_failed,v_req.root_cause,v_req.corrective_action,v_reopened,v_reopened::text,'open');
  update public.ncr_approval_requests set status='approved',reviewed_by=auth.uid(),reviewed_at=now() where id=p_ncr_id;
  update public.jobs set status='rework',current_stage=v_reopened where id=v_req.job_id;
  insert into public.job_audit_log(business_id,job_id,actor_id,action,details)
  values(v_req.business_id,v_req.job_id,auth.uid(),'ncr_approved',jsonb_build_object('failed_stage',v_failed::text,'reopened_stage',v_reopened::text));
end;
$$;

-- Customer payment remains separate. When both completion and customer payment
-- are true, a pending technician payment is generated automatically.
create or replace function public.set_invoice_paid_status(p_invoice_id uuid,p_paid boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_user public.users%rowtype; v_invoice public.invoices%rowtype;
begin
  select * into v_user from public.users where id=auth.uid();
  select * into v_invoice from public.invoices where id=p_invoice_id for update;
  if v_invoice.id is null or v_invoice.business_id <> v_user.business_id then raise exception 'Invoice not found for this business'; end if;
  if v_user.role::text not in ('ops_manager','accountant')
     and not (v_user.role::text='operations_manager' and public.osafi_can_manage_job(v_invoice.job_id)) then
    raise exception 'You cannot update payment for this invoice';
  end if;
  if not coalesce(p_paid,false) and exists(select 1 from public.technician_payments p where p.job_id=v_invoice.job_id and p.status='paid') then
    raise exception 'Customer payment cannot be reversed after the technician has been paid';
  end if;
  update public.invoices set status=case when coalesce(p_paid,false) then 'paid' else 'unpaid' end where id=p_invoice_id;
  insert into public.job_audit_log(business_id,job_id,actor_id,action)
  values(v_invoice.business_id,v_invoice.job_id,auth.uid(),case when coalesce(p_paid,false) then 'customer_invoice_paid' else 'customer_invoice_reopened' end);
  if coalesce(p_paid,false) then perform public.osafi_sync_technician_payment(v_invoice.job_id); end if;
end;
$$;

-- Invoice creation follows the same creator ownership rule. Accountants and the
-- owner retain workshop-wide billing access.
create or replace function public.create_customer_invoice(p_job_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user public.users%rowtype;
  v_job public.jobs%rowtype;
  v_cost public.job_costing%rowtype;
  v_invoice public.invoices%rowtype;
  v_amount numeric;
begin
  select * into v_user from public.users where id=auth.uid();
  select * into v_job from public.jobs where id=p_job_id;
  if v_user.id is null or v_job.id is null or v_job.business_id <> v_user.business_id then
    raise exception 'Job not found in this business';
  end if;
  if v_user.role::text not in ('ops_manager','accountant')
     and not (v_user.role::text='operations_manager' and public.osafi_can_manage_job(p_job_id)) then
    raise exception 'You can only invoice jobs you are permitted to manage';
  end if;
  select * into v_cost from public.job_costing where job_id=p_job_id;
  v_amount := coalesce(nullif(v_cost.selling_price,0),nullif(v_job.quoted_price,0),0);
  if v_amount <= 0 then raise exception 'Save a valid quotation before invoicing'; end if;
  select * into v_invoice from public.invoices where job_id=p_job_id order by created_at desc limit 1;
  if v_invoice.id is null then
    insert into public.invoices(business_id,job_id,total,status)
    values(v_user.business_id,p_job_id,v_amount,'unpaid') returning * into v_invoice;
    insert into public.job_audit_log(business_id,job_id,actor_id,action,details)
    values(v_job.business_id,p_job_id,auth.uid(),'invoice_created',jsonb_build_object('total',v_amount));
  else
    update public.invoices set total=v_amount where id=v_invoice.id returning * into v_invoice;
  end if;
  update public.jobs set quoted_price=v_amount where id=p_job_id;
  return v_invoice.id;
end;
$$;

-- Backfill currently eligible completed-and-paid jobs without changing any
-- existing paid technician record.
do $$
declare v_job record;
begin
  for v_job in
    select distinct j.id from public.jobs j
    join public.invoices i on i.job_id=j.id and i.status::text='paid'
    where j.completed_at is not null
  loop
    perform public.osafi_sync_technician_payment(v_job.id);
  end loop;
end;
$$;

grant execute on function public.set_agreed_labour_quote(uuid,numeric) to authenticated;
grant execute on function public.save_job_costing_with_materials(uuid,numeric,numeric,numeric,numeric,jsonb) to authenticated;
grant execute on function public.approve_stage_submission(uuid) to authenticated;
grant execute on function public.approve_ncr(uuid) to authenticated;
grant execute on function public.set_invoice_paid_status(uuid,boolean) to authenticated;
grant execute on function public.create_customer_invoice(uuid) to authenticated;
