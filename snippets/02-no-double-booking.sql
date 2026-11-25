-- No double booking, even when two patients tap the same slot at the same moment
-- (illustrative, written for this case study).

create extension if not exists btree_gist;  -- lets an exclusion constraint mix "=" and "&&"

create table doctors (
  id        uuid primary key default gen_random_uuid(),
  clinic_id uuid not null
);

create table appointments (
  id        uuid primary key default gen_random_uuid(),
  clinic_id uuid not null,
  doctor_id uuid not null references doctors,
  patient   text not null,
  during    tstzrange not null,
  status    text not null default 'booked' check (status in ('booked', 'cancelled')),
  -- The final guarantee: two active appointments of one doctor never overlap.
  constraint no_overlap exclude using gist (
    doctor_id with =,
    during    with &&
  ) where (status <> 'cancelled')
);

-- Every channel (web, WhatsApp bot, staff) books through this one function.
create function book_appointment(p_clinic uuid, p_doctor uuid, p_patient text,
                                 p_start timestamptz, p_minutes int)
returns appointments language plpgsql as $$
declare
  slot   tstzrange := tstzrange(p_start, p_start + make_interval(mins => p_minutes));
  booked appointments;
begin
  -- The doctor must belong to the clinic the request is for.
  if not exists (select 1 from doctors where id = p_doctor and clinic_id = p_clinic) then
    raise exception 'doctor does not belong to this clinic' using errcode = 'check_violation';
  end if;

  -- Serialise bookings per doctor for the rest of this transaction, so the
  -- availability check below cannot race with another booking.
  perform pg_advisory_xact_lock(hashtextextended(p_doctor::text, 0));

  if exists (select 1 from appointments
              where doctor_id = p_doctor and status <> 'cancelled' and during && slot) then
    raise exception 'slot taken' using errcode = 'exclusion_violation';
  end if;

  insert into appointments (clinic_id, doctor_id, patient, during)
  values (p_clinic, p_doctor, p_patient, slot)
  returning * into booked;
  return booked;
end $$;
