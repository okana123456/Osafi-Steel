-- Osafi Steel: permanent job costing, quotation and customer invoice repair.
-- Run this entire file in Supabase SQL Editor.

-- total_cost and selling_price are generated columns in the live database.
-- They must never be assigned by a trigger, RPC, or browser upsert.
drop trigger if exists osafi_job_costing_totals on public.job_costing;
drop function if exists public.osafi_calculate_job_costing();

-- Product type and finish are searchable free-text fields in the app.
alter table public.jobs drop constraint if exists jobs_finish_check;
alter table public.jobs drop constraint if exists jobs_product_type_check;

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
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user public.users%rowtype;
  v_job_id uuid;
  v_materials numeric := greatest(coalesce(p_materials_cost, 0), 0);
  v_labor numeric := greatest(coalesce(p_labor_cost, 0), 0);
  v_overhead numeric := greatest(coalesce(p_overhead_cost, 0), 0);
  v_margin numeric := greatest(coalesce(p_margin_percent, 0), 0);
  v_selling numeric;
begin
  select * into v_user from public.users where id = auth.uid();
  if v_user.id is null then raise exception 'Your login session is not linked to a workshop profile'; end if;
  if v_user.role::text not in ('ops_manager','operations_manager') then
    raise exception 'Only management can create jobs';
  end if;
  if not exists (
    select 1 from public.customers c
    where c.id = p_customer_id and c.business_id = v_user.business_id
  ) then raise exception 'Customer not found in this business'; end if;
  if not exists (
    select 1 from public.users u
    where u.id = p_technician_id and u.business_id = v_user.business_id
      and u.role::text = 'technician'
  ) then raise exception 'Choose a technician from this business'; end if;
  if nullif(trim(coalesce(p_product_type, '')), '') is null
     or nullif(trim(coalesce(p_dimensions, '')), '') is null
     or nullif(trim(coalesce(p_finish, '')), '') is null
     or p_deadline is null then
    raise exception 'Complete every required job field';
  end if;

  v_selling := round((v_materials + v_labor + v_overhead) * (1 + v_margin / 100), 2);

  insert into public.jobs(
    business_id, customer_id, technician_id, product_type, dimensions, finish,
    delivery_or_collection, deadline, quoted_price, status, created_by
  ) values (
    v_user.business_id, p_customer_id, p_technician_id, trim(p_product_type),
    trim(p_dimensions), trim(p_finish), p_fulfilment, p_deadline,
    v_selling, 'quoted', auth.uid()
  ) returning id into v_job_id;

  insert into public.job_costing(
    business_id, job_id, materials_cost, labor_cost, overhead_cost, margin_percent
  ) values (
    v_user.business_id, v_job_id, v_materials, v_labor, v_overhead, v_margin
  );

  return v_job_id;
end;
$$;

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
  select * into v_user from public.users where id = auth.uid();
  select * into v_job from public.jobs where id = p_job_id;
  if v_user.id is null or v_job.id is null or v_job.business_id <> v_user.business_id then
    raise exception 'Job not found in this business';
  end if;
  if v_user.role::text not in ('ops_manager','operations_manager','accountant') then
    raise exception 'You do not have permission to create customer invoices';
  end if;
  select * into v_cost from public.job_costing where job_id = p_job_id;
  v_amount := coalesce(nullif(v_cost.selling_price, 0), nullif(v_job.quoted_price, 0), 0);
  if v_amount <= 0 then
    raise exception 'The quotation total is zero. Save the job costing before invoicing';
  end if;

  select * into v_invoice from public.invoices
  where job_id = p_job_id order by created_at desc limit 1;
  if v_invoice.id is null then
    insert into public.invoices(business_id, job_id, total, status)
    values (v_user.business_id, p_job_id, v_amount, 'unpaid') returning * into v_invoice;
  else
    update public.invoices set total = v_amount where id = v_invoice.id
    returning * into v_invoice;
  end if;
  -- Billing must not interrupt approval or production. Invoice status belongs
  -- in public.invoices while the job keeps its current workshop status.
  update public.jobs set quoted_price = v_amount where id = p_job_id;
  return v_invoice.id;
end;
$$;

create or replace function public.set_invoice_paid_status(p_invoice_id uuid, p_paid boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user public.users%rowtype;
  v_invoice public.invoices%rowtype;
begin
  select * into v_user from public.users where id = auth.uid();
  if v_user.id is null or v_user.role::text not in ('ops_manager','operations_manager','accountant') then
    raise exception 'Only management or accounting can update invoice payments';
  end if;
  select * into v_invoice from public.invoices where id = p_invoice_id;
  if v_invoice.id is null or v_invoice.business_id <> v_user.business_id then
    raise exception 'Invoice not found for this business';
  end if;
  update public.invoices
  set status = case when coalesce(p_paid,false) then 'paid' else 'unpaid' end
  where id = p_invoice_id;
end;
$$;

-- Keep existing jobs and already-created zero invoices consistent with the
-- repaired costing rows.
update public.jobs j
set quoted_price = jc.selling_price
from public.job_costing jc
where jc.job_id = j.id and jc.selling_price > 0
  and coalesce(j.quoted_price, 0) = 0;

update public.invoices i
set total = coalesce(nullif(jc.selling_price, 0), nullif(j.quoted_price, 0), i.total)
from public.jobs j
left join public.job_costing jc on jc.job_id = j.id
where i.job_id = j.id and coalesce(i.total, 0) = 0;

grant execute on function public.create_job_with_costing(uuid,uuid,text,text,text,text,date,numeric,numeric,numeric,numeric,numeric) to authenticated;
grant execute on function public.create_customer_invoice(uuid) to authenticated;
grant execute on function public.set_invoice_paid_status(uuid,boolean) to authenticated;
