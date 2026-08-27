-- Coach proposals outlive the app session.
--
-- A proposal is a write the coach wants to make and the athlete has not yet accepted.
-- Until now it lived only in memory on the device: quitting the app before tapping
-- Confirm silently discarded the offer, while the replayed chat still showed the coach
-- promising the change. The athlete was left reading "I'll log that as 8.0 miles" with
-- no way to accept it and nothing saying the offer had expired.
--
-- The action belongs to the message that proposed it, so it lives on that row rather
-- than in a table of its own.

alter table coach_messages
  add column if not exists proposed_action jsonb,
  add column if not exists action_state    text;

-- Deliberately NOT a state: 'applying'. That is an in-flight UI state, and an app that
-- dies mid-write cannot know whether the write landed. Persisting it would let the app
-- come back asserting a state it can't verify; instead the row stays 'pending' until a
-- write is confirmed to have succeeded, and the athlete is re-offered the action.
alter table coach_messages
  drop constraint if exists coach_messages_action_state_check;
alter table coach_messages
  add constraint coach_messages_action_state_check
  check (action_state is null or action_state in ('pending', 'applied', 'dismissed', 'failed'));

-- Every existing row predates this column and had no card to restore.
-- Left as NULL, which the app reads as "this message never carried an action".

comment on column coach_messages.proposed_action is
  'The tool-call params the coach proposed, as returned by the coach Edge Function. NULL for ordinary messages.';
comment on column coach_messages.action_state is
  'pending | applied | dismissed | failed. NULL when the message carries no action.';
