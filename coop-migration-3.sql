-- ════════════════════════════════════════════════════════════════
-- Zayen Clicker co-op — migration 3: admin "pause purchases" per player
-- One additive column. Existing rooms keep all progress. Run once.
-- ════════════════════════════════════════════════════════════════

alter table public.coop_rooms add column if not exists frozen jsonb not null default '[]';
