// ====== CONFIG: paste your project URL and ANON (public) key only. Never the service-role key. ======
const SUPABASE_URL = 'https://seiqqswbdszbpjtepvmg.supabase.co', 
      SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InNlaXFxc3diZHN6YnBqdGVwdm1nIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTI1MTY1OTIsImV4cCI6MjEwODA5MjU5Mn0.20tzuQBeWjcnkfhCi3J75NuaSSvSLZfSl-egIrVB3c8';
const sb = supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
const $ = s => document.querySelector(s);
const esc = t => String(t ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
let me = null, programs = [], rows = [], edit = null;
const F = {year: '2026-2027', sem: 1, q: '', prog: '', comp: ''};
 
function msg(t, ok = true) { const m = $('#msg'); m.textContent = t; m.className = ok ? 'ok' : 'err'; scrollTo(0, 0); }
async function rpc(fn, args) {
  const {data, error} = await sb.rpc(fn, args);
  if (error) { msg(error.message, false); return null; }
  return data ?? true;
}
const num = v => v === '' ? null : Number(v);
const val = id => $('#' + id).value;
 
async function start() {
  const {data: {session}} = await sb.auth.getSession();
  if (!session) return loginView();
  const {data: p} = await sb.from('profiles').select('*').eq('id', session.user.id).single();
  if (!p) { await sb.auth.signOut(); msg('No profile for this account. Run the profile insert from schema.sql.', false); return loginView(); }
  me = p;
  programs = (await sb.from('programs').select('*').order('name')).data || [];
  $('#who').innerHTML = `${esc(me.full_name)} (${me.role}) <button class="g" onclick="logout()">Log out</button>`;
  me.role === 'staff' ? staffView() : scholarView();
}
function loginView() {
  $('#who').textContent = '';
  $('#app').innerHTML = `<div class="login"><div class="card"><div class="brand">Scholarship Office</div><h2>Welcome back</h2>
  <p class="sub">Log in to monitor scholarship compliance.</p>
  <label>Email<input id="em" type="email" autocomplete="username"></label>
  <label>Password<input id="pw" type="password" autocomplete="current-password" onkeydown="if(event.key==='Enter')login()"></label>
  <button onclick="login()">Log in</button></div></div>`;
}
async function login() {
  const {error} = await sb.auth.signInWithPassword({email: val('em'), password: val('pw')});
  if (error) return msg(error.message, false);
  $('#msg').className = ''; start();
}
async function logout() { await sb.auth.signOut(); me = null; $('#msg').className = ''; loginView(); }
 
const TONE = {Verified:'ok',Compliant:'ok',Approved:'ok',Active:'ok','Pending verification':'warn',Held:'warn',Returned:'bad','With Deficiency':'bad'};
const badge = t => `<span class="tag t-${TONE[t] || 'mut'}">${esc(t)}</span>`;
const dt = t => new Date(t).toLocaleString('en-PH', {timeZone: 'Asia/Manila', hour12: false}) + ' PHT';
 
// ================= SCHOLAR =================
async function scholarView() {
  const {data} = await sb.from('submissions').select('*').order('submitted_at', {ascending: false});
  rows = data || [];
  const e = edit ? rows.find(r => r.id === edit) : null;
  $('#app').innerHTML = `<div class="card"><h2>${e ? 'Correct returned submission' : 'Submit semester grades'}</h2>
  ${e ? `<p>Returned reason: <b>${esc(e.verification_reason)}</b></p>` : `
  <label>Academic year<input id="y" value="2026-2027"></label>
  <label>Semester<select id="s"><option>1</option><option>2</option></select></label>`}
  <label>GWA<input id="gwa" value="${e ? e.gwa : ''}"></label><label>Enrolled units<input id="u" value="${e ? e.enrolled_units : ''}"></label>
  <label>Failed<input id="f" value="${e ? e.failed_count : ''}"></label><label>Incomplete<input id="i" value="${e ? e.incomplete_count : ''}"></label>
  <label>Dropped<input id="d" value="${e ? e.dropped_count : ''}"></label>
  <label>Grade-document reference<input id="ev" value="${e ? esc(e.evidence_ref) : ''}"></label><br>
  <button onclick="submitForm()">${e ? 'Resubmit' : 'Submit'}</button>${e ? '<button class="g" onclick="edit=null;scholarView()">Cancel</button>' : ''}</div>
  <div class="card"><h2>My submissions</h2><div class="wrap"><table><tr><th>Term</th><th>GWA</th><th>Units</th><th>F/INC/DRP</th><th>Submitted</th><th>Verification</th><th>Compliance</th><th>Renewal</th><th></th></tr>
  ${rows.map(r => `<tr><td>${r.academic_year} S${r.semester}</td><td>${r.gwa}</td><td>${r.enrolled_units}</td><td>${r.failed_count}/${r.incomplete_count}/${r.dropped_count}</td>
  <td>${dt(r.submitted_at)}</td><td>${badge(r.verification_status)}${r.verification_reason ? '<br>' + esc(r.verification_reason) : ''}</td>
  <td>${badge(r.compliance_result)}${r.compliance_reasons.map(x => '<br>' + esc(x)).join('')}</td><td>${badge(r.renewal_decision)}${r.decision_note ? '<br>' + esc(r.decision_note) : ''}</td>
  <td>${r.verification_status === 'Returned' ? `<button onclick="edit='${r.id}';scholarView()">Correct</button>` : ''}<button class="g" onclick="history('${r.id}')">History</button></td></tr>`).join('') || '<tr><td colspan="9">No submissions yet.</td></tr>'}
  </table></div><div id="hist"></div></div>`;
}
async function submitForm() {
  const n = ['gwa', 'u', 'f', 'i', 'd'].map(k => num(val(k)));
  if (n.slice(1).some(x => x !== null && !Number.isInteger(x))) return msg('Units and counts must be whole numbers', false);
  const ev = val('ev');
  const ok = edit
    ? await rpc('resubmit_grades', {p_id: edit, p_gwa: n[0], p_units: n[1], p_failed: n[2], p_inc: n[3], p_drop: n[4], p_evidence: ev})
    : await rpc('submit_grades', {p_year: val('y'), p_sem: Number(val('s')), p_gwa: n[0], p_units: n[1], p_failed: n[2], p_inc: n[3], p_drop: n[4], p_evidence: ev});
  if (ok) { msg(edit ? 'Resubmitted. Status is Pending verification.' : 'Submission received.'); edit = null; scholarView(); }
}
 
// ================= STAFF =================
async function staffView() {
  const [{data: subs}, {data: sch}, stats] = await Promise.all([
    sb.from('submissions').select('*, scholars(student_id, full_name, programs(name))').eq('academic_year', F.year).eq('semester', F.sem).order('submitted_at'),
    sb.from('scholars').select('*, programs(name)').order('student_id'),
    rpc('dashboard_stats', {p_year: F.year, p_sem: F.sem})]);
  rows = subs || [];
  const q = F.q.toLowerCase();
  const shown = rows.filter(r => (!q || r.scholars.student_id.toLowerCase().includes(q) || r.scholars.full_name.toLowerCase().includes(q))
    && (!F.prog || r.scholars.programs.name === F.prog) && (!F.comp || r.compliance_result === F.comp));
  const po = programs.map(p => `<option value="${p.id}">${esc(p.name)}</option>`).join('');
  $('#app').innerHTML = `<div class="card"><h2>Dashboard</h2>
  <label>Academic year<input id="fy" value="${esc(F.year)}"></label><label>Semester<select id="fs"><option ${F.sem == 1 ? 'selected' : ''}>1</option><option ${F.sem == 2 ? 'selected' : ''}>2</option></select></label>
  <button class="g" onclick="setTerm()">Apply</button>
  <div class="stats">${stats ? `<div class="stat"><b>${stats.assigned_scholars}</b>Assigned scholars</div><div class="stat"><b>${stats.pending_verification}</b>Pending verification</div><div class="stat"><b>${stats.compliant}</b>Compliant</div><div class="stat"><b>${stats.with_deficiency}</b>With deficiency</div>` : ''}</div></div>
  <div class="card"><h2>Policy thresholds (read from program records)</h2><div class="wrap"><table><tr><th>Program</th><th>Max GWA</th><th>Min units</th><th>Max failed</th><th>Max INC</th><th>Max dropped</th><th>Deadline</th></tr>
  ${programs.map(p => `<tr><td>${esc(p.name)}</td><td>${p.max_gwa}</td><td>${p.min_units}</td><td>${p.max_failed}</td><td>${p.max_incomplete}</td><td>${p.max_dropped}</td><td>${dt(p.deadline)}</td></tr>`).join('')}</table></div></div>
  <div class="card"><h2>Register scholar</h2><label>Student ID<input id="ns"></label><label>Full name<input id="nn"></label>
  <label>Program<select id="np">${po}</select></label><button onclick="addScholar()">Register</button>
  <div class="wrap"><table><tr><th>ID</th><th>Name</th><th>Program (reassign)</th><th>Award</th></tr>
  ${(sch || []).map(s => `<tr><td>${esc(s.student_id)}</td><td>${esc(s.full_name)}</td><td><select onchange="setProgram('${s.id}',this.value)">${programs.map(p => `<option value="${p.id}" ${p.id === s.program_id ? 'selected' : ''}>${esc(p.name)}</option>`).join('')}</select></td><td>${badge(s.award_status)}</td></tr>`).join('')}</table></div></div>
  <div class="card"><h2>Submissions (${F.year} S${F.sem})</h2>
  <label>Search ID or name<input id="fq" value="${esc(F.q)}" oninput="F.q=this.value;clearTimeout(window.t);window.t=setTimeout(staffView,300)"></label>
  <label>Program<select onchange="F.prog=this.value;staffView()"><option value="">All</option>${programs.map(p => `<option ${F.prog === p.name ? 'selected' : ''}>${esc(p.name)}</option>`).join('')}</select></label>
  <label>Compliance<select onchange="F.comp=this.value;staffView()">${['', 'Not evaluated', 'Compliant', 'With Deficiency'].map(c => `<option value="${c}" ${F.comp === c ? 'selected' : ''}>${c || 'All'}</option>`).join('')}</select></label>
  <div class="wrap"><table><tr><th>Scholar</th><th>GWA/Units</th><th>F/INC/DRP</th><th>Evidence</th><th>Submitted</th><th>Verification</th><th>Compliance</th><th>Renewal</th><th>Actions</th></tr>
  ${shown.map(r => `<tr><td>${esc(r.scholars.student_id)}<br>${esc(r.scholars.full_name)}<br>${esc(r.scholars.programs.name)}</td><td>${r.gwa} / ${r.enrolled_units}</td><td>${r.failed_count}/${r.incomplete_count}/${r.dropped_count}</td><td>${esc(r.evidence_ref)}</td><td>${dt(r.submitted_at)}</td>
  <td>${badge(r.verification_status)}${r.verification_reason ? '<br>' + esc(r.verification_reason) : ''}</td><td>${badge(r.compliance_result)}${r.compliance_reasons.map(x => '<br>' + esc(x)).join('')}</td>
  <td>${badge(r.renewal_decision)}${r.decision_note ? '<br>' + esc(r.decision_note) : ''}</td>
  <td><button onclick="verify('${r.id}','Verified')">Verify</button><button class="w" onclick="verify('${r.id}','Returned')">Return</button><button onclick="evalRow('${r.id}')">Evaluate</button><button onclick="decide('${r.id}','Approved')">Approve</button><button class="w" onclick="decide('${r.id}','Held')">Hold</button><button class="g" onclick="history('${r.id}')">History</button></td></tr>`).join('') || '<tr><td colspan="9">No matching submissions.</td></tr>'}
  </table></div><div id="hist"></div></div>`;
}
function setTerm() { F.year = val('fy'); F.sem = Number(val('fs')); staffView(); }
async function addScholar() {
  const {error} = await sb.from('scholars').insert({student_id: val('ns').trim(), full_name: val('nn').trim(), program_id: val('np')});
  if (error) return msg(error.code === '23505' ? 'That student ID is already registered.' : error.message, false);
  msg('Scholar registered.'); staffView();
}
async function setProgram(id, pid) {
  const {error} = await sb.from('scholars').update({program_id: pid}).eq('id', id);
  error ? msg(error.message, false) : msg('Program reassigned.'); staffView();
}
async function verify(id, status) {
  let reason = null;
  if (status === 'Returned') { reason = prompt('Reason for returning (required):'); if (reason === null) return; }
  if (await rpc('verify_submission', {p_id: id, p_status: status, p_reason: reason})) { msg('Marked ' + status + '.'); staffView(); }
}
async function evalRow(id) {
  const r = await rpc('evaluate_submission', {p_id: id});
  if (r) { msg(r.length === true || !r.length ? 'Evaluation: Compliant.' : 'Evaluation: With Deficiency.'); staffView(); }
}
async function decide(id, d) {
  const note = prompt(`Note for ${d} decision:`); if (note === null) return;
  if (await rpc('decide_renewal', {p_id: id, p_decision: d, p_note: note})) { msg('Renewal ' + d + '.'); staffView(); }
}
async function history(id) {
  const {data} = await sb.from('audit_log').select('*').eq('submission_id', id).order('at');
  $('#hist').innerHTML = `<h2 style="margin-top:12px">History</h2><table><tr><th>When</th><th>Action</th><th>Change</th><th>Note</th><th>Actor</th></tr>
  ${(data || []).map(h => `<tr><td>${dt(h.at)}</td><td>${esc(h.action)}</td><td>${esc(h.old_value || '-')} → ${esc(h.new_value)}</td><td>${esc(h.note)}</td><td>${esc((h.actor || '').slice(0, 8))}</td></tr>`).join('')}</table>`;
}
start();