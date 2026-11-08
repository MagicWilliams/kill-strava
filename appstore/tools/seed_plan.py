#!/usr/bin/env python3
"""Prints SQL for the fictional runner's profile, goal and plan. LOCAL STACK ONLY: see ../README.md."""
import datetime as dt
import sys

uid = sys.argv[1]
start = dt.date(2026, 9, 28)   # Monday, week 1. 24 weeks ends on race day.
phases = ["base"] * 5 + ["build"] * 10 + ["peak"] * 6 + ["taper"] * 3
miles = [30, 32, 34, 28, 35, 37, 39, 33, 41, 43, 45, 37, 47, 49, 40, 50, 52, 54, 44, 55, 50, 40, 30, 20]
focus = {5: "Threshold work begins", 8: "First 18-mile long run", 11: "Step-back week"}

print("begin;")
print(f"""update profiles set name='Sam', max_hr=188, birthdate='1991-06-02', days_per_week=5, long_run_day=0,
  health_connected=true, onboarded_at='2026-09-27T12:00:00Z' where id='{uid}';""")
print(f"""insert into goals (id,user_id,race_name,race_date,distance,distance_m,goal_time_seconds,days_per_week,
  course_type,goal_type,is_active,start_mileage,created_at) values
  ('11111111-1111-4111-8111-111111111111','{uid}','Harbor City Marathon','2027-03-14','marathon',42195,12600,5,
  'flat','time',true,30,'2026-09-27T12:00:00Z');""")
print(f"""insert into plans (id,user_id,goal_id,start_date,weeks,status,created_at) values
  ('22222222-2222-4222-8222-222222222222','{uid}','11111111-1111-4111-8111-111111111111','{start}',24,'active','2026-09-27T12:00:00Z');""")
for i, (p, m) in enumerate(zip(phases, miles)):
    f = focus.get(i)
    f = f"'{f}'" if f else "null"
    print(f"insert into plan_weeks (plan_id,week_index,phase,target_mileage,focus) values "
          f"('22222222-2222-4222-8222-222222222222',{i},'{p}',{m},{f});")

M = 1609
week_sessions = [
    (1, "tempo", "Tempo intervals", 8, 448, "1.5 mi warm-up, 6 × ½ mi at 7:28 with 90 s jog, cool down"),
    (2, "easy", "Easy run", 6, 565, "Conversational. Keep it under 145 bpm."),
    (3, "threshold", "Steady tempo", 7, 462, "2 mi easy, 3 mi at 7:42, 2 mi easy"),
    (5, "easy", "Easy run", 5, 570, "Relaxed, with 4 strides at the end."),
    (6, "long", "Long run", 15, 580, "Easy for 12, then the last 3 at marathon effort."),
]
for w in range(4, 8):
    monday = start + dt.timedelta(weeks=w)
    for off, typ, title, mi, pace, detail in week_sessions:
        d = monday + dt.timedelta(days=off)
        d_mi = mi + (w - 5)
        print(f"""insert into sessions (plan_id,user_id,date,type,title,target_distance_m,target_pace_sec,structure,status) values
  ('22222222-2222-4222-8222-222222222222','{uid}','{d}','{typ}','{title}',{d_mi*M},{pace},'{{"detail":"{detail}"}}','planned');""")
print("commit;")
