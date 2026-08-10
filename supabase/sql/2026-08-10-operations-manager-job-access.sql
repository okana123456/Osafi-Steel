-- Osafi Steel: give both supported Operations Manager role names complete
-- access to the same-business job workflow.
--
-- The original schema used `ops_manager`; newer team invitations can use
-- `operations_manager`. Security-definer creation functions accepted both,
-- while several RLS policies still accepted only the original enum value.

create or replace function public.osafi_is_manager()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.osafi_has_role('ops_manager', 'operations_manager')
$$;

grant execute on function public.osafi_is_manager() to authenticated;

-- Additive policies preserve the existing technician, accountant and legacy
-- owner policies while giving both management role names equal job access.
drop policy if exists jobs_operations_management_all on public.jobs;
create policy jobs_operations_management_all on public.jobs
for all to authenticated
using (
  business_id = public.osafi_my_business()
  and public.osafi_is_manager()
)
with check (
  business_id = public.osafi_my_business()
  and public.osafi_is_manager()
);

drop policy if exists costing_operations_management_all on public.job_costing;
create policy costing_operations_management_all on public.job_costing
for all to authenticated
using (
  business_id = public.osafi_my_business()
  and public.osafi_is_manager()
)
with check (
  business_id = public.osafi_my_business()
  and public.osafi_is_manager()
);

drop policy if exists checklists_operations_management_all on public.stage_checklists;
create policy checklists_operations_management_all on public.stage_checklists
for all to authenticated
using (
  business_id = public.osafi_my_business()
  and public.osafi_is_manager()
)
with check (
  business_id = public.osafi_my_business()
  and public.osafi_is_manager()
);

drop policy if exists ncrs_operations_management_all on public.ncrs;
create policy ncrs_operations_management_all on public.ncrs
for all to authenticated
using (
  business_id = public.osafi_my_business()
  and public.osafi_is_manager()
)
with check (
  business_id = public.osafi_my_business()
  and public.osafi_is_manager()
);

drop policy if exists deliveries_operations_management_all on public.deliveries;
create policy deliveries_operations_management_all on public.deliveries
for all to authenticated
using (
  business_id = public.osafi_my_business()
  and public.osafi_is_manager()
)
with check (
  business_id = public.osafi_my_business()
  and public.osafi_is_manager()
);

drop policy if exists invoices_operations_management_all on public.invoices;
create policy invoices_operations_management_all on public.invoices
for all to authenticated
using (
  business_id = public.osafi_my_business()
  and public.osafi_is_manager()
)
with check (
  business_id = public.osafi_my_business()
  and public.osafi_is_manager()
);

-- These tables already used osafi_is_manager(), but explicit policies keep the
-- full job-detail workflow protected from future legacy-policy drift.
drop policy if exists attachments_operations_management_all on public.job_attachments;
create policy attachments_operations_management_all on public.job_attachments
for all to authenticated
using (business_id = public.osafi_my_business() and public.osafi_is_manager())
with check (business_id = public.osafi_my_business() and public.osafi_is_manager());

drop policy if exists messages_operations_management_all on public.job_messages;
create policy messages_operations_management_all on public.job_messages
for all to authenticated
using (business_id = public.osafi_my_business() and public.osafi_is_manager())
with check (business_id = public.osafi_my_business() and public.osafi_is_manager());

drop policy if exists complaints_operations_management_all on public.complaints;
create policy complaints_operations_management_all on public.complaints
for all to authenticated
using (business_id = public.osafi_my_business() and public.osafi_is_manager())
with check (business_id = public.osafi_my_business() and public.osafi_is_manager());

drop policy if exists stage_requests_operations_management_all on public.job_stage_approval_requests;
create policy stage_requests_operations_management_all on public.job_stage_approval_requests
for all to authenticated
using (business_id = public.osafi_my_business() and public.osafi_is_manager())
with check (business_id = public.osafi_my_business() and public.osafi_is_manager());

drop policy if exists ncr_requests_operations_management_all on public.ncr_approval_requests;
create policy ncr_requests_operations_management_all on public.ncr_approval_requests
for all to authenticated
using (business_id = public.osafi_my_business() and public.osafi_is_manager())
with check (business_id = public.osafi_my_business() and public.osafi_is_manager());

