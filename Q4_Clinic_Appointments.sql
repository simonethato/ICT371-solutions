-- ICT371 Q4 Clinic Appointment Scheduling (PostgreSQL + pg_cron)
DROP TABLE IF EXISTS clinic_summary, appointments, doctors, patients CASCADE;

-- (a) Tables
CREATE TABLE patients (
  patient_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  full_name  VARCHAR(100) NOT NULL
);
CREATE TABLE doctors (
  doctor_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  full_name VARCHAR(100) NOT NULL
);
CREATE TABLE appointments (
  appointment_id  INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  patient_id      INT NOT NULL REFERENCES patients(patient_id),
  doctor_id       INT NOT NULL REFERENCES doctors(doctor_id),
  appointment_day DATE NOT NULL,
  slot_time       TIME NOT NULL
    CHECK (slot_time IN (TIME '09:00', TIME '10:00', TIME '11:00', TIME '12:00')),
  status          VARCHAR(10) NOT NULL DEFAULT 'BOOKED'
    CHECK (status IN ('BOOKED', 'ATTENDED', 'CANCELLED'))
);
CREATE TABLE clinic_summary (
  summary_date   DATE PRIMARY KEY,
  booked_count   INT NOT NULL,
  attended_count INT NOT NULL,
  cancelled_count INT NOT NULL
);

-- (d) Trigger (created before seed data)
CREATE OR REPLACE FUNCTION trg_fn_slot_clash() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.status <> 'CANCELLED' THEN
    PERFORM 1 FROM doctors WHERE doctor_id = NEW.doctor_id FOR UPDATE;  -- serialise per doctor
    IF EXISTS (
      SELECT 1 FROM appointments a
      WHERE a.doctor_id = NEW.doctor_id
        AND a.appointment_day = NEW.appointment_day
        AND a.slot_time = NEW.slot_time
        AND a.status <> 'CANCELLED'
        AND a.appointment_id IS DISTINCT FROM NEW.appointment_id   -- exclude the row being changed
    ) THEN
      RAISE EXCEPTION 'Doctor % already has a booking on % at %',
        NEW.doctor_id, NEW.appointment_day, NEW.slot_time;
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_slot_clash
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW EXECUTE FUNCTION trg_fn_slot_clash();

-- (b) Function
CREATE OR REPLACE FUNCTION fn_daily_load(p_doctor_id INT, p_day DATE)
RETURNS INT LANGUAGE plpgsql AS $$
BEGIN
  PERFORM 1 FROM doctors WHERE doctor_id = p_doctor_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown doctor %', p_doctor_id;
  END IF;
  RETURN (SELECT COUNT(*)::INT FROM appointments
          WHERE doctor_id = p_doctor_id AND appointment_day = p_day AND status <> 'CANCELLED');
END $$;

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_book_appointment(p_patient_id INT, p_doctor_id INT, p_day DATE, p_slot TIME)
LANGUAGE plpgsql AS $$
BEGIN
  IF p_day IS NULL OR p_slot IS NULL THEN
    RAISE EXCEPTION 'Day and slot are required';
  END IF;
  PERFORM 1 FROM patients WHERE patient_id = p_patient_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown patient %', p_patient_id; END IF;
  PERFORM 1 FROM doctors WHERE doctor_id = p_doctor_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown doctor %', p_doctor_id; END IF;
  IF p_day < CURRENT_DATE THEN
    RAISE EXCEPTION 'Cannot book a past date (%)', p_day;
  END IF;
  IF p_slot NOT IN (TIME '09:00', TIME '10:00', TIME '11:00', TIME '12:00') THEN
    RAISE EXCEPTION 'Unsupported slot %. Use 09:00, 10:00, 11:00 or 12:00', p_slot;
  END IF;
  INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status)
  VALUES (p_patient_id, p_doctor_id, p_day, p_slot, 'BOOKED');   -- trigger rejects clashes
END $$;

-- (a) Seed data (six appointments, no slot clash)
INSERT INTO patients (full_name) VALUES ('Grace Mulenga'), ('Peter Chileshe'), ('Ruth Nkhoma');
INSERT INTO doctors  (full_name) VALUES ('Dr. Banda'), ('Dr. Sichone'), ('Dr. Mutale');
INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status) VALUES
  (1, 1, CURRENT_DATE,     '09:00', 'BOOKED'),
  (2, 1, CURRENT_DATE,     '10:00', 'BOOKED'),
  (3, 2, CURRENT_DATE,     '09:00', 'BOOKED'),
  (1, 1, CURRENT_DATE - 1, '09:00', 'ATTENDED'),
  (2, 2, CURRENT_DATE - 1, '10:00', 'CANCELLED'),
  (3, 3, CURRENT_DATE - 1, '11:00', 'ATTENDED');

-- Tests
SELECT fn_daily_load(1, CURRENT_DATE) AS doc1_today,      -- 2
       fn_daily_load(3, CURRENT_DATE) AS doc3_today;      -- 0
CALL pr_book_appointment(3, 3, CURRENT_DATE + 1, '12:00');
DO $$ BEGIN CALL pr_book_appointment(1, 1, CURRENT_DATE, '09:00');   -- clash
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_book_appointment(1, 1, CURRENT_DATE - 1, '10:00'); -- past
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_book_appointment(1, 1, CURRENT_DATE + 1, '13:00'); -- bad slot
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN UPDATE appointments SET slot_time = '09:00' WHERE appointment_id = 2; -- UPDATE clash
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
UPDATE appointments SET slot_time = '11:00' WHERE appointment_id = 2;  -- allowed (own row excluded)

-- (e) View (no unrelated patient data: name only)
CREATE OR REPLACE VIEW v_today_appointments AS
SELECT a.appointment_id, p.full_name AS patient_name, d.full_name AS doctor_name, a.slot_time
FROM appointments a
JOIN patients p ON p.patient_id = a.patient_id
JOIN doctors  d ON d.doctor_id  = a.doctor_id
WHERE a.appointment_day = CURRENT_DATE AND a.status = 'BOOKED';
SELECT * FROM v_today_appointments ORDER BY slot_time;

-- (f) Non-unique index
CREATE INDEX idx_appt_day_doctor ON appointments (appointment_day, doctor_id);
ANALYZE appointments;
SET enable_seqscan = off;
EXPLAIN SELECT * FROM appointments WHERE appointment_day = CURRENT_DATE AND doctor_id = 1;
RESET enable_seqscan;
-- Justification: day-by-doctor schedules are the main search; the index serves
-- the trigger's clash check, the daily-load function and the daily summary.
-- It is non-unique because cancelled rows may legitimately share a day/doctor.

-- (g) Scheduled job
CREATE OR REPLACE PROCEDURE pr_refresh_clinic_summary(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO clinic_summary (summary_date, booked_count, attended_count, cancelled_count)
  SELECT p_day,
         COUNT(*) FILTER (WHERE status = 'BOOKED'),
         COUNT(*) FILTER (WHERE status = 'ATTENDED'),
         COUNT(*) FILTER (WHERE status = 'CANCELLED')
  FROM appointments WHERE appointment_day = p_day
  ON CONFLICT (summary_date) DO UPDATE
    SET booked_count = EXCLUDED.booked_count,
        attended_count = EXCLUDED.attended_count,
        cancelled_count = EXCLUDED.cancelled_count;
END $$;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('refresh-clinic-summary', '0 1 * * *',
  $$CALL pr_refresh_clinic_summary(CURRENT_DATE - 1)$$);

CALL pr_refresh_clinic_summary(CURRENT_DATE - 1);
CALL pr_refresh_clinic_summary(CURRENT_DATE - 1);   -- rerun replaces the row
SELECT * FROM clinic_summary;
