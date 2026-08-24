-- Onboarding (spec: progress.md, interviewed 2026-07-09)

-- Gate: any signed-in user without this timestamp gets the onboarding takeover.
alter table profiles add column if not exists onboarded_at timestamptz;

-- Facts the interview collects (all chat-mutable afterward).
alter table profiles add column if not exists birthdate date;          -- personalizes the HR formula (kills hardcoded age 28)
alter table profiles add column if not exists injury_notes text;       -- past-year injuries/niggles → plan caution + check-in follow-ups
alter table profiles add column if not exists strength_notes text;     -- current strength/cross-training habits
alter table profiles add column if not exists wants_strength boolean not null default false;  -- prescribe it, don't just avoid it
