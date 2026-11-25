-- A Postgres job queue for outgoing messages (illustrative, written for this case study).
--
-- Several workers can poll at once: FOR UPDATE SKIP LOCKED hands each job to
-- exactly one of them, without workers blocking each other. A job whose worker
-- died becomes claimable again after a timeout, and failures retry with backoff.

create table outbound_jobs (
  id              bigint generated always as identity primary key,
  tenant_id       uuid not null,
  channel         text not null check (channel in ('whatsapp', 'telegram')),
  recipient       text not null,
  body            text not null,
  idempotency_key text unique,               -- the same reply enqueued twice is sent once
  status          text not null default 'queued'
                    check (status in ('queued', 'processing', 'sent', 'failed')),
  attempts        int  not null default 0,
  max_attempts    int  not null default 5,
  next_attempt_at timestamptz not null default now(),
  locked_at       timestamptz,
  last_error      text,
  created_at      timestamptz not null default now()
);

-- Only the rows a worker can pick, in pick order.
create index outbound_jobs_ready_idx on outbound_jobs (next_attempt_at)
  where status in ('queued', 'processing');

-- Claim up to `batch` jobs for `for_channel`. Each worker calls this in its own transaction.
create function claim_outbound_jobs(for_channel text, batch int default 10,
                                    stale_after interval default '10 minutes')
returns setof outbound_jobs language sql as $$
  update outbound_jobs j
     set status = 'processing', locked_at = now(), attempts = j.attempts + 1
   where j.id in (
     select id from outbound_jobs
      where channel = for_channel
        and next_attempt_at <= now()
        and (status = 'queued'
             -- a worker that crashed mid-send left its job "processing": take it back
             or (status = 'processing' and locked_at < now() - stale_after))
      order by next_attempt_at
      limit batch
      for update skip locked
   )
  returning j.*;
$$;

create function complete_outbound_job(job_id bigint) returns void language sql as $$
  update outbound_jobs set status = 'sent', locked_at = null, last_error = null where id = job_id;
$$;

-- Retry with exponential backoff (30 s, 1 min, 2 min, …) until max_attempts, then give up visibly.
create function fail_outbound_job(job_id bigint, error text) returns void language sql as $$
  update outbound_jobs
     set status          = case when attempts >= max_attempts then 'failed' else 'queued' end,
         next_attempt_at = now() + interval '30 seconds' * power(2, greatest(attempts - 1, 0)),
         locked_at       = null,
         last_error      = left(error, 500)
   where id = job_id;
$$;
