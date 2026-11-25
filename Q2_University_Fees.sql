-- ICT371 Q2 University Fee Payments (PostgreSQL + pg_cron)
DROP TABLE IF EXISTS daily_collections, payment_audit, payments, students CASCADE;

-- (a) Tables
CREATE TABLE students (
  student_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  student_number VARCHAR(20) NOT NULL UNIQUE,
  full_name      VARCHAR(100) NOT NULL,
  fee_due        NUMERIC(12,2) NOT NULL CHECK (fee_due >= 0)
);
CREATE TABLE payments (
  payment_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  student_id INT NOT NULL REFERENCES students(student_id),
  amount     NUMERIC(12,2) NOT NULL CHECK (amount > 0),
  paid_on    DATE NOT NULL DEFAULT CURRENT_DATE
);
CREATE TABLE payment_audit (
  audit_id   INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  payment_id INT NOT NULL REFERENCES payments(payment_id),
  student_id INT NOT NULL REFERENCES students(student_id),
  amount     NUMERIC(12,2) NOT NULL,
  logged_at  TIMESTAMP NOT NULL DEFAULT now()
);
CREATE TABLE daily_collections (
  collection_date DATE PRIMARY KEY,
  payment_count   INT NOT NULL,
  total_amount    NUMERIC(12,2) NOT NULL
);

-- (b) Function
CREATE OR REPLACE FUNCTION fn_fee_balance(p_student_id INT)
RETURNS NUMERIC LANGUAGE plpgsql AS $$
DECLARE v_fee NUMERIC(12,2);
BEGIN
  SELECT fee_due INTO v_fee FROM students WHERE student_id = p_student_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown student %', p_student_id;
  END IF;
  RETURN v_fee - COALESCE((SELECT SUM(amount) FROM payments
                           WHERE student_id = p_student_id), 0);
END $$;

-- (c) Procedure (audit row is NOT inserted here; the trigger does it)
CREATE OR REPLACE PROCEDURE pr_receive_payment(p_student_id INT, p_amount NUMERIC, p_paid_on DATE)
LANGUAGE plpgsql AS $$
DECLARE v_balance NUMERIC;
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'Payment amount must be greater than zero';
  END IF;
  IF p_paid_on IS NULL THEN
    RAISE EXCEPTION 'Payment date is required';
  END IF;
  PERFORM 1 FROM students WHERE student_id = p_student_id FOR UPDATE;  -- serialise per student
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown student %', p_student_id;
  END IF;
  v_balance := fn_fee_balance(p_student_id);
  IF p_amount > v_balance THEN
    RAISE EXCEPTION 'Payment % exceeds outstanding balance %', p_amount, v_balance;
  END IF;
  INSERT INTO payments (student_id, amount, paid_on) VALUES (p_student_id, p_amount, p_paid_on);
END $$;

-- (d) Trigger
CREATE OR REPLACE FUNCTION trg_fn_payment_audit() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO payment_audit (payment_id, student_id, amount, logged_at)
  VALUES (NEW.payment_id, NEW.student_id, NEW.amount, now());
  RETURN NEW;
END $$;
CREATE TRIGGER trg_payment_audit
AFTER INSERT ON payments
FOR EACH ROW EXECUTE FUNCTION trg_fn_payment_audit();

-- (a) Seed data (student 3 has no payments)
INSERT INTO students (student_number, full_name, fee_due) VALUES
  ('S1001', 'Mwansa Banda', 5000.00),
  ('S1002', 'Chanda Phiri', 3000.00),
  ('S1003', 'Thandi Zulu',  4000.00);
INSERT INTO payments (student_id, amount, paid_on) VALUES
  (1, 2000.00, CURRENT_DATE - 10),
  (1, 1500.00, CURRENT_DATE - 5),
  (1,  500.00, CURRENT_DATE - 1),
  (2, 1000.00, CURRENT_DATE - 9),
  (2, 1000.00, CURRENT_DATE - 1),
  (2, 1000.00, CURRENT_DATE - 1);

-- Tests
SELECT fn_fee_balance(1) AS s1, fn_fee_balance(2) AS s2, fn_fee_balance(3) AS s3; -- 1000, 0, 4000
CALL pr_receive_payment(3, 1000.00, CURRENT_DATE);
DO $$ BEGIN CALL pr_receive_payment(3, 99999, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_receive_payment(3, 0, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
SELECT * FROM payment_audit ORDER BY audit_id;

-- (e) View
CREATE OR REPLACE VIEW v_fee_balances AS
SELECT s.student_number, s.full_name,
       s.fee_due - COALESCE(SUM(p.amount), 0) AS outstanding_balance
FROM students s
LEFT JOIN payments p ON p.student_id = s.student_id
GROUP BY s.student_id, s.student_number, s.full_name, s.fee_due
HAVING s.fee_due - COALESCE(SUM(p.amount), 0) > 0;
SELECT * FROM v_fee_balances;   -- student S1002 (settled) is excluded

-- (f) Composite index
CREATE INDEX idx_payments_student_paid_on ON payments (student_id, paid_on);
ANALYZE payments;
SET enable_seqscan = off;
EXPLAIN SELECT * FROM payments
WHERE student_id = 1 AND paid_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
RESET enable_seqscan;
-- Justification: equality on student_id then range on paid_on matches the
-- column order (equality first, range last), so only that student's payments
-- inside the dates are read, and the same index speeds up balance look-ups.

-- (g) Scheduled job
CREATE OR REPLACE PROCEDURE pr_refresh_collections(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO daily_collections (collection_date, payment_count, total_amount)
  SELECT p_day, COUNT(*), COALESCE(SUM(amount), 0)
  FROM payments WHERE paid_on = p_day
  ON CONFLICT (collection_date) DO UPDATE
    SET payment_count = EXCLUDED.payment_count, total_amount = EXCLUDED.total_amount;
END $$;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('refresh-collections', '0 1 * * *',
  $$CALL pr_refresh_collections(CURRENT_DATE - 1)$$);

CALL pr_refresh_collections(CURRENT_DATE - 1);
CALL pr_refresh_collections(CURRENT_DATE - 1);    -- rerun replaces the row
SELECT * FROM daily_collections;
