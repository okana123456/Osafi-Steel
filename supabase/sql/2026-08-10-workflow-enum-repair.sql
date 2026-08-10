-- Repair all stage text -> enum boundaries in the managed approval workflow.
-- Approval request tables intentionally store text for backwards compatibility;
-- final checklist, NCR and job records use the public.job_stage enum.

-- Historical checklist records must remain valid if their technician is later
-- reassigned or promoted to another role. New submissions are still restricted
-- to the currently assigned technician by request_stage_approval().
create or replace function public.enforce_tenant_refs()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  ref_business uuid;
begin
  if tg_table_name = 'jobs' then
    select business_id into ref_business from public.customers where id = new.customer_id;
    if ref_business is distinct from new.business_id then raise exception 'Customer belongs to another business'; end if;
    if new.technician_id is not null and not exists (
      select 1 from public.users where id=new.technician_id and business_id=new.business_id and role::text='technician'
    ) then raise exception 'Invalid technician'; end if;
  elsif tg_table_name in ('job_costing','stage_checklists','ncrs','deliveries','invoices') then
    select business_id into ref_business from public.jobs where id = new.job_id;
    if ref_business is distinct from new.business_id then raise exception 'Job belongs to another business'; end if;
    if tg_table_name = 'stage_checklists' and not exists (
      select 1 from public.users where id=new.technician_id and business_id=new.business_id
    ) then raise exception 'Invalid checklist team member'; end if;
  elsif tg_table_name = 'inventory_moves' then
    select business_id into ref_business from public.inventory_items where id = new.item_id;
    if ref_business is distinct from new.business_id then raise exception 'Item belongs to another business'; end if;
    if new.job_id is not null and not exists (
      select 1 from public.jobs where id=new.job_id and business_id=new.business_id
    ) then raise exception 'Job belongs to another business'; end if;
  end if;
  return new;
end;
$$;

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
  v_stage public.job_stage;
begin
  select * into v_user from public.users where id = auth.uid();
  select * into v_job from public.jobs where id = p_job_id;
  if v_job.id is null or v_user.business_id <> v_job.business_id then
    raise exception 'Job not found';
  end if;
  if v_user.role::text <> 'technician' or v_job.technician_id <> v_user.id then
    raise exception 'Only the assigned technician can submit this stage';
  end if;
  if p_stage not in ('cutting','welding','finishing','qc') then
    raise exception 'Invalid production stage';
  end if;
  v_stage := p_stage::public.job_stage;
  if v_job.current_stage is distinct from v_stage then
    raise exception 'Submit the checklist for the job current stage';
  end if;
  insert into public.job_stage_approval_requests(
    business_id,job_id,requested_by,stage,answers,notes
  ) values (
    v_job.business_id,p_job_id,auth.uid(),v_stage::text,coalesce(p_answers,'[]'::jsonb),nullif(trim(p_notes),'')
  );
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
  v_stage public.job_stage;
  v_next public.job_stage;
begin
  select * into v_user from public.users where id = auth.uid();
  select * into v_req from public.job_stage_approval_requests where id = p_checklist_id for update;
  if v_req.id is null or v_user.business_id <> v_req.business_id
     or v_user.role::text not in ('ops_manager','operations_manager') then
    raise exception 'Only an operations manager can approve this work';
  end if;
  if v_req.status <> 'pending' then raise exception 'This request is not pending'; end if;
  if v_req.stage not in ('cutting','welding','finishing','qc') then
    raise exception 'This approval request has an invalid production stage';
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
  v_reopened public.job_stage;
  v_failed_rank integer;
  v_reopened_rank integer;
begin
  select * into v_user from public.users where id = auth.uid();
  select * into v_job from public.jobs where id = p_job_id;
  if v_job.id is null or v_user.business_id <> v_job.business_id then raise exception 'Job not found'; end if;
  if v_user.role::text <> 'technician' or v_job.technician_id <> v_user.id then
    raise exception 'Only the assigned technician can raise this NCR';
  end if;
  if v_job.current_stage is null or v_job.current_stage='done'::public.job_stage then
    raise exception 'This job has no active production stage';
  end if;
  if p_reopened_stage not in ('cutting','welding','finishing','qc') then
    raise exception 'Invalid reopened production stage';
  end if;
  v_reopened := p_reopened_stage::public.job_stage;
  v_failed_rank := array_position(array['cutting','welding','finishing','qc'],v_job.current_stage::text);
  v_reopened_rank := array_position(array['cutting','welding','finishing','qc'],v_reopened::text);
  if v_reopened_rank > v_failed_rank then
    raise exception 'Reopened stage must be at or before the failed stage';
  end if;
  insert into public.ncr_approval_requests(
    business_id,job_id,requested_by,category,stage_failed_at,
    root_cause,corrective_action,reopened_stage
  ) values (
    v_job.business_id,p_job_id,auth.uid(),trim(p_category),v_job.current_stage::text,
    trim(p_root_cause),trim(p_corrective_action),v_reopened::text
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
  v_failed public.job_stage;
  v_reopened public.job_stage;
begin
  select * into v_user from public.users where id = auth.uid();
  select * into v_req from public.ncr_approval_requests where id = p_ncr_id for update;
  if v_req.id is null or v_user.business_id <> v_req.business_id
     or v_user.role::text not in ('ops_manager','operations_manager') then
    raise exception 'Only an operations manager can approve NCRs';
  end if;
  if v_req.status <> 'pending' then raise exception 'This NCR request is not pending'; end if;
  if v_req.reopened_stage not in ('cutting','welding','finishing','qc') then
    raise exception 'This NCR has an invalid reopened stage';
  end if;
  if coalesce(v_req.stage_failed_at,'') not in ('cutting','welding','finishing','qc') then
    raise exception 'This NCR has an invalid failed stage';
  end if;
  v_failed := v_req.stage_failed_at::public.job_stage;
  v_reopened := v_req.reopened_stage::public.job_stage;
  insert into public.ncrs(
    business_id,job_id,category,stage_failed_at,root_cause,
    corrective_action,reopened_at_stage,reopened_stage,status
  ) values (
    v_req.business_id,v_req.job_id,v_req.category,v_failed,v_req.root_cause,
    v_req.corrective_action,v_reopened,v_reopened::text,'open'
  );
  update public.ncr_approval_requests
  set status='approved',reviewed_by=auth.uid(),reviewed_at=now()
  where id=p_ncr_id;
  update public.jobs
  set status='rework'::public.job_status,current_stage=v_reopened
  where id=v_req.job_id;
end;
$$;

grant execute on function public.request_stage_approval(uuid,text,jsonb,text) to authenticated;
grant execute on function public.approve_stage_submission(uuid) to authenticated;
grant execute on function public.request_ncr_approval(uuid,text,text,text,text) to authenticated;
grant execute on function public.approve_ncr(uuid) to authenticated;
