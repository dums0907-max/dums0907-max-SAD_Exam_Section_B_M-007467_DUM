# Student Scholarship Monitoring and Academic Compliance System

**--AVAILABLE ACCOUNTS--
**staff account : staff@adssu.edu.ph / 123456789

scholar accoount : scholar@adssu.edu.ph / 123456789

SAD Laboratory Examination, Section B. Browser-based minimum viable system for Scholar and Scholarship Staff roles.
Stack: HTML, CSS, JavaScript, Supabase (Postgres, Auth, Row Level Security). Synthetic data only.

## Files

| File | Purpose |
|---|---|
| `index.html` | Page structure; loads supabase-js and `app.js` |
| `styles.css` | Styling |
| `app.js` | Login, scholar view, staff view; calls database functions |
| `schema.sql` | Tables, access policies (RLS), workflow functions, seed records B01 to B06 |
| `TEST_RESULTS.md` | Results table for TC01 to TC10 |

## Environment variable names

The app is plain browser JavaScript, so the two values are constants at the top of `app.js`:

- `https://seiqqswbdszbpjtepvmg.supabase.co`: your project URL
- `eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InNlaXFxc3diZHN6YnBqdGVwdm1nIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTI1MTY1OTIsImV4cCI6MjEwODA5MjU5Mn0.20tzuQBeWjcnkfhCi3J75NuaSSvSLZfSl-egIrVB3c8`: your project's public anon key

Never put the service-role key or any password in the source code or screenshots.

## Setup

1. Create a Supabase project.
2. Open SQL Editor, paste all of `schema.sql`, and run it once. It creates the tables, policies, functions and seeds the two programs and six scholars (Academic Year 2026-2027, Semester 1).
3. Under Authentication > Users, create two users (one staff, one scholar) and turn on Auto Confirm User. Test-account details are supplied privately to the instructor.
4. In SQL Editor, create the profiles and link the scholar login to record B01 (replace the emails with the ones you created):

```sql
insert into profiles(id, role, full_name)
select id, 'staff', 'Test Staff' from auth.users where email = 'staff@adssu.edu.ph';
insert into profiles(id, role, full_name)
select id, 'scholar', 'Scholar One' from auth.users where email = 'scholar@adssu.edu.ph';
update scholars set user_id = (select id from auth.users where email = 'scholar@adssu.edu.ph') where student_id = 'B01';
```

5. Put your URL and anon key into `app.js`.

## Run

From the project folder: `python -m http.server 8000`, then open `http://localhost:8000`.
Log in as staff to see the dashboard, or as the scholar to submit and track grades.

## How access is enforced

Scholars cannot write to any table directly. Reads are limited by Row Level Security (a scholar reads only rows linked to their own account). All writes go through database functions (`submit_grades`, `resubmit_grades`, `verify_submission`, `evaluate_submission`, `decide_renewal`), which check the role, validate input, and write the history log. Policy thresholds are read from the `programs` table, not from code.

## Known defects and limitations

Update this list after testing. Report defects honestly.

- A scholar login is linked to a scholar record by SQL (step 4), not from a screen.
- Only record B01 has a login; the other seeded scholars (B02 to B06) cannot sign in.
- Verification reasons and decision notes use browser prompt boxes.
- The grade-document reference is text only; there is no file upload (out of scope).
- Add any defect found during testing here.

## Out of scope (by exam rules)

Live Registrar API, SMS, machine learning, payments, full appeal workflow, policy exceptions. The app never alters official grades or releases payments.
