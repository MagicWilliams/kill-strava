-- LOCAL STACK ONLY: see ../README.md. What the coach function would have written for the
-- fictional runner. Every figure here was checked against what the app computed from the seed.
begin;
-- The past sessions the app matched its runs to get targets close to what was run.
update sessions s set target_distance_m = round(r.distance_m / 1609.34) * 1609
  from runs r where r.id = s.run_id;

update runs set coach_takeaway = 'A steady 12.6 miles at 9:28, with heart rate holding at 152. That''s the right effort for a long run three weeks after a half. Nothing here needs fixing, so Tuesday''s tempo stays on the plan.'
  where start_time::date = '2026-11-01';
update runs set coach_takeaway = 'The middle three miles are what count here. You held about 7:30 and your heart rate stayed controlled, which is well inside the 8:00 pace you need in March. The easy miles on either side stayed easy, and that''s why the quality held.',
    title = 'Thursday tempo', rpe = 5, notes = 'Felt smooth after the second rep. Cool morning.'
  where start_time::date = '2026-10-29';
update runs set coach_takeaway = 'An easy 5.4 miles at 9:13 and 141 bpm. Exactly what the day before a tempo should look like.'
  where start_time::date = '2026-10-28';

insert into coach_threads (id, user_id, title, summary, started_at, last_message_at)
  select '33333333-3333-4333-8333-333333333331', id, null, null, '2026-11-03T20:40:00Z', '2026-11-03T20:44:00Z' from profiles;
insert into coach_threads (id, user_id, title, summary, started_at, last_message_at)
  select '33333333-3333-4333-8333-333333333332', id, 'Racing the half', 'Ran 1:39:05 in October. Agreed to take a recovery week before the build, and that the result supports a 3:30 goal.', '2026-10-12T16:00:00Z', '2026-10-12T16:20:00Z' from profiles;
insert into coach_threads (id, user_id, title, summary, started_at, last_message_at)
  select '33333333-3333-4333-8333-333333333333', id, 'Setting up the block', 'Chose Harbor City in March with a 3:30 goal, five days a week and Sunday long runs. Started from about 30 miles a week.', '2026-09-27T17:00:00Z', '2026-09-27T17:30:00Z' from profiles;

insert into coach_messages (user_id, thread_id, role, content, created_at)
  select id, '33333333-3333-4333-8333-333333333331', 'user', 'Sunday felt harder than it should have. Am I still on track for 3:30?', '2026-11-03T20:40:00Z' from profiles;
insert into coach_messages (user_id, thread_id, role, content, created_at)
  select id, '33333333-3333-4333-8333-333333333331', 'coach', 'Yes. Your projection is 3:25:54 against a 3:30:00 goal. Sunday''s 12.6 miles at 9:28 and 152 bpm is about right three weeks after a race.', '2026-11-03T20:41:00Z' from profiles;
insert into coach_messages (user_id, thread_id, role, content, created_at)
  select id, '33333333-3333-4333-8333-333333333331', 'user', 'Good. I''m traveling Sunday, can the long run move to Saturday?', '2026-11-03T20:43:00Z' from profiles;
insert into coach_messages (user_id, thread_id, role, content, created_at, proposed_action, action_state)
  select p.id, '33333333-3333-4333-8333-333333333331', 'coach', 'Sure. Saturday''s easy run gives way, and Thursday''s tempo stays.', '2026-11-03T20:44:00Z',
    jsonb_build_object('type','update_session','summary','Move Sunday''s 15 mi long run to Saturday, Nov 7','session_id',s.id,'date','2026-11-07'), 'pending'
  from profiles p, sessions s where s.date = '2026-11-08';
insert into coach_messages (user_id, thread_id, role, content, created_at)
  select id, '33333333-3333-4333-8333-333333333332', 'coach', 'A 1:39:05 half is a good reason to trust a 3:30 goal. Take this week easy.', '2026-10-12T16:20:00Z' from profiles;
insert into coach_messages (user_id, thread_id, role, content, created_at)
  select id, '33333333-3333-4333-8333-333333333333', 'coach', 'Five days a week, long runs on Sunday, starting from about 30 miles. Your plan is ready.', '2026-09-27T17:30:00Z' from profiles;
commit;
