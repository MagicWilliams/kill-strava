-- Coach threads and a memory that outlives 24 messages (#87).
--
-- ⚠️  UNAPPLIED. David applies it. Apply before merging the app change that reads it: until
--     these tables exist the Coach tab's thread list reads as unreachable and the coach has
--     no memory, which is the state it is in today — so the order is "migration, then build".
--
-- ── What this is ─────────────────────────────────────────────────────────────────────
-- The Coach tab is one endless thread, and the coach only ever sees the last 24 messages
-- (`ChatStore.send`, `messages.suffix(24)`). Everything older is forgotten: the race plan,
-- the injury history, what was already agreed. The transcript keeps it; the coach does not.
--
-- Two separate problems, two tables:
--
--  1. **Threads.** A conversation gets a start, an end, a title and a recap, so the archive
--     is navigable and a new chat can start clean. `coach_messages.thread_id` says which
--     conversation a message belongs to.
--  2. **Memory.** A durable fact ("goal is sub-3:15 at Chicago", "left calf, 2023") is not a
--     message and must not age out with one. It is recorded once, carried into every later
--     conversation's context, and retired when it stops being true — never deleted, so the
--     ledger of what the coach believed and when stays readable.
--
-- ── Order matters ────────────────────────────────────────────────────────────────────
-- 1. `coach_threads` — `coach_messages.thread_id` and `coach_memory.source_thread_id`
--    reference it.
-- 2. `coach_messages.thread_id`, then the backfill: every row that exists today lands in one
--    "Before threads" thread per user. A null `thread_id` would be invisible to a thread-
--    scoped read, which for David is 2,000-odd messages of real coaching history.
-- 3. `coach_memory`.
--
-- Additive: no existing column changes and no message is rewritten beyond gaining a
-- thread_id. The backfill is idempotent — it only ever touches rows where thread_id is null.
--
-- Reversible with:
--   drop table if exists coach_memory;
--   alter table coach_messages drop column if exists thread_id;
--   drop table if exists coach_threads;

-- ── 1. Threads ───────────────────────────────────────────────────────────────────────
create table if not exists coach_threads (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references auth.users(id) on delete cascade,
  -- Both written by the coach's summarize pass when the thread is finished, so both are
  -- null while it is live. The app supplies the standing-in line; nothing invents a recap.
  title           text,
  summary         text,
  started_at      timestamptz not null default now(),
  -- Touched by the app on every message it inserts. This, not `started_at`, is what the
  -- list orders by and what the 6-hour idle rule measures from: a conversation opened on
  -- Monday and continued on Thursday is Thursday's conversation.
  last_message_at timestamptz not null default now(),

  check (last_message_at >= started_at)
);

comment on table coach_threads is
  'One coaching conversation (#87). title/summary are written by the coach''s summarize pass once the thread is finished — null means "still live, or not summarized yet". last_message_at drives both list order and the idle rule (Engine/CoachThreads.swift).';

create index if not exists coach_threads_user_recent_idx
  on coach_threads(user_id, last_message_at desc);

alter table coach_threads enable row level security;

-- Same policy as `runs` and `coach_messages` (0001): every row is the athlete's own.
-- Dropped first, as in 0016, so the whole file is re-runnable.
drop policy if exists "own coach threads" on coach_threads;
create policy "own coach threads" on coach_threads
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- ── 2. Messages belong to a thread ───────────────────────────────────────────────────
alter table coach_messages
  add column if not exists thread_id uuid references coach_threads(id) on delete cascade;

-- Leads with thread_id because every read is "this thread, newest first" — the same page
-- the Coach tab asks for (`ChatHistory.pageSize`). It also covers the foreign key, which
-- is what the performance advisor flagged on 0012's fkeys (#98) and on goals.race_run_id
-- (#212): without it, deleting a thread full-scans a table that only grows.
create index if not exists coach_messages_thread_time_idx
  on coach_messages(thread_id, created_at desc);

comment on column coach_messages.thread_id is
  'The conversation this message belongs to (#87). Null only between this migration and its backfill: a thread-scoped read cannot see a null, so the app treats one as unreachable history rather than as an empty chat.';

-- The backfill. Every message that exists predates threads, so each user gets exactly one
-- thread holding all of theirs, spanning the real dates of what it contains. Summarized as
-- itself rather than left for the coach to summarize: a 2,000-message archive is not what
-- the summarize pass is sized for, and "this is everything from before" is the honest recap.
with carried as (
  select user_id, min(created_at) as first_at, max(created_at) as last_at
  from coach_messages
  where thread_id is null
  group by user_id
), made as (
  insert into coach_threads (user_id, title, summary, started_at, last_message_at)
  select
    user_id,
    'Before threads',
    'Everything said before this conversation was split into threads.',
    first_at,
    last_at
  from carried
  returning id, user_id
)
update coach_messages m
set thread_id = made.id
from made
where m.user_id = made.user_id and m.thread_id is null;

-- ── 3. Memory ────────────────────────────────────────────────────────────────────────
create table if not exists coach_memory (
  id               uuid primary key default gen_random_uuid(),
  user_id          uuid not null references auth.users(id) on delete cascade,
  -- One fact, in the coach's words, written to be read cold in a conversation months later.
  fact             text not null check (length(btrim(fact)) > 0),
  -- Where it was learned, for "why does the coach think that". `on delete set null` and not
  -- cascade: deleting a conversation must never delete what it taught the coach.
  source_thread_id uuid references coach_threads(id) on delete set null,
  created_at       timestamptz not null default now(),
  -- Retired, never deleted (the `shoes` rule, 0016). A fact that stopped being true is
  -- history, and a coach that silently forgot one would be impossible to debug.
  retired_at       timestamptz,

  check (retired_at is null or retired_at >= created_at)
);

comment on table coach_memory is
  'Durable facts the coach carries across conversations (#87), recorded by its `remember` tool after the athlete confirms. Active = retired_at is null; those are what rides in the athlete context. Retire, never delete.';

-- The active set is the only thing the app reads, and it reads it on every Coach tab open.
create index if not exists coach_memory_active_idx
  on coach_memory(user_id, created_at desc) where retired_at is null;

-- Covers the foreign key (see the thread_id index above).
create index if not exists coach_memory_source_thread_idx
  on coach_memory(source_thread_id);

alter table coach_memory enable row level security;

drop policy if exists "own coach memory" on coach_memory;
create policy "own coach memory" on coach_memory
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- ── Check (changes nothing) ──────────────────────────────────────────────────────────
--
-- Every message is in exactly one thread — expect 0 rows:
--
--   select count(*) from coach_messages where thread_id is null;
--
-- One carried thread per user, spanning its real contents — expect "Before threads" with
-- the first and last dates of that user's history, and a count matching their archive:
--
--   select t.title, t.started_at, t.last_message_at, count(m.id) as messages
--   from coach_threads t left join coach_messages m on m.thread_id = t.id
--   group by t.id, t.title, t.started_at, t.last_message_at
--   order by t.last_message_at desc;
--
-- Memory starts empty; the coach fills it as it learns:
--
--   select count(*) from coach_memory;
