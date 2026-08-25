-- Coach confirm cards survive an app restart (issue #9)
--
-- The coach's proposed change lived only in ChatStore's memory. Quit the app before tapping
-- Confirm and the offer was gone: history replayed "I'll log that as 8.0 miles" with no card
-- beneath it, so the change was neither applied nor refused and nothing on screen said which
-- (progress.md, 2026-07-08 night).
--
-- A proposal belongs to the message that made it, so it lives on the row rather than in a
-- table of its own — one read of coach_messages restores the conversation and its open offers
-- together, and there is no second thing to keep in step.

alter table coach_messages add column if not exists proposed_action jsonb;
alter table coach_messages add column if not exists action_state text;

alter table coach_messages drop constraint if exists coach_messages_action_state_check;
alter table coach_messages add constraint coach_messages_action_state_check
  check (action_state is null or action_state in ('pending','applied','dismissed','failed'));

comment on column coach_messages.proposed_action is
  'The coach tool call this message proposed, as sent by the coach function. NULL for ordinary messages and for all history predating this column.';

comment on column coach_messages.action_state is
  'Whether the athlete resolved the proposal. Set alongside proposed_action and NULL without it. Deliberately has no ''applying'' value: a write in flight is not a fact worth storing — see ios/Tempo/Engine/CoachActionState.swift.';
