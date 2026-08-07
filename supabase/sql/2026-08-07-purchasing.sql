-- Osafi Steel purchasing and supplier management
-- Run once in Supabase SQL Editor before opening the Purchases tab.

create extension if not exists pgcrypto;

create table if not exists public.suppliers (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  name text not null,
  contact_person text,
  email text,
  phone text,
  address text,
  tax_number text,
  created_by uuid references public.users(id),
  created_at timestamptz not null default now()
);

create table if not exists public.purchase_orders (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  supplier_id uuid not null references public.suppliers(id),
  order_number text not null,
  order_date date not null default current_date,
  expected_date date,
  status text not null default 'ordered' check (status in ('draft','ordered','received','cancelled')),
  subtotal numeric not null default 0,
  tax numeric not null default 0,
  total numeric not null default 0,
  notes text,
  created_by uuid references public.users(id),
  received_by uuid references public.users(id),
  received_at timestamptz,
  created_at timestamptz not null default now(),
  unique (business_id, order_number)
);

create table if not exists public.purchase_order_items (
  id uuid primary key default gen_random_uuid(),
  purchase_order_id uuid not null references public.purchase_orders(id) on delete cascade,
  inventory_item_id uuid not null references public.inventory_items(id),
  description text not null,
  quantity numeric not null check (quantity > 0),
  unit_cost numeric not null default 0 check (unit_cost >= 0),
  line_total numeric not null default 0,
  created_at timestamptz not null default now()
);

create table if not exists public.supplier_documents (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  supplier_id uuid not null references public.suppliers(id),
  purchase_order_id uuid references public.purchase_orders(id) on delete set null,
  document_type text not null check (document_type in ('invoice','credit_note')),
  document_number text not null,
  document_date date not null default current_date,
  amount numeric not null default 0 check (amount >= 0),
  reason text,
  created_by uuid references public.users(id),
  created_at timestamptz not null default now(),
  unique (business_id, document_type, document_number)
);

create index if not exists suppliers_business_idx on public.suppliers(business_id);
create index if not exists purchase_orders_business_idx on public.purchase_orders(business_id);
create index if not exists purchase_order_items_order_idx on public.purchase_order_items(purchase_order_id);
create index if not exists supplier_documents_business_idx on public.supplier_documents(business_id);

alter table public.suppliers enable row level security;
alter table public.purchase_orders enable row level security;
alter table public.purchase_order_items enable row level security;
alter table public.supplier_documents enable row level security;

drop policy if exists suppliers_manager_access on public.suppliers;
create policy suppliers_manager_access on public.suppliers for all
using (business_id = public.osafi_my_business() and public.osafi_is_manager())
with check (business_id = public.osafi_my_business() and public.osafi_is_manager());

drop policy if exists purchase_orders_manager_access on public.purchase_orders;
create policy purchase_orders_manager_access on public.purchase_orders for all
using (business_id = public.osafi_my_business() and public.osafi_is_manager())
with check (business_id = public.osafi_my_business() and public.osafi_is_manager());

drop policy if exists purchase_items_manager_access on public.purchase_order_items;
create policy purchase_items_manager_access on public.purchase_order_items for all
using (exists (
  select 1 from public.purchase_orders po
  where po.id = purchase_order_id
    and po.business_id = public.osafi_my_business()
    and public.osafi_is_manager()
)) with check (exists (
  select 1 from public.purchase_orders po
  where po.id = purchase_order_id
    and po.business_id = public.osafi_my_business()
    and public.osafi_is_manager()
));

drop policy if exists supplier_documents_manager_access on public.supplier_documents;
create policy supplier_documents_manager_access on public.supplier_documents for all
using (business_id = public.osafi_my_business() and public.osafi_is_manager())
with check (business_id = public.osafi_my_business() and public.osafi_is_manager());

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
  if v_user.id is null or v_user.role <> 'ops_manager' then
    raise exception 'Only an operations manager can create purchases';
  end if;
  select * into v_supplier from public.suppliers where id = p_supplier_id;
  if v_supplier.id is null or v_supplier.business_id <> v_user.business_id then
    raise exception 'Supplier not found';
  end if;
  if jsonb_array_length(coalesce(p_items, '[]'::jsonb)) = 0 then
    raise exception 'Add at least one purchase item';
  end if;
  select coalesce(sum((x->>'quantity')::numeric * (x->>'unit_cost')::numeric), 0)
  into v_subtotal from jsonb_array_elements(p_items) x;
  insert into public.purchase_orders(
    business_id, supplier_id, order_number, order_date, expected_date,
    status, subtotal, tax, total, notes, created_by
  ) values (
    v_user.business_id, p_supplier_id, trim(p_order_number), coalesce(p_order_date,current_date),
    p_expected_date, 'ordered', v_subtotal, greatest(coalesce(p_tax,0),0),
    v_subtotal + greatest(coalesce(p_tax,0),0), nullif(trim(p_notes),''), auth.uid()
  ) returning id into v_order_id;
  for v_item in select * from jsonb_array_elements(p_items)
  loop
    if (v_item->>'quantity')::numeric <= 0 or (v_item->>'unit_cost')::numeric < 0 then
      raise exception 'Purchase quantities and costs are invalid';
    end if;
    if not exists (
      select 1 from public.inventory_items i
      where i.id = (v_item->>'inventory_item_id')::uuid
        and i.business_id = v_user.business_id
    ) then
      raise exception 'Inventory item not found';
    end if;
    insert into public.purchase_order_items(
      purchase_order_id, inventory_item_id, description, quantity, unit_cost, line_total
    ) values (
      v_order_id, (v_item->>'inventory_item_id')::uuid, trim(v_item->>'description'),
      (v_item->>'quantity')::numeric, (v_item->>'unit_cost')::numeric,
      (v_item->>'quantity')::numeric * (v_item->>'unit_cost')::numeric
    );
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
  select * into v_order from public.purchase_orders where id = p_purchase_order_id for update;
  if v_order.id is null or v_order.business_id <> v_user.business_id or v_user.role <> 'ops_manager' then
    raise exception 'Only an operations manager can receive this purchase';
  end if;
  if v_order.status = 'received' then raise exception 'This purchase was already received'; end if;
  if v_order.status = 'cancelled' then raise exception 'A cancelled purchase cannot be received'; end if;
  for v_line in select * from public.purchase_order_items where purchase_order_id = v_order.id
  loop
    perform public.move_inventory(
      v_line.inventory_item_id, 'in', v_line.quantity, null,
      'Purchase order ' || v_order.order_number
    );
  end loop;
  update public.purchase_orders
  set status = 'received', received_by = auth.uid(), received_at = now()
  where id = v_order.id;
end;
$$;

grant execute on function public.create_purchase_order(uuid,text,date,date,numeric,text,jsonb) to authenticated;
grant execute on function public.receive_purchase_order(uuid) to authenticated;
