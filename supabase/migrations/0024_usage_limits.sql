-- Per-user limits on the calls that spend Anthropic money.
--
-- ⚠️  UNAPPLIED. David applies it. The functions tolerate its absence (see below), so it can
--     go in before or after they deploy; nothing is enforced until both are live.
--
-- ── Why this exists ──────────────────────────────────────────────────────────────────
-- Tempo is free, and anyone gets an anonymous account on first launch. `coach` had no check
-- at all, and `verify_jwt` does not help: the publishable key shipped in the app is itself a
-- valid JWT. Once the app is public, anyone can run up the Anthropic bill without limit.
--
-- ── Why the decision is here and not in the function ─────────────────────────────────
-- A check and a count made in two round trips let concurrent calls all see "under the limit"
-- and all go through, which is precisely what someone scripting this would do. So one
-- transaction checks and counts, behind an advisory lock per user and kind.
--
-- ── Why `claim_usage` is SECURITY DEFINER, and why it is safe to expose ──────────────
-- It has to write counters the caller may not touch: a table the athlete can write under RLS
-- is one they can reset. With no policies on either table, this function is the only way in.
-- Calling it directly through PostgREST only spends the caller's own allowance. Its limits
-- come from `usage_limits`, not from an argument, so a caller cannot widen them, and a kind
-- with no limits row writes nothing, so it cannot be used to grow the table either.
--
-- ── Failure modes the function relies on ─────────────────────────────────────────────
--  - The publishable key (`anon`) has no EXECUTE here. That is how a call with no real user
--    is told apart from a real one, so `anon` stays revoked below.
--  - A valid JWT for a deleted user fails the foreign key and reads as `no_user`, not as an
--    error: the function treats errors as "the limiter is down" and lets the call through.
--
-- Tuning needs no deploy, which matters because `coach` is live:
--   update usage_limits set max_calls = 80 where kind = 'chat' and window_s = 3600;
--
-- Reversible with:
--   drop function if exists claim_usage(text);
--   drop table if exists usage_counters;
--   drop table if exists usage_limits;

-- ── 1. The limits ────────────────────────────────────────────────────────────────────
create table if not exists usage_limits (
  -- chat | takeaway | block_review | summarize | plan. Separate so that a burst of background
  -- work (takeaways, a backlog of thread recaps) can never use up the athlete's chat.
  kind      text    not null,
  window_s  integer not null check (window_s > 0),
  max_calls integer not null check (max_calls >= 0),
  primary key (kind, window_s)
);

comment on table usage_limits is
  'Per-user call limits per kind and window. Read by claim_usage; edit a row to tune a limit, no deploy needed. A kind with no rows is unlimited.';

-- `do nothing`, so re-running this file never undoes a limit tuned by hand.
insert into usage_limits (kind, window_s, max_calls) values
  ('chat',         3600,  50),
  ('chat',         86400, 120),
  ('takeaway',     3600,  30),
  ('takeaway',     86400, 60),
  ('summarize',    3600,  20),
  ('summarize',    86400, 40),
  ('block_review', 3600,  10),
  ('block_review', 86400, 20),
  ('plan',         3600,  10),
  ('plan',         86400, 20)
on conflict (kind, window_s) do nothing;

-- ── 2. The counters ──────────────────────────────────────────────────────────────────
-- One row per user, kind and fixed window rather than one per call: the row count stays
-- bounded however hard someone hammers this, and a read is a primary-key lookup.
--
-- Fixed windows let a caller spend two windows' worth across a boundary. That is fine for a
-- cost limit, and it gives the athlete an exact time the limit resets.
create table if not exists usage_counters (
  user_id      uuid        not null references auth.users(id) on delete cascade,
  kind         text        not null,
  window_s     integer     not null,
  window_start timestamptz not null,
  calls        integer     not null default 0,
  primary key (user_id, kind, window_s, window_start)
);

comment on table usage_counters is
  'Calls that were allowed, per user, kind and fixed window. Written only by claim_usage. A refused call is not counted, so hammering a limit never pushes back its reset.';

-- ── 3. Nobody reads or writes these directly ─────────────────────────────────────────
-- RLS with no policies, and the default Supabase grants taken away as well.
alter table usage_limits enable row level security;
alter table usage_counters enable row level security;
revoke all on usage_limits from anon, authenticated;
revoke all on usage_counters from anon, authenticated;

-- ── 4. Check and count, in one transaction ───────────────────────────────────────────
-- Returns one of:
--   {"allowed": true}
--   {"allowed": false, "reason": "limited", "retry_after_s": 1234}
--   {"allowed": false, "reason": "no_user"}
create or replace function claim_usage(p_kind text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid     uuid := auth.uid();
  lim     record;
  bucket  timestamptz;
  used    integer;
  wait_s  integer := 0;
begin
  if uid is null then
    return jsonb_build_object('allowed', false, 'reason', 'no_user');
  end if;

  perform pg_advisory_xact_lock(hashtextextended(uid::text || ':' || p_kind, 0));

  for lim in
    select window_s, max_calls from public.usage_limits where kind = p_kind
  loop
    bucket := to_timestamp(floor(extract(epoch from now()) / lim.window_s) * lim.window_s);
    select calls into used from public.usage_counters
      where user_id = uid and kind = p_kind and window_s = lim.window_s and window_start = bucket;
    if coalesce(used, 0) >= lim.max_calls then
      -- The latest of the exhausted windows: telling the athlete the hour resets in ten
      -- minutes is a lie if the day's allowance is gone too.
      wait_s := greatest(wait_s, ceil(extract(epoch from
        bucket + make_interval(secs => lim.window_s) - now()))::integer);
    end if;
  end loop;

  if wait_s > 0 then
    return jsonb_build_object('allowed', false, 'reason', 'limited', 'retry_after_s', wait_s);
  end if;

  -- All windows or none, so a refusal from one window never spends another.
  insert into public.usage_counters (user_id, kind, window_s, window_start, calls)
    select uid, p_kind, l.window_s,
           to_timestamp(floor(extract(epoch from now()) / l.window_s) * l.window_s), 1
    from public.usage_limits l
    where l.kind = p_kind
  on conflict (user_id, kind, window_s, window_start)
    do update set calls = public.usage_counters.calls + 1;

  -- Self-cleaning, and only ever the caller's own rows. Kept well past the longest window so
  -- real usage can be read back when a limit needs tuning.
  delete from public.usage_counters
    where user_id = uid and window_start < now() - interval '35 days';

  return jsonb_build_object('allowed', true);
exception
  when foreign_key_violation then
    return jsonb_build_object('allowed', false, 'reason', 'no_user');
end;
$$;

comment on function claim_usage(text) is
  'Atomically checks the caller against usage_limits and counts the call if it is allowed. Called by the coach and plan edge functions with the caller''s JWT, immediately before they spend Anthropic money.';

revoke all on function claim_usage(text) from public, anon;
grant execute on function claim_usage(text) to authenticated;
