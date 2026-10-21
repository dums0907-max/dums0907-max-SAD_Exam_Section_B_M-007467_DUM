-- Scholarship Monitoring and Academic Compliance System (SAD Section B)
-- Run in Supabase SQL Editor. Synthetic data only.

create extension if not exists pgcrypto;

-- ============ TABLES ============
create table programs (
  id uuid primary key default gen_random_uuid(),
  name text unique not null,
  max_gwa numeric(3,2) not null check (max_gwa between 1 and 5),
  min_units int not null check (min_units >= 0),
  max_failed int not null check (max_failed >= 0),
  max_incomplete int not null check (max_incomplete >= 0),
  max_dropped int not null check (max_dropped >= 0),
  deadline timestamptz not null
);

create table profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  role text not null check (role in ('scholar','staff')),
  full_name text not null
);

create table scholars (
  id uuid primary key default gen_random_uuid(),
  student_id text unique not null,
  full_name text not null,
  program_id uuid not null references programs(id),
  user_id uuid unique references auth.users(id),          -- null for seeded scholars with no login
  award_status text not null default 'Active' check (award_status in ('Active','Suspended','Ended'))
);

create table submissions (
  id uuid primary key default gen_random_uuid(),
  scholar_id uuid not null references scholars(id),
  academic_year text not null,
  semester int not null check (semester in (1,2,3)),
  gwa numeric(3,2) not null check (gwa between 1.00 and 5.00),
  enrolled_units int not null check (enrolled_units >= 0),
  failed_count int not null check (failed_count >= 0),
  incomplete_count int not null check (incomplete_count >= 0),
  dropped_count int not null check (dropped_count >= 0),
  evidence_ref text not null check (length(trim(evidence_ref)) > 0),
  submitted_at timestamptz not null default now(),
  verification_status text not null default 'Pending verification'
    check (verification_status in ('Pending verification','Verified','Returned')),
  verification_reason text,
  compliance_result text not null default 'Not evaluated'
    check (compliance_result in ('Not evaluated','Compliant','With Deficiency')),
  compliance_reasons text[] not null default '{}',
  renewal_decision text not null default 'Undecided' check (renewal_decision in ('Undecided','Approved','Held')),
  decision_note text,
  unique (scholar_id, academic_year, semester)
);

create table audit_log (
  id bigint generated always as identity primary key,
  submission_id uuid not null references submissions(id),
  action text not null,
  actor uuid,
  old_value text,
  new_value text,
  note text,
  at timestamptz not null default now()
);

-- ============ HELPERS ============
create or replace function is_staff() returns boolean
language sql security definer set search_path = public stable as $$
  select exists (select 1 from profiles where id = auth.uid() and role = 'staff');
$$;

create or replace function log_action(p_sub uuid, p_action text, p_old text, p_new text, p_note text)
returns void language sql security definer set search_path = public as $$
  insert into audit_log(submission_id, action, actor, old_value, new_value, note)
  values (p_sub, p_action, auth.uid(), p_old, p_new, p_note);
$$;

create or replace function validate_summary(p_gwa numeric, p_units int, p_failed int, p_inc int, p_drop int, p_evidence text)
returns void language plpgsql as $$
begin
  if p_gwa is null or p_gwa < 1.00 or p_gwa > 5.00 then
    raise exception 'GWA must be between 1.00 and 5.00 (got %)', p_gwa; end if;
  if p_units is null or p_units < 0 or p_failed is null or p_failed < 0
     or p_inc is null or p_inc < 0 or p_drop is null or p_drop < 0 then
    raise exception 'Units and failed/incomplete/dropped counts must be non-negative integers'; end if;
  if p_evidence is null or length(trim(p_evidence)) = 0 then
    raise exception 'Grade-document reference is required'; end if;
end $$;

-- ============ RLS ============
alter table programs enable row level security;
alter table profiles enable row level security;
alter table scholars enable row level security;
alter table submissions enable row level security;
alter table audit_log enable row level security;

create policy programs_read on programs for select to authenticated using (true);
create policy programs_staff_write on programs for update to authenticated using (is_staff()) with check (is_staff());

create policy profiles_read on profiles for select to authenticated using (id = auth.uid() or is_staff());

create policy scholars_read on scholars for select to authenticated using (is_staff() or user_id = auth.uid());
create policy scholars_staff_insert on scholars for insert to authenticated with check (is_staff());
create policy scholars_staff_update on scholars for update to authenticated using (is_staff()) with check (is_staff());

create policy submissions_read on submissions for select to authenticated
  using (is_staff() or exists (select 1 from scholars s where s.id = scholar_id and s.user_id = auth.uid()));
-- no insert/update/delete policies: all writes go through the RPC functions below

create policy audit_read on audit_log for select to authenticated
  using (is_staff() or exists (select 1 from submissions x join scholars s on s.id = x.scholar_id
                               where x.id = submission_id and s.user_id = auth.uid()));

-- ============ WORKFLOW FUNCTIONS ============
create or replace function submit_grades(p_year text, p_sem int, p_gwa numeric, p_units int,
  p_failed int, p_inc int, p_drop int, p_evidence text) returns uuid
language plpgsql security definer set search_path = public as $$
declare sc scholars; new_id uuid;
begin
  select * into sc from scholars where user_id = auth.uid();
  if not found then raise exception 'No scholar record is linked to your account'; end if;
  perform validate_summary(p_gwa, p_units, p_failed, p_inc, p_drop, p_evidence);
  begin
    insert into submissions(scholar_id, academic_year, semester, gwa, enrolled_units, failed_count,
      incomplete_count, dropped_count, evidence_ref)
    values (sc.id, p_year, p_sem, p_gwa, p_units, p_failed, p_inc, p_drop, trim(p_evidence))
    returning id into new_id;
  exception when unique_violation then
    raise exception 'Duplicate: a submission for % semester % already exists. If it was returned, correct and resubmit it.', p_year, p_sem;
  end;
  perform log_action(new_id, 'submitted', null, 'Pending verification', null);
  return new_id;
end $$;

create or replace function resubmit_grades(p_id uuid, p_gwa numeric, p_units int,
  p_failed int, p_inc int, p_drop int, p_evidence text) returns void
language plpgsql security definer set search_path = public as $$
declare s submissions;
begin
  select x.* into s from submissions x join scholars sc on sc.id = x.scholar_id
   where x.id = p_id and sc.user_id = auth.uid();
  if not found then raise exception 'Access denied: not your submission'; end if;
  if s.verification_status <> 'Returned' then raise exception 'Only returned submissions can be corrected'; end if;
  perform validate_summary(p_gwa, p_units, p_failed, p_inc, p_drop, p_evidence);
  update submissions set gwa = p_gwa, enrolled_units = p_units, failed_count = p_failed,
    incomplete_count = p_inc, dropped_count = p_drop, evidence_ref = trim(p_evidence),
    submitted_at = now(), verification_status = 'Pending verification', verification_reason = null,
    compliance_result = 'Not evaluated', compliance_reasons = '{}',
    renewal_decision = 'Undecided', decision_note = null
  where id = p_id;
  perform log_action(p_id, 'resubmitted', 'Returned', 'Pending verification', 'Scholar correction');
end $$;

create or replace function verify_submission(p_id uuid, p_status text, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare s submissions;
begin
  if not is_staff() then raise exception 'Access denied: staff only'; end if;
  if p_status not in ('Verified','Returned') then raise exception 'Status must be Verified or Returned'; end if;
  if p_status = 'Returned' and (p_reason is null or length(trim(p_reason)) = 0) then
    raise exception 'A reason is required when returning evidence'; end if;
  select * into s from submissions where id = p_id;
  if not found then raise exception 'Submission not found'; end if;
  update submissions set verification_status = p_status, verification_reason = p_reason,
    compliance_result = 'Not evaluated', compliance_reasons = '{}',
    renewal_decision = 'Undecided', decision_note = null
  where id = p_id;
  perform log_action(p_id, 'verification', s.verification_status, p_status, p_reason);
end $$;

create or replace function evaluate_submission(p_id uuid) returns text[]
language plpgsql security definer set search_path = public as $$
declare s submissions; pr programs; r text[] := '{}'; res text;
begin
  if not is_staff() then raise exception 'Access denied: staff only'; end if;
  select * into s from submissions where id = p_id;
  if not found then raise exception 'Submission not found'; end if;
  if s.verification_status <> 'Verified' then
    raise exception 'Cannot evaluate: evidence is "%". Verify it first.', s.verification_status; end if;
  select pr2.* into pr from programs pr2 join scholars sc on sc.program_id = pr2.id where sc.id = s.scholar_id;

  if s.gwa > pr.max_gwa then r := r || format('GWA %s exceeds maximum %s', s.gwa, pr.max_gwa); end if;
  if s.enrolled_units < pr.min_units then r := r || format('Enrolled units %s below minimum %s', s.enrolled_units, pr.min_units); end if;
  if s.failed_count > pr.max_failed then r := r || format('Failed subjects %s exceed allowed %s', s.failed_count, pr.max_failed); end if;
  if s.incomplete_count > pr.max_incomplete then r := r || format('Incomplete grades %s exceed allowed %s', s.incomplete_count, pr.max_incomplete); end if;
  if s.dropped_count > pr.max_dropped then r := r || format('Dropped subjects %s exceed allowed %s', s.dropped_count, pr.max_dropped); end if;
  if s.submitted_at > pr.deadline then
    r := r || format('Submitted late: %s (Asia/Manila) is after deadline %s',
      to_char(s.submitted_at at time zone 'Asia/Manila', 'YYYY-MM-DD HH24:MI'),
      to_char(pr.deadline at time zone 'Asia/Manila', 'YYYY-MM-DD HH24:MI'));
  end if;

  res := case when array_length(r, 1) is null then 'Compliant' else 'With Deficiency' end;
  update submissions set compliance_result = res, compliance_reasons = r,
    renewal_decision = 'Undecided', decision_note = null where id = p_id;
  perform log_action(p_id, 'evaluation', s.compliance_result, res, array_to_string(r, '; '));
  return r;
end $$;

create or replace function decide_renewal(p_id uuid, p_decision text, p_note text) returns void
language plpgsql security definer set search_path = public as $$
declare s submissions;
begin
  if not is_staff() then raise exception 'Access denied: staff only'; end if;
  if p_decision not in ('Approved','Held') then raise exception 'Decision must be Approved or Held'; end if;
  select * into s from submissions where id = p_id;
  if not found then raise exception 'Submission not found'; end if;
  if s.verification_status <> 'Verified' or s.compliance_result = 'Not evaluated' then
    raise exception 'Blocked: record must be verified and evaluated before a renewal decision'; end if;
  if p_decision = 'Approved' and s.compliance_result <> 'Compliant' then
    raise exception 'Blocked: a record "With Deficiency" cannot be approved'; end if;
  update submissions set renewal_decision = p_decision, decision_note = p_note where id = p_id;
  perform log_action(p_id, 'renewal', s.renewal_decision, p_decision, p_note);
end $$;

create or replace function dashboard_stats(p_year text, p_sem int) returns json
language plpgsql security definer set search_path = public as $$
begin
  if not is_staff() then raise exception 'Access denied: staff only'; end if;
  return json_build_object(
    'assigned_scholars', (select count(*) from scholars),
    'pending_verification', (select count(*) from submissions where academic_year = p_year and semester = p_sem and verification_status = 'Pending verification'),
    'compliant', (select count(*) from submissions where academic_year = p_year and semester = p_sem and compliance_result = 'Compliant'),
    'with_deficiency', (select count(*) from submissions where academic_year = p_year and semester = p_sem and compliance_result = 'With Deficiency'));
end $$;

revoke all on function submit_grades, resubmit_grades, verify_submission, evaluate_submission,
  decide_renewal, dashboard_stats from public;
grant execute on function submit_grades, resubmit_grades, verify_submission, evaluate_submission,
  decide_renewal, dashboard_stats to authenticated;

-- ============ SEED (runs as postgres, bypasses RLS) ============
insert into programs(name, max_gwa, min_units, max_failed, max_incomplete, max_dropped, deadline) values
 ('Excellence Scholar', 2.00, 18, 0, 0, 0, '2026-11-06 17:00:00+08'),
 ('Access Scholar',     2.50, 15, 0, 0, 1, '2026-11-06 17:00:00+08');

insert into scholars(student_id, full_name, program_id)
select v.sid, v.nm, p.id from (values
 ('B01','Scholar One','Excellence Scholar'), ('B02','Scholar Two','Excellence Scholar'),
 ('B03','Scholar Three','Access Scholar'),  ('B04','Scholar Four','Access Scholar'),
 ('B05','Scholar Five','Excellence Scholar'),('B06','Scholar Six','Access Scholar')
) v(sid, nm, prog) join programs p on p.name = v.prog;

insert into submissions(scholar_id, academic_year, semester, gwa, enrolled_units, failed_count,
  incomplete_count, dropped_count, evidence_ref, submitted_at, verification_status)
select s.id, '2026-2027', 1, v.gwa, v.units, v.f, v.i, v.d, 'GD-' || v.sid, v.ts::timestamptz, v.vs
from (values
 ('B01',2.00,18,0,0,0,'2026-11-06 17:00:00+08','Verified'),   -- exactly at deadline
 ('B02',2.01,18,0,0,0,'2026-11-05 10:00:00+08','Verified'),
 ('B03',2.50,15,0,0,1,'2026-11-05 10:00:00+08','Verified'),
 ('B04',2.50,14,0,1,0,'2026-11-05 10:00:00+08','Verified'),
 ('B05',1.75,18,1,0,0,'2026-11-06 17:01:00+08','Verified'),   -- one minute late
 ('B06',2.25,15,0,0,0,'2026-11-05 10:00:00+08','Pending verification')
) v(sid,gwa,units,f,i,d,ts,vs) join scholars s on s.student_id = v.sid;

-- After creating two Auth users (Dashboard > Authentication > Users), edit the emails and run:
-- insert into profiles(id, role, full_name) select id,'staff','Test Staff' from auth.users where email='staff@test.local';
-- insert into profiles(id, role, full_name) select id,'scholar','Scholar One' from auth.users where email='scholar@test.local';
-- update scholars set user_id = (select id from auth.users where email='scholar@test.local') where student_id='B01';
