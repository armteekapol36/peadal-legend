-- =================================================================
-- PEADAL LEGEND — Supabase Schema
-- รันใน Supabase Dashboard → SQL Editor → New Query
-- =================================================================

-- 1. ACCOUNTS
create table if not exists accounts (
  employee_id   text primary key check (employee_id ~ '^[A-Za-z0-9_-]{3,20}$'),
  title         text check (char_length(title) <= 20),
  first_name    text not null check (char_length(first_name) between 1 and 60 and first_name !~ '[<>]'),
  last_name     text not null check (char_length(last_name)  between 1 and 60 and last_name  !~ '[<>]'),
  office        text check (office is null or office in ('สำนักงานใหญ่','กฟน.1','กฟน.2','กฟน.3','กฟฉ.1','กฟฉ.2','กฟฉ.3','กฟก.1','กฟก.2','กฟก.3','กฟต.1','กฟต.2','กฟต.3')),
  department    text check (department is null or (char_length(department) <= 80 and department !~ '[<>]')),
  birth_year    int check (birth_year is null or birth_year between 2400 and 2600),   -- พ.ศ.
  weight        numeric check (weight is null or weight between 20 and 300),
  height        numeric check (height is null or height between 100 and 250),
  is_state_athlete boolean default false,
  pass_hash     text not null check (char_length(pass_hash) between 8 and 200),
  consent       boolean default false,
  is_admin      boolean default false,
  disabled      boolean default false,
  created_at    timestamptz default now()
);

-- 2. PROFILES (gear, photo_url, achievements — kept as JSONB because the
--    character creator schema evolves often and JSON is more flexible here)
-- Keyed by employee_id (not name): a name is just text someone typed and people's names get corrected, so it
-- must never be a primary key for data this important — employee_id is unique and never changes. The app always
-- resolves the CURRENT display name live from accounts, so renaming someone in accounts is enough on its own;
-- nothing here needs to change to pick it up.
create table if not exists profiles (
  employee_id text primary key references accounts(employee_id),
  name    text check (name is null or char_length(name) <= 121),   -- last-known display name, for admins browsing the table only — never authoritative, the app never reads it
  data    jsonb not null default '{}'
            check (jsonb_typeof(data) = 'object' and octet_length(data::text) < 200000)
);

-- 3. ACTIVITY ENTRIES
-- employee_id is the real link to accounts; name is a denormalised snapshot kept for admin/decision-log
-- readability and as a fallback for any legacy row from before this column existed. The app always prefers
-- employee_id -> accounts for grouping/leaderboards/history, so correcting someone's name in accounts fixes how
-- their past entries display too, without touching a single row here.
create table if not exists entries (
  id             text primary key check (char_length(id) between 1 and 80),
  employee_id    text references accounts(employee_id),
  name           text not null check (char_length(name) between 1 and 121),
  office         text check (office is null or char_length(office) <= 40),
  type           text not null check (type in ('ride','run')),
  distance_km    numeric not null check (distance_km > 0 and distance_km <= 1000),
  date           date not null check (date >= date '2020-01-01' and date <= current_date + 1),
  status         text not null default 'pending'
                   check (status in ('pending','approved','rejected','flagged')),
  flags          jsonb default '[]'
                   check (jsonb_typeof(flags) = 'array' and octet_length(flags::text) < 5000),
  community_flags jsonb default '[]'
                   check (jsonb_typeof(community_flags) = 'array' and octet_length(community_flags::text) < 30000),
  note           text check (note is null or char_length(note) <= 500),
  ai_read        jsonb check (ai_read is null or (jsonb_typeof(ai_read) = 'object' and octet_length(ai_read::text) < 5000)),
  photo_url      text check (photo_url is null or (photo_url ~ '^https://' and char_length(photo_url) <= 500)),  -- Supabase Storage URL
  exif_date      date,           -- date read from the photo's EXIF (shown to admins when reviewing)
  duration_min   numeric check (duration_min is null or (duration_min > 0 and duration_min <= 2880)),  -- moving/elapsed time read from the photo, when OCR finds one — used to pre-fill the Share Card's calorie estimate
  demo           boolean default false,
  submitted_at   timestamptz default now()
);
create index if not exists entries_employee_idx on entries (employee_id);

-- 4. APP SETTINGS (single row, id always = 1)
create table if not exists app_settings (
  id                  int primary key default 1,
  banner              text default '' check (char_length(banner) <= 300),
  season_close_date   date,
  threshold_ride      numeric default 150 check (threshold_ride > 0 and threshold_ride <= 1000),
  threshold_run       numeric default 50  check (threshold_run  > 0 and threshold_run  <= 1000),
  road_to_legend      jsonb not null default '{}'::jsonb
    check (jsonb_typeof(road_to_legend) = 'object' and octet_length(road_to_legend::text) < 200000),  -- "Road to Legend" training-calendar day overrides (admin-edited days only — the default weekly template lives in the app, not the DB)
  constraint only_one_row check (id = 1)
);
insert into app_settings (id) values (1) on conflict do nothing;

-- 5. DECISION LOG
create table if not exists decision_log (
  id            bigserial primary key,
  entry_id      text,
  name          text,
  office        text,
  type          text,
  distance_km   numeric,
  date          date,
  status        text check (status in ('approved','rejected')),
  decided_by    text check (char_length(decided_by) <= 130),
  decided_at    timestamptz default now()
);

-- 5b. INDEXES — leaderboards/admin filter on these; keyset-stable paging uses (submitted_at, id)
create index if not exists entries_status_idx     on entries (status);
create index if not exists entries_name_idx       on entries (name);
create index if not exists entries_date_idx       on entries (date);
create index if not exists entries_submitted_idx  on entries (submitted_at desc, id);
create index if not exists declog_decided_idx     on decision_log (decided_at desc);

-- 6. EVIDENCE PHOTOS bucket — created further down by SQL (no dashboard click-through needed)

-- =================================================================
-- RLS — Row Level Security
-- This app uses its own app-level auth (employee_id + hash) so all
-- requests hit Supabase through the anon key.
-- For an internal org tool this simple policy works well:
-- everyone can read public data; admin flag controls write access.
-- =================================================================

-- Explicit privileges. Supabase projects differ in whether new tables are auto-granted to the API roles; being
-- explicit makes this file work either way. RLS below still decides which rows each request can touch.
grant usage on schema public to anon, authenticated;
grant select, insert, update, delete on profiles, entries, app_settings to anon, authenticated;
grant select, insert on decision_log to anon, authenticated;            -- append-only audit trail
grant usage, select on sequence decision_log_id_seq to anon, authenticated;

alter table accounts         enable row level security;
alter table profiles         enable row level security;
alter table entries          enable row level security;
alter table app_settings     enable row level security;
alter table decision_log     enable row level security;

-- Accounts: read name+office+employee_id for leaderboard, full read for admins
create policy "accounts_read_public" on accounts
  for select using (true);

create policy "accounts_insert" on accounts
  for insert with check (true);

create policy "accounts_update" on accounts
  for update using (true);   -- app enforces auth before calling

-- =================================================================
-- SECURITY: pass_hash must never be selectable by the public/anon role.
-- RLS is row-level only — it can't hide one column while allowing others —
-- so this is enforced separately with a column-level GRANT. Without this,
-- anyone holding the anon key (it's embedded in the HTML, so effectively
-- everyone) could query GET /rest/v1/accounts?select=pass_hash directly
-- and download every employee's password hash in one request, even though
-- the app's own JS never asks for that column.
-- =================================================================
revoke select on accounts from anon, authenticated;
grant select (
  employee_id, title, first_name, last_name, office, department,
  birth_year, weight, height, is_state_athlete, consent, is_admin,
  disabled, created_at
) on accounts to anon, authenticated;
grant insert, update on accounts to anon, authenticated;

-- Login verification happens through this function instead of ever
-- selecting pass_hash to the client: the browser computes the hash of the
-- password the person typed (same as it always did) and this function
-- compares it against the stored hash server-side, returning only a
-- boolean — the real stored hash never leaves the database.
-- Login attempts are counted per employee_id: 8 failures inside 10 minutes locks that ID out for the rest of the
-- window (the RPC raises 'too_many_attempts'). Without this, anyone holding the anon key could try passwords
-- against check_login at full speed. A correct password clears the counter.
create table if not exists login_attempts (
  employee_id text not null,
  at          timestamptz not null default now()
);
create index if not exists login_attempts_idx on login_attempts (employee_id, at);
alter table login_attempts enable row level security;      -- no policies: unreachable through the REST API
revoke all on login_attempts from anon, authenticated;

create or replace function check_login(p_employee_id text, p_password_hash text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  fails int;
  ok boolean;
begin
  delete from login_attempts where at < now() - interval '1 day';
  select count(*) into fails from login_attempts
   where employee_id = p_employee_id and at > now() - interval '10 minutes';
  if fails >= 8 then
    raise exception 'too_many_attempts';
  end if;
  select exists(
    select 1 from accounts
    where employee_id = p_employee_id and pass_hash = p_password_hash
  ) into ok;
  if ok then
    delete from login_attempts where employee_id = p_employee_id;
  else
    insert into login_attempts (employee_id) values (p_employee_id);
  end if;
  return ok;
end;
$$;
grant execute on function check_login(text, text) to anon, authenticated;

-- Community report: appended inside the database so two people reporting at once (or an admin approving from a
-- stale page) can't overwrite each other. Returns null if this person already reported it (or the entry is gone),
-- otherwise the entry's new status and full list of reports.
-- reporterId lets the dedup check (below) survive a rename: a renamed member can't report the same entry twice
-- just because their display name changed. Legacy rows from before this column existed have no reporterId, so
-- the check falls back to matching by name for those specifically — never breaks old data.
create or replace function report_entry(p_id text, p_reason text, p_reporter text, p_reporter_id text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r jsonb;
begin
  update entries e set
    community_flags = coalesce(e.community_flags, '[]'::jsonb) || jsonb_build_array(jsonb_build_object(
        'reason', left(coalesce(nullif(trim(p_reason), ''), 'ไม่ระบุเหตุผล'), 300),
        'at', now(),
        'reporterName', left(p_reporter, 121),
        'reporterId', p_reporter_id)),
    status = case when e.status = 'approved' then 'flagged' else e.status end
  where e.id = p_id
    and not exists (
      select 1 from jsonb_array_elements(coalesce(e.community_flags, '[]'::jsonb)) f
      where (p_reporter_id is not null and f->>'reporterId' = p_reporter_id)
         or (f->>'reporterId' is null and f->>'reporterName' = p_reporter)
    )
  returning jsonb_build_object('status', e.status, 'community_flags', e.community_flags) into r;
  return r;
end;
$$;
grant execute on function report_entry(text, text, text, text) to anon, authenticated;


-- =================================================================
-- IMPORTANT LIMITATION — read before relying on these policies:
-- This app has no real server-verified session (no Supabase Auth), so RLS
-- can't tell "the admin" apart from anyone else holding the anon key — the
-- key is embedded in the HTML, so that's effectively the public. Genuinely
-- restricting who can approve entries, edit others' profiles, or change
-- settings requires migrating login to Supabase Auth (or a custom Edge
-- Function checking admin status server-side) — a real project on its own,
-- not a policy tweak. Ask if you want that done properly.
--
-- What CAN be tightened safely without breaking any real feature or needing
-- to know who's asking is done below: nobody, ever, legitimately needs to
-- UPDATE or DELETE a decision-log row, or delete a REAL (non-demo) entry or
-- profile — only the demo-data tools do that, and only to demo-flagged
-- rows. So those specific operations are blocked outright or scoped to
-- demo=true, closing off the easiest ways to tamper with results or cover
-- tracks even though full per-user authorization isn't possible yet.
-- =================================================================

-- Profiles: public read; write allowed (no real admin/ownership check possible
-- yet — see note above) but deleting a real (non-demo) profile is blocked
create policy "profiles_read" on profiles for select using (true);
create policy "profiles_insert" on profiles for insert with check (true);
create policy "profiles_update" on profiles for update using (true);
create policy "profiles_delete_demo_only" on profiles for delete
  using (coalesce((data->>'demo')::boolean, false) = true);

-- Entries: public read; write allowed (see note above) but deleting a real
-- (non-demo) entry is blocked — only entries.demo = true can be deleted,
-- which is all clearDemo() ever needs
create policy "entries_read" on entries for select using (true);
create policy "entries_insert" on entries for insert with check (true);
create policy "entries_update" on entries for update using (true);
create policy "entries_delete_demo_only" on entries for delete using (demo = true);

-- App settings: public read; write allowed (see note above — a real
-- admin-only lock here needs the Auth migration too)
create policy "settings_read" on app_settings for select using (true);
create policy "settings_write" on app_settings for all using (true);

-- Decision log: append-only audit trail — insert and read, but nobody
-- (not even a compromised anon key) can rewrite or erase past entries
create policy "declog_insert" on decision_log for insert with check (true);
create policy "declog_read" on decision_log for select using (true);

-- =================================================================
-- Storage: evidence bucket policies (bucket created as PUBLIC — the app
-- calls getPublicUrl(), which only produces working links for a public
-- bucket. A private bucket would need signed, expiring URLs instead, which
-- this app doesn't implement. Photos are workout screenshots at unguessable
-- random paths, not sensitive documents, so public is the practical choice
-- here — say so if you'd rather switch to private + signed URLs instead.)
-- =================================================================
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  values ('evidence', 'evidence', true, 5242880, array['image/jpeg','image/png','image/webp'])
  on conflict (id) do update set public = true, file_size_limit = 5242880,
                                 allowed_mime_types = array['image/jpeg','image/png','image/webp'];
create policy "evidence_read" on storage.objects for select using (bucket_id = 'evidence');
create policy "evidence_insert" on storage.objects for insert
  with check (bucket_id = 'evidence' and name ~ '^evidence/[A-Za-z0-9_-]+\.(jpg|png)$');
create policy "evidence_delete" on storage.objects for delete using (bucket_id = 'evidence');  -- lets the 45-day evidence-photo cleanup remove old files

-- =================================================================
-- Feed: posts (photo-only, no caption), likes, and comments. Same open RLS
-- posture as the rest of this pre-Auth-migration project (see the note on
-- entries/accounts above re: auth.uid()).
-- =================================================================
create table if not exists posts (
  id            text primary key check (char_length(id) between 1 and 80),
  employee_id   text not null references accounts(employee_id),
  name          text not null check (char_length(name) between 1 and 121),
  photo_url     text not null check (photo_url ~ '^https://'),
  created_at    timestamptz not null default now()
);
create index if not exists posts_created_idx on posts (created_at desc);
create index if not exists posts_employee_idx on posts (employee_id);

create table if not exists post_likes (
  post_id       text not null references posts(id) on delete cascade,
  employee_id   text not null references accounts(employee_id),
  created_at    timestamptz not null default now(),
  primary key (post_id, employee_id)
);

create table if not exists post_comments (
  id            text primary key check (char_length(id) between 1 and 80),
  post_id       text not null references posts(id) on delete cascade,
  employee_id   text not null references accounts(employee_id),
  name          text not null check (char_length(name) between 1 and 121),
  text          text not null check (char_length(text) between 1 and 200),
  created_at    timestamptz not null default now()
);
create index if not exists post_comments_post_idx on post_comments (post_id);

alter table posts enable row level security;
alter table post_likes enable row level security;
alter table post_comments enable row level security;

create policy "posts_read" on posts for select using (true);
create policy "posts_insert" on posts for insert with check (true);
create policy "posts_delete" on posts for delete using (true);
create policy "post_likes_read" on post_likes for select using (true);
create policy "post_likes_insert" on post_likes for insert with check (true);
create policy "post_likes_delete" on post_likes for delete using (true);
create policy "post_comments_read" on post_comments for select using (true);
create policy "post_comments_insert" on post_comments for insert with check (true);
create policy "post_comments_delete" on post_comments for delete using (true);
grant select, insert, delete on posts, post_likes, post_comments to anon, authenticated;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  values ('posts', 'posts', true, 2097152, array['image/jpeg','image/png'])
  on conflict (id) do update set public = true, file_size_limit = 2097152,
                                 allowed_mime_types = array['image/jpeg','image/png'];
create policy "posts_bucket_read" on storage.objects for select using (bucket_id = 'posts');
create policy "posts_bucket_insert" on storage.objects for insert
  with check (bucket_id = 'posts' and name ~ '^posts/[A-Za-z0-9_-]+\.(jpg|png)$');
create policy "posts_bucket_delete" on storage.objects for delete using (bucket_id = 'posts');

