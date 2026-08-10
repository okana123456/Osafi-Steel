-- Osafi Steel: fix invalid triggers/NCR enum casts, add departments and labour quotes.
-- Run this entire file once in Supabase SQL Editor.

alter type public.app_role add value if not exists 'operations_manager';
alter type public.app_role add value if not exists 'store_manager';
alter type public.app_role add value if not exists 'accountant';

-- Remove only triggers that reference NEW.technician_id on tables where that
-- field does not exist. Such triggers can never execute successfully and caused
-- the "record new has no field technician_id" error during job creation/costing.
do $$
declare r record;
begin
  for r in
    select ns.nspname as schema_name, c.relname as table_name, t.tgname as trigger_name
    from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    join pg_namespace ns on ns.oid = c.relnamespace
    join pg_proc p on p.oid = t.tgfoid
    where not t.tgisinternal
      and ns.nspname = 'public'
      and lower(pg_get_functiondef(p.oid)) ~ 'new[[:space:]]*\.[[:space:]]*technician_id'
      and not exists (
        select 1 from pg_attribute a
        where a.attrelid = c.oid and a.attname = 'technician_id' and not a.attisdropped
      )
  loop
    execute format('drop trigger if exists %I on %I.%I', r.trigger_name, r.schema_name, r.table_name);
  end loop;
end $$;

create or replace function public.osafi_has_role(variadic allowed_roles text[])
returns boolean language sql stable security definer set search_path = public as $$
  select exists(
    select 1 from public.users
    where id = auth.uid() and role::text = any(allowed_roles)
  )
$$;

create or replace function public.osafi_is_manager()
returns boolean language sql stable security definer set search_path = public as $$
  select public.osafi_has_role('ops_manager','operations_manager')
$$;

create table if not exists public.technician_quotes (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  job_id uuid not null unique references public.jobs(id) on delete cascade,
  technician_id uuid not null references public.users(id),
  proposed_amount numeric check (proposed_amount is null or proposed_amount >= 0),
  agreed_amount numeric check (agreed_amount is null or agreed_amount >= 0),
  notes text,
  status text not null default 'submitted' check (status in ('submitted','agreed')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.technician_quotes enable row level security;
drop policy if exists technician_quotes_access on public.technician_quotes;
create policy technician_quotes_access on public.technician_quotes for select
using (
  business_id = public.osafi_my_business()
  and (
    public.osafi_has_role('ops_manager','operations_manager')
    or technician_id = auth.uid()
  )
);
drop policy if exists technician_quotes_submit on public.technician_quotes;
drop policy if exists technician_quotes_technician_update on public.technician_quotes;
drop policy if exists technician_quotes_manager_update on public.technician_quotes;
revoke insert, update, delete on public.technician_quotes from authenticated;

create or replace function public.submit_technician_quote(
  p_job_id uuid,
  p_amount numeric,
  p_notes text default null
) returns void
language plpgsql security definer set search_path = public as $$
declare v_user public.users%rowtype; v_job public.jobs%rowtype;
begin
  select * into v_user from public.users where id=auth.uid();
  select * into v_job from public.jobs where id=p_job_id;
  if v_user.role::text <> 'technician' or v_job.technician_id <> auth.uid()
     or v_job.business_id <> v_user.business_id then
    raise exception 'Only the assigned technician can submit this quote';
  end if;
  if p_amount is null or p_amount < 0 then raise exception 'Enter a valid labour price'; end if;
  insert into public.technician_quotes(business_id,job_id,technician_id,proposed_amount,agreed_amount,notes,status,updated_at)
  values(v_user.business_id,p_job_id,auth.uid(),p_amount,null,nullif(trim(p_notes),''),'submitted',now())
  on conflict(job_id) do update set technician_id=excluded.technician_id,
    proposed_amount=excluded.proposed_amount,agreed_amount=null,
    notes=excluded.notes,status='submitted',updated_at=now();
end;
$$;

create or replace function public.set_agreed_labour_quote(p_job_id uuid,p_amount numeric)
returns void
language plpgsql security definer set search_path = public as $$
declare v_user public.users%rowtype; v_job public.jobs%rowtype;
begin
  select * into v_user from public.users where id=auth.uid();
  select * into v_job from public.jobs where id=p_job_id;
  if v_user.role::text not in ('ops_manager','operations_manager')
     or v_job.business_id <> v_user.business_id then
    raise exception 'Only management can agree the labour price';
  end if;
  if v_job.technician_id is null then return; end if;
  if p_amount is null or p_amount < 0 then raise exception 'Enter a valid labour price'; end if;
  insert into public.technician_quotes(business_id,job_id,technician_id,agreed_amount,status,updated_at)
  values(v_user.business_id,p_job_id,v_job.technician_id,p_amount,'agreed',now())
  on conflict(job_id) do update set technician_id=excluded.technician_id,
    agreed_amount=excluded.agreed_amount,status='agreed',updated_at=now();
end;
$$;

create or replace function public.create_job_with_costing(
  p_customer_id uuid,
  p_technician_id uuid,
  p_product_type text,
  p_dimensions text,
  p_finish text,
  p_fulfilment text,
  p_deadline date,
  p_quoted_price numeric,
  p_materials_cost numeric,
  p_labor_cost numeric,
  p_overhead_cost numeric,
  p_margin_percent numeric
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_user public.users%rowtype;
  v_job_id uuid;
  v_total numeric;
  v_selling numeric;
begin
  select * into v_user from public.users where id=auth.uid();
  if v_user.role::text not in ('ops_manager','operations_manager') then
    raise exception 'Only management can create jobs';
  end if;
  if not exists(select 1 from public.customers c where c.id=p_customer_id and c.business_id=v_user.business_id) then
    raise exception 'Customer not found';
  end if;
  if not exists(select 1 from public.users u where u.id=p_technician_id and u.business_id=v_user.business_id and u.role::text='technician') then
    raise exception 'Choose a technician from this business';
  end if;
  v_total := greatest(coalesce(p_materials_cost,0),0)
    + greatest(coalesce(p_labor_cost,0),0)
    + greatest(coalesce(p_overhead_cost,0),0);
  v_selling := round(v_total * (1 + greatest(coalesce(p_margin_percent,0),0) / 100), 2);
  insert into public.jobs(
    business_id,customer_id,technician_id,product_type,dimensions,finish,
    delivery_or_collection,deadline,quoted_price,status,created_by
  ) values (
    v_user.business_id,p_customer_id,p_technician_id,trim(p_product_type),trim(p_dimensions),trim(p_finish),
    p_fulfilment,p_deadline,v_selling,'quoted',auth.uid()
  ) returning id into v_job_id;
  insert into public.job_costing(job_id,materials_cost,labor_cost,overhead_cost,total_cost,margin_percent,selling_price)
  values(v_job_id,greatest(coalesce(p_materials_cost,0),0),greatest(coalesce(p_labor_cost,0),0),
    greatest(coalesce(p_overhead_cost,0),0),v_total,greatest(coalesce(p_margin_percent,0),0),v_selling);
  return v_job_id;
end;
$$;

create or replace function public.approve_stage_submission(p_checklist_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare v_req public.job_stage_approval_requests%rowtype; v_user public.users%rowtype; v_next text;
begin
  select * into v_user from public.users where id=auth.uid();
  select * into v_req from public.job_stage_approval_requests where id=p_checklist_id;
  if v_req.id is null or v_user.business_id<>v_req.business_id
     or v_user.role::text not in ('ops_manager','operations_manager') then
    raise exception 'Only an operations manager can approve this work';
  end if;
  if v_req.status<>'pending' then raise exception 'This request is not pending'; end if;
  v_next:=case v_req.stage when 'cutting' then 'welding' when 'welding' then 'finishing'
    when 'finishing' then 'qc' when 'qc' then 'done' else 'done' end;
  insert into public.stage_checklists(job_id,technician_id,stage,checklist_answers,result,notes)
  values(v_req.job_id,v_req.requested_by,v_req.stage,v_req.answers,'pass',v_req.notes);
  update public.job_stage_approval_requests set status='approved',reviewed_by=auth.uid(),reviewed_at=now()
  where id=p_checklist_id;
  update public.jobs set current_stage=v_next::public.job_stage,
    status=case when v_next='done' then 'completed' else 'in_production' end,
    completed_at=case when v_next='done' then now() else completed_at end
  where id=v_req.job_id;
end;
$$;

-- Store department access.
drop policy if exists inventory_store_access on public.inventory_items;
create policy inventory_store_access on public.inventory_items for all
using (business_id = public.osafi_my_business() and public.osafi_has_role('ops_manager','store_manager'))
with check (business_id = public.osafi_my_business() and public.osafi_has_role('ops_manager','store_manager'));
drop policy if exists inventory_moves_store_access on public.inventory_moves;
create policy inventory_moves_store_access on public.inventory_moves for all
using (business_id = public.osafi_my_business() and public.osafi_has_role('ops_manager','store_manager'))
with check (business_id = public.osafi_my_business() and public.osafi_has_role('ops_manager','store_manager'));

drop policy if exists suppliers_manager_access on public.suppliers;
create policy suppliers_manager_access on public.suppliers for all
using (business_id = public.osafi_my_business() and public.osafi_has_role('ops_manager','store_manager'))
with check (business_id = public.osafi_my_business() and public.osafi_has_role('ops_manager','store_manager'));
drop policy if exists purchase_orders_manager_access on public.purchase_orders;
create policy purchase_orders_manager_access on public.purchase_orders for all
using (business_id = public.osafi_my_business() and public.osafi_has_role('ops_manager','store_manager'))
with check (business_id = public.osafi_my_business() and public.osafi_has_role('ops_manager','store_manager'));
drop policy if exists purchase_items_manager_access on public.purchase_order_items;
create policy purchase_items_manager_access on public.purchase_order_items for all
using (exists(select 1 from public.purchase_orders po where po.id = purchase_order_id and po.business_id = public.osafi_my_business() and public.osafi_has_role('ops_manager','store_manager')))
with check (exists(select 1 from public.purchase_orders po where po.id = purchase_order_id and po.business_id = public.osafi_my_business() and public.osafi_has_role('ops_manager','store_manager')));
drop policy if exists supplier_documents_manager_access on public.supplier_documents;
create policy supplier_documents_manager_access on public.supplier_documents for all
using (business_id = public.osafi_my_business() and public.osafi_has_role('ops_manager','store_manager','accountant'))
with check (business_id = public.osafi_my_business() and public.osafi_has_role('ops_manager','store_manager','accountant'));
drop policy if exists accountant_suppliers_read on public.suppliers;
create policy accountant_suppliers_read on public.suppliers for select
using (business_id = public.osafi_my_business() and public.osafi_has_role('ops_manager','accountant'));
drop policy if exists accountant_purchase_orders_read on public.purchase_orders;
create policy accountant_purchase_orders_read on public.purchase_orders for select
using (business_id = public.osafi_my_business() and public.osafi_has_role('ops_manager','accountant'));

-- Accounting department access.
drop policy if exists customers_management_access on public.customers;
create policy customers_management_access on public.customers for all
using (
  customers.business_id = public.osafi_my_business()
  and public.osafi_has_role('ops_manager','operations_manager')
)
with check (
  customers.business_id = public.osafi_my_business()
  and public.osafi_has_role('ops_manager','operations_manager')
);
drop policy if exists accounting_manager_access on public.accounting_entries;
create policy accounting_manager_access on public.accounting_entries for all
using (business_id = public.osafi_my_business() and public.osafi_has_role('ops_manager','accountant'))
with check (business_id = public.osafi_my_business() and public.osafi_has_role('ops_manager','accountant'));
drop policy if exists accountant_jobs_read on public.jobs;
create policy accountant_jobs_read on public.jobs for select
using (business_id = public.osafi_my_business() and public.osafi_has_role('ops_manager','accountant'));
drop policy if exists accountant_customers_read on public.customers;
create policy accountant_customers_read on public.customers for select
using (business_id = public.osafi_my_business() and public.osafi_has_role('ops_manager','accountant'));
drop policy if exists accountant_invoices_access on public.invoices;
create policy accountant_invoices_access on public.invoices for all
using (exists(select 1 from public.jobs j where j.id=invoices.job_id and j.business_id=public.osafi_my_business() and public.osafi_has_role('ops_manager','accountant')))
with check (exists(select 1 from public.jobs j where j.id=invoices.job_id and j.business_id=public.osafi_my_business() and public.osafi_has_role('ops_manager','accountant')));

create or replace function public.set_invoice_paid_status(p_invoice_id uuid, p_paid boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user public.users%rowtype;
  v_invoice public.invoices%rowtype;
  v_business_id uuid;
begin
  select * into v_user from public.users where id = auth.uid();
  if v_user.id is null or v_user.role::text not in ('ops_manager','accountant') then
    raise exception 'Only the Administrator or Accountant can update invoice payments';
  end if;
  select * into v_invoice from public.invoices where id = p_invoice_id;
  if v_invoice.id is not null then
    select business_id into v_business_id from public.jobs where id = v_invoice.job_id;
  end if;
  if v_invoice.id is null or v_business_id is null or v_business_id <> v_user.business_id then
    raise exception 'Invoice not found for this business';
  end if;
  if coalesce(p_paid,false) then
    update public.invoices set status = 'paid' where id = p_invoice_id;
  else
    update public.invoices set status = 'unpaid' where id = p_invoice_id;
  end if;
end;
$$;

-- Fraud-prevention checks: existing incomplete suppliers remain readable, but
-- every new or edited supplier must have all identity/contact fields completed.
alter table public.suppliers drop constraint if exists suppliers_complete_details;
alter table public.suppliers add constraint suppliers_complete_details check (
  length(trim(coalesce(name,''))) > 0 and length(trim(coalesce(contact_person,''))) > 0
  and length(trim(coalesce(email,''))) > 0 and length(trim(coalesce(phone,''))) > 0
  and length(trim(coalesce(address,''))) > 0 and length(trim(coalesce(tax_number,''))) > 0
) not valid;

create or replace function public.move_inventory_department(
  p_item_id uuid,
  p_direction text,
  p_qty numeric,
  p_job_id uuid default null,
  p_notes text default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user public.users%rowtype;
  v_item public.inventory_items%rowtype;
begin
  select * into v_user from public.users where id = auth.uid();
  select * into v_item from public.inventory_items where id = p_item_id for update;
  if v_item.id is null or v_item.business_id <> v_user.business_id
     or v_user.role::text not in ('ops_manager','store_manager') then
    raise exception 'Only the Store Manager or Administrator can move inventory';
  end if;
  if p_direction not in ('in','out') or p_qty is null or p_qty <= 0 then
    raise exception 'Enter a valid stock direction and quantity';
  end if;
  if p_direction = 'out' and v_item.qty_on_hand < p_qty then
    raise exception 'Not enough stock available';
  end if;
  update public.inventory_items
  set qty_on_hand = qty_on_hand + case when p_direction = 'in' then p_qty else -p_qty end
  where id = p_item_id;
  insert into public.inventory_moves(business_id,item_id,job_id,direction,qty,notes)
  values (v_user.business_id,p_item_id,p_job_id,p_direction,p_qty,nullif(trim(p_notes),''));
end;
$$;

create or replace function public.create_purchase_order(
  p_supplier_id uuid,
  p_order_number text,
  p_order_date date,
  p_expected_date date,
  p_tax numeric,
  p_notes text,
  p_items jsonb
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user public.users%rowtype;
  v_supplier public.suppliers%rowtype;
  v_order_id uuid;
  v_subtotal numeric;
  v_item jsonb;
begin
  select * into v_user from public.users where id = auth.uid();
  if v_user.id is null or v_user.role::text not in ('ops_manager','store_manager') then
    raise exception 'Only the Store Manager or Administrator can create purchases';
  end if;
  select * into v_supplier from public.suppliers where id = p_supplier_id;
  if v_supplier.id is null or v_supplier.business_id <> v_user.business_id then raise exception 'Supplier not found'; end if;
  if jsonb_array_length(coalesce(p_items,'[]'::jsonb)) = 0 then raise exception 'Add at least one purchase item'; end if;
  select coalesce(sum((x->>'quantity')::numeric * (x->>'unit_cost')::numeric),0)
  into v_subtotal from jsonb_array_elements(p_items) x;
  insert into public.purchase_orders(
    business_id,supplier_id,order_number,order_date,expected_date,status,
    subtotal,tax,total,notes,created_by
  ) values (
    v_user.business_id,p_supplier_id,trim(p_order_number),coalesce(p_order_date,current_date),
    p_expected_date,'ordered',v_subtotal,greatest(coalesce(p_tax,0),0),
    v_subtotal + greatest(coalesce(p_tax,0),0),nullif(trim(p_notes),''),auth.uid()
  ) returning id into v_order_id;
  for v_item in select * from jsonb_array_elements(p_items)
  loop
    if (v_item->>'quantity')::numeric <= 0 or (v_item->>'unit_cost')::numeric < 0 then raise exception 'Purchase quantities and costs are invalid'; end if;
    if not exists(select 1 from public.inventory_items i where i.id=(v_item->>'inventory_item_id')::uuid and i.business_id=v_user.business_id) then raise exception 'Inventory item not found'; end if;
    insert into public.purchase_order_items(purchase_order_id,inventory_item_id,description,quantity,unit_cost,line_total)
    values (v_order_id,(v_item->>'inventory_item_id')::uuid,trim(v_item->>'description'),
      (v_item->>'quantity')::numeric,(v_item->>'unit_cost')::numeric,
      (v_item->>'quantity')::numeric*(v_item->>'unit_cost')::numeric);
  end loop;
  return v_order_id;
end;
$$;

create or replace function public.receive_purchase_order(p_purchase_order_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user public.users%rowtype;
  v_order public.purchase_orders%rowtype;
  v_line record;
begin
  select * into v_user from public.users where id = auth.uid();
  select * into v_order from public.purchase_orders where id=p_purchase_order_id for update;
  if v_order.id is null or v_order.business_id <> v_user.business_id
     or v_user.role::text not in ('ops_manager','store_manager') then
    raise exception 'Only the Store Manager or Administrator can receive this purchase';
  end if;
  if v_order.status='received' then raise exception 'This purchase was already received'; end if;
  if v_order.status='cancelled' then raise exception 'A cancelled purchase cannot be received'; end if;
  for v_line in select * from public.purchase_order_items where purchase_order_id=v_order.id
  loop
    perform public.move_inventory_department(v_line.inventory_item_id,'in',v_line.quantity,null,'Purchase order '||v_order.order_number);
  end loop;
  update public.purchase_orders set status='received',received_by=auth.uid(),received_at=now() where id=v_order.id;
end;
$$;

-- Fix enum mismatch when an Operations Manager approves an NCR.
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
  if v_req.id is null or v_user.business_id <> v_req.business_id
     or v_user.role::text not in ('ops_manager','operations_manager') then
    raise exception 'Only an operations manager can approve NCRs';
  end if;
  if v_req.status <> 'pending' then raise exception 'This NCR request is not pending'; end if;
  insert into public.ncrs(
    business_id, job_id, category, stage_failed_at, root_cause,
    corrective_action, reopened_at_stage, reopened_stage, status
  ) values (
    v_req.business_id, v_req.job_id, v_req.category,
    v_req.stage_failed_at::public.job_stage, v_req.root_cause,
    v_req.corrective_action, v_req.reopened_stage, v_req.reopened_stage, 'open'
  );
  update public.ncr_approval_requests
  set status = 'approved', reviewed_by = auth.uid(), reviewed_at = now()
  where id = p_ncr_id;
  update public.jobs
  set status = 'rework', current_stage = v_req.reopened_stage::public.job_stage
  where id = v_req.job_id;
end;
$$;

grant execute on function public.osafi_has_role(variadic text[]) to authenticated;
grant execute on function public.submit_technician_quote(uuid,numeric,text) to authenticated;
grant execute on function public.set_agreed_labour_quote(uuid,numeric) to authenticated;
grant execute on function public.create_job_with_costing(uuid,uuid,text,text,text,text,date,numeric,numeric,numeric,numeric,numeric) to authenticated;
grant execute on function public.approve_stage_submission(uuid) to authenticated;
grant execute on function public.approve_ncr(uuid) to authenticated;
grant execute on function public.set_invoice_paid_status(uuid,boolean) to authenticated;
grant execute on function public.move_inventory_department(uuid,text,numeric,uuid,text) to authenticated;
grant execute on function public.create_purchase_order(uuid,text,date,date,numeric,text,jsonb) to authenticated;
grant execute on function public.receive_purchase_order(uuid) to authenticated;
