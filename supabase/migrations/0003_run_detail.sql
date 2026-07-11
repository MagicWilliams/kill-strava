-- Run Detail page (spec: progress.md, interviewed 2026-07-08)

-- Cached coach takeaway per run. Generated on first open of the detail page;
-- ChatStore nulls it when a run is corrected so it regenerates with the new data.
alter table runs add column if not exists coach_takeaway text;

-- Athlete's max heart rate (bpm). NULL → app uses the age formula (220 − age).
-- Set by the coach's update_athlete tool when the athlete reports a tested value;
-- onboarding will also write this later.
alter table profiles add column if not exists max_hr smallint check (max_hr between 120 and 230);
