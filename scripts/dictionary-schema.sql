-- Lin Flow shared dictionary: one row per term in vocab.txt and per rule in replacements.txt,
-- across every computer. Sources/LinFlowCore/DictionarySync.swift and
-- windows/LinFlow.Core/DictionarySync.cs write it; SYNC-PLAN.md has the design.
--
-- Terms and corrections only: no transcript, audio or app name. A deletion is a row marked
-- deleted, not a deleted row, so it reaches the computers that still have the entry.
-- Safe to run again: every statement is idempotent.

create table if not exists public.dictionary_entries (
  kind       text        not null check (kind in ('term', 'rule')),
  -- The term or the rule's left side, lowercased: one entry whatever its case.
  key        text        not null check (char_length(key) >= 1),
  text       text        not null check (char_length(text) >= 1),
  -- A rule's right side. Empty for a term, and a rule may map a word to nothing.
  target     text        not null default '',
  learned    boolean     not null default false,
  deleted    boolean     not null default false,
  -- Compared only for equality by the apps, never ordered, so clocks need not agree.
  updated_at timestamptz not null default now(),
  -- The computer that wrote the row last. For reading the table, not for the merge.
  device     text        check (char_length(device) <= 64),
  primary key (kind, key)
);

alter table public.dictionary_entries enable row level security;

-- The same grants as daily_totals: the publishable key can read every row, add a row and change
-- a row. No delete: a deletion is an update that marks the row.
grant usage on schema public to anon;
grant select, insert, update on table public.dictionary_entries to anon;
revoke truncate, references, trigger on table public.dictionary_entries from anon, authenticated;

drop policy if exists "read dictionary" on public.dictionary_entries;
create policy "read dictionary" on public.dictionary_entries for select to anon using (true);

drop policy if exists "add dictionary" on public.dictionary_entries;
create policy "add dictionary" on public.dictionary_entries for insert to anon with check (true);

drop policy if exists "change dictionary" on public.dictionary_entries;
create policy "change dictionary" on public.dictionary_entries for update to anon using (true) with check (true);
