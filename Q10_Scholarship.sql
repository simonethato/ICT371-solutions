-- ICT371 Q10 Scholarship Application Assessment (PostgreSQL + pg_cron)
DROP TABLE IF EXISTS decision_audit, applications, students CASCADE;

-- (a) Tables
CREATE TABLE students (
  student_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  student_number VARCHAR(20) NOT NULL UNIQUE,
  full_name      VARCHAR(100) NOT NULL
);
CREATE TABLE applications (
  application_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  student_id         INT NOT NULL REFERENCES students(student_id),
  age_at_application INT NOT NULL CHECK (age_at_application > 0),
  monthly_income     NUMERIC(12,2) NOT NULL CHECK (monthly_income >= 0),
  average_mark       NUMERIC(5,2) NOT NULL CHECK (average_mark BETWEEN 0 AND 100),
  submitted_on       DATE NOT NULL DEFAULT CURRENT_DATE,
  status             VARCHAR(10) NOT NULL DEFAULT 'PENDING'
    CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED'))
);
CREATE TABLE decision_audit (
  audit_id       INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  application_id INT NOT NULL REFERENCES applications(application_id),
  old_status     VARCHAR(10) NOT NULL,
  new_status     VARCHAR(10) NOT NULL,
  changed_at     TIMESTAMP NOT NULL DEFAULT now()
);

-- (b) Function
CREATE OR REPLACE FUNCTION fn_scholarship_eligible(p_age INT, p_income NUMERIC, p_mark NUMERIC)
RETURNS BOOLEAN LANGUAGE plpgsql AS $$
BEGIN
  IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
    RAISE EXCEPTION 'Age, income and mark must not be NULL';
  END IF;
  IF p_income < 0 THEN RAISE EXCEPTION 'Income must not be negative'; END IF;
  IF p_age <= 0 THEN RAISE EXCEPTION 'Age must be positive'; END IF;
  IF p_mark < 0 OR p_mark > 100 THEN RAISE EXCEPTION 'Mark must be between 0 and 100'; END IF;
  RETURN p_age BETWEEN 18 AND 25 AND p_income <= 3000 AND p_mark >= 70;
END $$;

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_assess_application(p_application_id INT)
LANGUAGE plpgsql AS $$
DECLARE v_age INT; v_income NUMERIC; v_mark NUMERIC; v_status VARCHAR(10);
BEGIN
  SELECT age_at_application, monthly_income, average_mark, status
  INTO v_age, v_income, v_mark, v_status
  FROM applications WHERE application_id = p_application_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Application % does not exist', p_application_id;
  END IF;
  IF v_status <> 'PENDING' THEN
    RAISE EXCEPTION 'Application % has already been assessed (%)', p_application_id, v_status;
  END IF;
  UPDATE applications
  SET status = CASE WHEN fn_scholarship_eligible(v_age, v_income, v_mark)
                    THEN 'APPROVED' ELSE 'REJECTED' END
  WHERE application_id = p_application_id;
END $$;

-- (d) Trigger
CREATE OR REPLACE FUNCTION trg_fn_decision_audit() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO decision_audit (application_id, old_status, new_status, changed_at)
  VALUES (OLD.application_id, OLD.status, NEW.status, now());
  RETURN NEW;
END $$;
CREATE TRIGGER trg_decision_audit
AFTER UPDATE ON applications
FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM NEW.status)
EXECUTE FUNCTION trg_fn_decision_audit();

-- (a) Seed data: six PENDING applications, three students, boundary cases
INSERT INTO students (student_number, full_name) VALUES
  ('SC001', 'Alice Mumba'), ('SC002', 'Brian Tembo'), ('SC003', 'Chola Mwale');
INSERT INTO applications (student_id, age_at_application, monthly_income, average_mark, submitted_on) VALUES
  (1, 20, 2500.00, 75.00, CURRENT_DATE - 14),   -- qualifies
  (1, 17, 2000.00, 80.00, CURRENT_DATE - 12),   -- too young
  (2, 25, 3000.00, 70.00, CURRENT_DATE - 10),   -- upper boundary, qualifies
  (2, 18, 3000.00, 70.00, CURRENT_DATE - 8),    -- lower boundary, qualifies
  (3, 22, 3000.01, 90.00, CURRENT_DATE - 6),    -- income just above limit
  (3, 21, 1500.00, 69.99, CURRENT_DATE - 4);    -- mark just below limit

-- Tests
SELECT fn_scholarship_eligible(25, 3000, 70) AS boundary, fn_scholarship_eligible(26, 1000, 90) AS too_old;
DO $$ BEGIN PERFORM fn_scholarship_eligible(NULL, 1000, 80);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_scholarship_eligible(20, 1000, 101);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
CALL pr_assess_application(1);                                   -- APPROVED
DO $$ BEGIN CALL pr_assess_application(1);                       -- already assessed
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_assess_application(999);                     -- unknown
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
UPDATE applications SET status = status WHERE application_id = 1;  -- unchanged: no audit row
SELECT * FROM decision_audit;

-- (e) View (income omitted)
CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT s.student_number, s.full_name, a.average_mark, a.status
FROM applications a JOIN students s ON s.student_id = a.student_id
WHERE a.status = 'APPROVED';

-- (f) Index: equality on status first, then range on submitted_on
CREATE INDEX idx_app_status_submitted ON applications (status, submitted_on);
ANALYZE applications;
SET enable_seqscan = off;
EXPLAIN SELECT * FROM applications
WHERE status = 'PENDING' AND submitted_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
RESET enable_seqscan;
-- Justification: the weekly job and officers filter by status (equality) within a
-- date window (range); this column order gives one tight index range scan.

-- (g) Scheduled job: only PENDING rows are selected, so reruns are harmless
CREATE OR REPLACE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql AS $$
DECLARE r RECORD;
BEGIN
  FOR r IN SELECT application_id FROM applications
           WHERE status = 'PENDING' ORDER BY application_id
  LOOP
    CALL pr_assess_application(r.application_id);
  END LOOP;
END $$;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('assess-pending', '0 8 * * 1', $$CALL pr_assess_pending()$$);

CALL pr_assess_pending();
CALL pr_assess_pending();   -- rerun: nothing PENDING, no duplicate audit rows
SELECT application_id, status FROM applications ORDER BY 1;  -- 1,3,4 APPROVED; 2,5,6 REJECTED
SELECT * FROM decision_audit ORDER BY audit_id;
SELECT * FROM v_approved_applicants;
