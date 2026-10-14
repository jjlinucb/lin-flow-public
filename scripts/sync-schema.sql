-- Lin Flow shared word totals: one row per computer per day.
--
-- Counts only. No transcript, audio, dictionary entry or app name is ever written here; the
-- apps build each row from their local history and send these six columns and nothing else.
-- Safe to run again: every statement is idempotent.

create table if not exists public.daily_totals (
  device        text             not null check (char_length(device) between 1 and 64),
  day           date             not null,
  words         integer          not null default 0 check (words >= 0),
  dictations    integer          not null default 0 check (dictations >= 0),
  audio_seconds double precision not null default 0 check (audio_seconds >= 0),
  updated_at    timestamptz      not null default now(),
  primary key (device, day)
);

alter table public.daily_totals enable row level security;

-- Projects made after 2026-05-30 expose no table to the Data API until it is granted, so the
-- apps' role gets exactly what they use: read every row, add a row, change a row. No delete.
grant usage on schema public to anon;
grant select, insert, update on table public.daily_totals to anon;

-- The project's default privileges still hand out TRUNCATE, REFERENCES and TRIGGER on every new
-- table (seen on lin-flow, 2026-09-25). The Data API cannot use them, and nothing here needs them.
revoke truncate, references, trigger on table public.daily_totals from anon, authenticated;

drop policy if exists "read totals" on public.daily_totals;
create policy "read totals" on public.daily_totals for select to anon using (true);

drop policy if exists "add totals" on public.daily_totals;
create policy "add totals" on public.daily_totals for insert to anon with check (true);

drop policy if exists "change totals" on public.daily_totals;
create policy "change totals" on public.daily_totals for update to anon using (true) with check (true);
