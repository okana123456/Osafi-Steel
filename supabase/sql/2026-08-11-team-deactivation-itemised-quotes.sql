-- Osafi Steel: preserve staff history when removing access and add itemised
-- material quotations. Run this entire file in Supabase SQL Editor.

alter table public.users
  add column if not exists is_active boolean not null default true;

create table if not exists public.job_material_items (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  job_id uuid not null references public.jobs(id) on delete cascade,
  description text not null check (length(trim(description)) > 0),
  quantity numeric(14,3) not null check (quantity > 0),
  unit_price numeric(14,2) not null check (unit_price >= 0),
  line_total numeric(14,2) generated always as (round(quantity * unit_price, 2)) stored,
  sort_order integer not null default 0,
  created_at timestamptz not null default now()
);

create index if not exists job_material_items_job_id_idx
  on public.job_material_items(job_id, sort_order, created_at);

alter table public.job_material_items enable row level security;

drop policy if exists job_material_items_management_all on public.job_material_items;
create policy job_material_items_management_all on public.job_material_items
for all to authenticated
using (
  business_id = public.osafi_my_business()
  and public.osafi_has_role('ops_manager', 'operations_manager')
)
with check (
  business_id = public.osafi_my_business()
  and public.osafi_has_role('ops_manager', 'operations_manager')
);

drop policy if exists job_material_items_accounting_read on public.job_material_items;
create policy job_material_items_accounting_read on public.job_material_items
for select to authenticated
using (
  business_id = public.osafi_my_business()
  and public.osafi_has_role('accountant')
);

create or replace function public.osafi_validate_job_material_item()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (
    select 1 from public.jobs j
    where j.id = new.job_id and j.business_id = new.business_id
  ) then
    raise exception 'Material item job belongs to another business';
  end if;
  new.description := trim(new.description);
  return new;
end;
$$;

drop trigger if exists osafi_validate_job_material_item on public.job_material_items;
create trigger osafi_validate_job_material_item
before insert or update on public.job_material_items
for each row execute function public.osafi_validate_job_material_item();

create or replace function public.osafi_insert_material_items(
  p_business_id uuid,
  p_job_id uuid,
  p_items jsonb
) returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item jsonb;
  v_name text;
  v_quantity numeric;
  v_unit_price numeric;
  v_total numeric := 0;
  v_order integer := 0;
begin
  if p_items is null then return 0; end if;
  if jsonb_typeof(p_items) <> 'array' then
    raise exception 'Material items must be a list';
  end if;

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    v_name := trim(coalesce(v_item->>'description', ''));
    begin
      v_quantity := (v_item->>'quantity')::numeric;
      v_unit_price := (v_item->>'unit_price')::numeric;
    exception when others then
      raise exception 'Every material needs a valid quantity and unit price';
    end;
    if v_name = '' or v_quantity <= 0 or v_unit_price < 0 then
      raise exception 'Every material needs a name, quantity above zero and a non-negative unit price';
    end if;
    insert into public.job_material_items(
      business_id, job_id, description, quantity, unit_price, sort_order
    ) values (
      p_business_id, p_job_id, v_name, v_quantity, v_unit_price, v_order
    );
    v_total := v_total + round(v_quantity * v_unit_price, 2);
    v_order := v_order + 1;
  end loop;
  return round(v_total, 2);
end;
$$;

revoke all on function public.osafi_insert_material_items(uuid,uuid,jsonb) from public;

create or replace function public.create_job_with_itemised_costing(
  p_customer_id uuid,
  p_technician_id uuid,
  p_product_type text,
  p_dimensions text,
  p_finish text,
  p_fulfilment text,
  p_deadline date,
  p_materials_cost numeric,
  p_labor_cost numeric,
  p_overhead_cost numeric,
  p_margin_percent numeric,
  p_material_items jsonb default '[]'::jsonb
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
  v_item_total numeric := 0;
  v_selling numeric;
begin
  select * into v_user from public.users where id = auth.uid();
  if v_user.id is null or coalesce(v_user.is_active, true) is false then
    raise exception 'Your workshop account is not active';
  end if;
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
      and u.role::text = 'technician' and coalesce(u.is_active, true)
  ) then raise exception 'Choose an active technician from this business'; end if;
  if nullif(trim(coalesce(p_product_type, '')), '') is null
     or nullif(trim(coalesce(p_dimensions, '')), '') is null
     or nullif(trim(coalesce(p_finish, '')), '') is null
     or p_deadline is null then
    raise exception 'Complete every required job field';
  end if;

  insert into public.jobs(
    business_id, customer_id, technician_id, product_type, dimensions, finish,
    delivery_or_collection, deadline, quoted_price, status, created_by
  ) values (
    v_user.business_id, p_customer_id, p_technician_id, trim(p_product_type),
    trim(p_dimensions), trim(p_finish), p_fulfilment, p_deadline,
    0, 'quoted', auth.uid()
  ) returning id into v_job_id;

  v_item_total := public.osafi_insert_material_items(v_user.business_id, v_job_id, coalesce(p_material_items, '[]'::jsonb));
  if jsonb_array_length(coalesce(p_material_items, '[]'::jsonb)) > 0 then
    v_materials := v_item_total;
  end if;
  v_selling := round((v_materials + v_labor + v_overhead) * (1 + v_margin / 100), 2);

  insert into public.job_costing(
    business_id, job_id, materials_cost, labor_cost, overhead_cost, margin_percent
  ) values (
    v_user.business_id, v_job_id, v_materials, v_labor, v_overhead, v_margin
  );
  update public.jobs set quoted_price = v_selling where id = v_job_id;
  return v_job_id;
end;
$$;

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
     or v_job.id is null or v_job.business_id <> v_user.business_id
     or v_user.role::text not in ('ops_manager','operations_manager') then
    raise exception 'Only management can cost this business job';
  end if;

  delete from public.job_material_items where job_id = p_job_id;
  v_item_total := public.osafi_insert_material_items(v_user.business_id, p_job_id, coalesce(p_material_items, '[]'::jsonb));
  if jsonb_array_length(coalesce(p_material_items, '[]'::jsonb)) > 0 then
    v_materials := v_item_total;
  end if;
  v_selling := round((v_materials + v_labor + v_overhead) * (1 + v_margin / 100), 2);

  insert into public.job_costing(
    business_id, job_id, materials_cost, labor_cost, overhead_cost, margin_percent
  ) values (
    v_user.business_id, p_job_id, v_materials, v_labor, v_overhead, v_margin
  )
  on conflict (job_id) do update set
    materials_cost = excluded.materials_cost,
    labor_cost = excluded.labor_cost,
    overhead_cost = excluded.overhead_cost,
    margin_percent = excluded.margin_percent,
    updated_at = now();

  update public.jobs set quoted_price = v_selling where id = p_job_id;
  return v_selling;
end;
$$;

grant select, insert, update, delete on public.job_material_items to authenticated;
grant execute on function public.create_job_with_itemised_costing(uuid,uuid,text,text,text,text,date,numeric,numeric,numeric,numeric,jsonb) to authenticated;
grant execute on function public.save_job_costing_with_materials(uuid,numeric,numeric,numeric,numeric,jsonb) to authenticated;

