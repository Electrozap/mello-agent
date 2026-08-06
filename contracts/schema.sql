-- =============================================================
-- contracts/schema.sql
-- Mello AI — Outbound Voice Agent
--
-- JOINT CONTRACT FILE. Changes require agreement from both tracks.
--
-- WRITE OWNERSHIP (enforce by discipline, not by DB permissions):
--   Track A (agent)    -> call_sessions.transcript
--                         call_sessions.stage_timings
--                         call_sessions.ended_at
--                         call_turns.*  (all)
--   Track B (platform) -> everything else
--
-- Run against Supabase: SQL Editor, or `psql $DATABASE_URL -f schema.sql`
-- =============================================================

create extension if not exists "pgcrypto";      -- gen_random_uuid()

-- =============================================================
-- ENUMS
-- =============================================================

create type campaign_status as enum (
  'draft', 'scheduled', 'running', 'paused', 'completed', 'cancelled'
);

create type lead_status as enum (
  'queued',          -- eligible for dialing
  'in_progress',     -- claimed by a dialer worker
  'retry_pending',   -- no-answer/busy, waiting for next_attempt_at
  'completed',       -- terminal, reached and handled
  'exhausted',       -- terminal, hit max attempts
  'blocked',         -- terminal, failed the compliance gate
  'dnd'              -- terminal, opted out
);

create type call_disposition as enum (
  -- pre-connect outcomes (Track B writes)
  'not_dialed_dnd',
  'not_dialed_window',      -- outside 09:00-21:00 IST
  'not_dialed_no_consent',
  'not_dialed_no_dlt',
  'no_answer',
  'busy',
  'failed',                 -- carrier/network failure
  'voicemail',              -- AMD positive
  -- post-conversation outcomes (Track B writes, from B8 post-call pipeline)
  'booked',
  'callback_requested',
  'interested_not_booked',
  'not_interested',
  'wrong_number',
  'opted_out',
  'transferred_to_human',
  'caller_hung_up',
  'agent_error'             -- pipeline crashed mid-call
);

create type compliance_result as enum ('pass', 'fail');

-- =============================================================
-- TENANCY
-- =============================================================

create table clients (
  id              uuid primary key default gen_random_uuid(),
  name            text        not null,
  business_type   text,                       -- 'gym' | 'salon' | 'studio' | ...
  city            text,
  dlt_entity_id   text,                       -- TRAI DLT registered entity ID
  timezone        text        not null default 'Asia/Kolkata',
  is_active       boolean     not null default true,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

-- =============================================================
-- CAMPAIGNS  (Track B owns entirely)
-- =============================================================

create table campaigns (
  id                    uuid primary key default gen_random_uuid(),
  client_id             uuid not null references clients(id) on delete cascade,
  name                  text not null,
  status                campaign_status not null default 'draft',

  -- compliance (B5)
  dlt_template_id       text,                 -- must be non-null before dialing
  consent_basis         text,                 -- 'existing_member' | 'web_form' | ...
  calling_window_start  time not null default '09:00',
  calling_window_end    time not null default '21:00',

  -- pacing / retry (B6)
  max_concurrent_calls  int  not null default 2  check (max_concurrent_calls between 1 and 50),
  max_attempts          int  not null default 3  check (max_attempts between 1 and 5),
  retry_interval_min    int  not null default 240,

  -- agent config (read by Track A via lead_context, never written by A)
  agent_config          jsonb not null default '{}'::jsonb,
  -- e.g. {"voice":"anushka","language":"en-IN","system_prompt_id":"gym_booking_v3",
  --       "first_message":"Hi {{name}}, calling from {{business}}..."}

  scheduled_start_at    timestamptz,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);

create index idx_campaigns_active
  on campaigns (status, scheduled_start_at)
  where status in ('scheduled', 'running');

-- =============================================================
-- LEADS  (Track B owns entirely)
-- =============================================================

create table leads (
  id                uuid primary key default gen_random_uuid(),
  campaign_id       uuid not null references campaigns(id) on delete cascade,
  client_id         uuid not null references clients(id) on delete cascade,

  phone_e164        text not null check (phone_e164 ~ '^\+91[6-9][0-9]{9}$'),
  name              text,

  -- injected into the system prompt as dynamic variables
  context           jsonb not null default '{}'::jsonb,
  -- e.g. {"membership_expiry":"2026-08-20","last_visit":"2026-07-02","plan":"quarterly"}

  -- consent evidence (B5) — never dial without this
  consent_source    text,
  consent_at        timestamptz,

  status            lead_status not null default 'queued',
  attempt_count     int  not null default 0,
  last_attempt_at   timestamptz,
  next_attempt_at   timestamptz not null default now(),

  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),

  unique (campaign_id, phone_e164)
);

-- The dialer's hot query. Partial index keeps it small as the table grows.
create index idx_leads_dial_queue
  on leads (campaign_id, next_attempt_at)
  where status in ('queued', 'retry_pending');

create index idx_leads_phone on leads (phone_e164);

-- =============================================================
-- DND REGISTRY  (Track B owns entirely)
-- Checked before every dial. Global across clients — an opt-out is an opt-out.
-- =============================================================

create table dnd_registry (
  phone_e164   text primary key check (phone_e164 ~ '^\+91[6-9][0-9]{9}$'),
  source       text not null,          -- 'ncpr' | 'caller_request' | 'manual' | 'client_upload'
  reason       text,
  added_at     timestamptz not null default now()
);

-- =============================================================
-- CALL SESSIONS  (SHARED — see write ownership at top of file)
-- One row per dial attempt, including attempts blocked before dialing.
-- =============================================================

create table call_sessions (
  id                  uuid primary key default gen_random_uuid(),
  lead_id             uuid not null references leads(id) on delete cascade,
  campaign_id         uuid not null references campaigns(id) on delete cascade,
  client_id           uuid not null references clients(id) on delete cascade,

  attempt_number      int  not null default 1,

  -- ---- Track B: telephony ----
  exotel_call_sid     text,
  from_number         text,
  to_number           text not null,

  -- ---- Track B: compliance gate result (B5), written BEFORE dialing ----
  compliance_result   compliance_result,
  compliance_detail   jsonb not null default '{}'::jsonb,
  -- e.g. {"dnd":"pass","dlt":"pass","window":"fail","consent":"pass"}

  -- ---- Track B: AMD (B4) ----
  amd_result          text,             -- 'human' | 'machine' | 'unknown'
  amd_source          text,             -- 'exotel' | 'heuristic'

  -- ---- lifecycle ----
  created_at          timestamptz not null default now(),  -- B
  dialed_at           timestamptz,                         -- B
  answered_at         timestamptz,                         -- B
  ended_at            timestamptz,                         -- A (or B if never handed over)
  duration_sec        int generated always as (
                        extract(epoch from (ended_at - answered_at))::int
                      ) stored,

  disposition         call_disposition,                    -- B
  end_reason          text,                                -- A: 'goal_met' | 'caller_hangup' | 'error'

  -- ---- Track A ----
  transcript          jsonb not null default '[]'::jsonb,
  -- [{"turn":1,"role":"agent","text":"...","ts":"..."},
  --  {"turn":1,"role":"caller","text":"...","ts":"..."}]

  stage_timings       jsonb not null default '{}'::jsonb,
  -- roll-up only; per-turn detail lives in call_turns
  -- {"turns":5,"p50_total_ms":780,"p95_total_ms":1120}

  -- ---- Track B: post-call (B8) ----
  outcome_data        jsonb not null default '{}'::jsonb,
  -- {"interest":"high","requested_slot":"2026-08-09T07:00:00+05:30",
  --  "objections":["price"],"callback_at":null}

  recording_url       text,
  error_detail        text
);

create index idx_sessions_campaign  on call_sessions (campaign_id, created_at desc);
create index idx_sessions_lead      on call_sessions (lead_id, attempt_number);
create index idx_sessions_exotel    on call_sessions (exotel_call_sid);
create index idx_sessions_disposition
  on call_sessions (client_id, disposition, created_at desc);

-- =============================================================
-- CALL TURNS  (Track A owns entirely)
--
-- NOTE: this table is an addition to what Task 0.2 specified.
-- Rationale: A6 and B9 both need per-turn latency percentiles.
-- Computing those by unnesting a jsonb array is painful and slow;
-- one row per turn makes `select percentile_cont(0.95) ...` trivial.
-- stage_timings on call_sessions stays as the roll-up.
-- Agree on this before committing, per the contract rule.
-- =============================================================

create table call_turns (
  id                    bigserial primary key,
  call_session_id       uuid not null references call_sessions(id) on delete cascade,
  turn_index            int  not null,

  caller_text           text,
  agent_text            text,

  -- latency budget, milliseconds, measured from speech_end (A6)
  ms_to_stt_final       int,
  ms_to_llm_first_token int,
  ms_to_tts_first_byte  int,
  ms_to_media_out       int,   -- the number that matters; target <800 now, <500 later

  -- turn-taking diagnostics (A7/A9)
  endpoint_source       text,  -- 'smart_turn_v2' | 'vad_timeout' | 'stt_endpoint'
  was_interrupted       boolean not null default false,
  backchannel_filtered  boolean not null default false,

  tool_calls            jsonb not null default '[]'::jsonb,
  -- [{"name":"check_slots","ms":420,"ok":true}]

  audio_url             text,  -- caller audio for this turn — feeds the B9 eval harness
  created_at            timestamptz not null default now(),

  unique (call_session_id, turn_index)
);

create index idx_turns_latency on call_turns (call_session_id, turn_index);

-- =============================================================
-- TRIGGERS — updated_at
-- =============================================================

create or replace function set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end $$;

create trigger trg_clients_updated   before update on clients
  for each row execute function set_updated_at();
create trigger trg_campaigns_updated before update on campaigns
  for each row execute function set_updated_at();
create trigger trg_leads_updated     before update on leads
  for each row execute function set_updated_at();

-- =============================================================
-- VIEW — latency dashboard (A6 / B9)
-- =============================================================

create or replace view v_latency_by_campaign as
select
  cs.campaign_id,
  count(*)                                                              as turns,
  percentile_cont(0.50) within group (order by ct.ms_to_media_out)::int as p50_ms,
  percentile_cont(0.95) within group (order by ct.ms_to_media_out)::int as p95_ms,
  percentile_cont(0.50) within group (order by ct.ms_to_stt_final)::int as p50_stt_ms,
  percentile_cont(0.50) within group (order by ct.ms_to_llm_first_token)::int as p50_llm_ms,
  percentile_cont(0.50) within group (order by ct.ms_to_tts_first_byte)::int  as p50_tts_ms,
  avg(ct.was_interrupted::int)                                          as interrupt_rate
from call_turns ct
join call_sessions cs on cs.id = ct.call_session_id
group by cs.campaign_id;

-- =============================================================
-- ROW LEVEL SECURITY
-- Backend uses the service_role key, which bypasses RLS.
-- Enable now so nothing is ever readable via the anon key by accident.
-- Add per-client policies when the client dashboard is built.
-- =============================================================

alter table clients       enable row level security;
alter table campaigns     enable row level security;
alter table leads         enable row level security;
alter table dnd_registry  enable row level security;
alter table call_sessions enable row level security;
alter table call_turns    enable row level security;

-- =============================================================
-- SEED — B1 checkpoint (20 fake leads)
-- Replace the phone numbers with ones you control before dialing anything.
-- =============================================================

insert into clients (id, name, business_type, city, dlt_entity_id)
values ('00000000-0000-0000-0000-000000000001',
        'Test Fitness Studio', 'gym', 'Mumbai', 'DLT-TEST-0001');

insert into campaigns (id, client_id, name, status, dlt_template_id,
                       consent_basis, agent_config)
values ('00000000-0000-0000-0000-000000000002',
        '00000000-0000-0000-0000-000000000001',
        'Renewal Reminder — Aug 2026', 'draft', 'TPL-TEST-0001',
        'existing_member',
        '{"voice":"anushka","language":"en-IN","system_prompt_id":"gym_renewal_v1"}'::jsonb);

insert into leads (campaign_id, client_id, phone_e164, name, context,
                   consent_source, consent_at)
select
  '00000000-0000-0000-0000-000000000002',
  '00000000-0000-0000-0000-000000000001',
  '+919' || lpad((100000000 + i)::text, 9, '0'),
  'Test Lead ' || i,
  jsonb_build_object('plan', 'quarterly',
                     'membership_expiry', (current_date + i)::text),
  'existing_member',
  now() - interval '30 days'
from generate_series(1, 20) as i;
