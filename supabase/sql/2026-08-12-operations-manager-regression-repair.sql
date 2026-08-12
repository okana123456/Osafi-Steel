-- Osafi Steel: repair Operations Manager job creation and stage approval.
-- Safe to run after the 2026-08-11 creator-scoped workflow migration.

create or replace function public.osafi_my_business()
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select business_id from public.users where id = auth.uid()
$$;
grant execute on function public.osafi_my_business() to authenticated;

-- Read-only access to same-business technicians for job assignment.
drop policy if exists users_operations_technicians_read on public.users;
create policy users_operations_technicians_read on public.users
for select to authenticated
using (
  business_id = public.osafi_my_business()
  and role::text = 'technician'
  and coalesce(is_active, true)
  and public.osafi_has_role('operations_manager')
);

-- Explicit enum casts prevent the CASE result being treated as text.
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
  select * into v_req from public.job_stage_approval_requests
  where id = p_checklist_id for update;

  if v_req.id is null or not public.osafi_can_manage_job(v_req.job_id) then
    raise exception 'You can only approve stages for jobs you manage';
  end if;
  if v_req.status <> 'pending' then raise exception 'This request is not pending'; end if;
  if v_req.stage not in ('cutting','welding','finishing','qc') then
    raise exception 'Invalid production stage';
  end if;

  v_stage := v_req.stage::public.job_stage;
  v_next := case v_stage
    when 'cutting'::public.job_stage then 'welding'::public.job_stage
    when 'welding'::public.job_stage then 'finishing'::public.job_stage
    when 'finishing'::public.job_stage then 'qc'::public.job_stage
    else 'done'::public.job_stage
  end;

  insert into public.stage_checklists(
    business_id,job_id,technician_id,stage,checklist_answers,result,notes
  ) values (
    v_req.business_id,v_req.job_id,v_req.requested_by,v_stage,
    coalesce(v_req.answers,'[]'::jsonb),'pass',v_req.notes
  );

  update public.job_stage_approval_requests
  set status='approved',reviewed_by=auth.uid(),reviewed_at=now()
  where id=p_checklist_id;

  update public.jobs
  set current_stage=v_next,
      status=case
        when v_next='done'::public.job_stage then 'completed'::public.job_status
        when v_next='qc'::public.job_stage then 'qc'::public.job_status
        else 'in_production'::public.job_status
      end,
      completed_at=case when v_next='done'::public.job_stage then now() else completed_at end
  where id=v_req.job_id;

  insert into public.job_audit_log(business_id,job_id,actor_id,action,details)
  values(v_req.business_id,v_req.job_id,auth.uid(),'stage_approved',
    jsonb_build_object('stage',v_req.stage,'next_stage',v_next::text));

  perform public.osafi_sync_technician_payment(v_req.job_id);
end;
$$;

grant execute on function public.approve_stage_submission(uuid) to authenticated;
