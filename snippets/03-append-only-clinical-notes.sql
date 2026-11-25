-- Clinical notes that keep their history (illustrative, written for this case study).
--
-- A note is never edited or deleted. A correction is a new row that names the
-- row it supersedes, so the record of what was written, and when, stays intact.

create table clinical_notes (
  id          bigint generated always as identity primary key,
  clinic_id   uuid not null,
  patient_id  uuid not null,
  tooth_fdi   smallint check (tooth_fdi between 11 and 85),  -- FDI notation; null = whole mouth
  note        text not null,
  supersedes  bigint references clinical_notes,               -- set on a correction
  written_by  uuid not null,
  written_at  timestamptz not null default now()
);

-- A note can be corrected once; corrections of corrections form a chain.
create unique index clinical_notes_one_correction on clinical_notes (supersedes)
  where supersedes is not null;

create function clinical_notes_append_only() returns trigger language plpgsql as $$
begin
  raise exception 'clinical notes are append-only; add a correction instead'
    using errcode = 'insufficient_privilege';
end $$;

create trigger clinical_notes_no_edit
  before update or delete on clinical_notes
  for each row execute function clinical_notes_append_only();

-- What the chart shows: the latest version of every note.
create view current_clinical_notes with (security_invoker = true) as
select n.*
from clinical_notes n
where not exists (select 1 from clinical_notes c where c.supersedes = n.id);
