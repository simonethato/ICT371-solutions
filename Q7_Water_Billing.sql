-- ICT371 Q7 Water Meter Readings and Billing (PostgreSQL + pg_cron)
DROP TABLE IF EXISTS receivable_snapshot, bills, readings, customers CASCADE;

-- (a) Tables
CREATE TABLE customers (
  customer_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  full_name   VARCHAR(100) NOT NULL
);
CREATE TABLE readings (
  reading_id       INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  customer_id      INT NOT NULL REFERENCES customers(customer_id),
  reading_month    DATE NOT NULL CHECK (EXTRACT(DAY FROM reading_month) = 1),
  previous_reading NUMERIC(10,2) NOT NULL CHECK (previous_reading >= 0),
  current_reading  NUMERIC(10,2) NOT NULL CHECK (current_reading >= 0),
  CONSTRAINT uq_reading_cust_month UNIQUE (customer_id, reading_month)
);
CREATE TABLE bills (
  bill_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  reading_id  INT NOT NULL UNIQUE REFERENCES readings(reading_id),
  charge      NUMERIC(12,2) NOT NULL CHECK (charge >= 0),
  amount_paid NUMERIC(12,2) NOT NULL DEFAULT 0,
  due_on      DATE NOT NULL,
  CONSTRAINT ck_paid_range CHECK (amount_paid >= 0 AND amount_paid <= charge)
);
CREATE TABLE receivable_snapshot (
  snapshot_date DATE PRIMARY KEY,
  total_due     NUMERIC(14,2) NOT NULL
);

-- (b) Function: first 10 units K5, above 10 K8
CREATE OR REPLACE FUNCTION fn_water_charge(p_units NUMERIC)
RETURNS NUMERIC(12,2) LANGUAGE plpgsql AS $$
BEGIN
  IF p_units IS NULL OR p_units < 0 THEN
    RAISE EXCEPTION 'Consumption must not be NULL or negative';
  END IF;
  IF p_units <= 10 THEN
    RETURN ROUND(p_units * 5, 2);
  END IF;
  RETURN ROUND(10 * 5 + (p_units - 10) * 8, 2);
END $$;

-- (d) Trigger
CREATE OR REPLACE FUNCTION trg_fn_check_reading() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.current_reading < NEW.previous_reading THEN
    RAISE EXCEPTION 'current_reading (%) cannot be below previous_reading (%)',
      NEW.current_reading, NEW.previous_reading;
  END IF;
  RETURN NEW;   -- raising above aborts the statement, so nothing is stored
END $$;
CREATE TRIGGER trg_check_reading
BEFORE INSERT OR UPDATE ON readings
FOR EACH ROW EXECUTE FUNCTION trg_fn_check_reading();

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_generate_bill(p_reading_id INT, p_due_on DATE)
LANGUAGE plpgsql AS $$
DECLARE v_prev NUMERIC; v_curr NUMERIC;
BEGIN
  IF p_due_on IS NULL THEN
    RAISE EXCEPTION 'Due date is required';
  END IF;
  SELECT previous_reading, current_reading INTO v_prev, v_curr
  FROM readings WHERE reading_id = p_reading_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown reading %', p_reading_id;
  END IF;
  IF EXISTS (SELECT 1 FROM bills WHERE reading_id = p_reading_id) THEN
    RAISE EXCEPTION 'Reading % already has a bill', p_reading_id;
  END IF;
  INSERT INTO bills (reading_id, charge, amount_paid, due_on)
  VALUES (p_reading_id, fn_water_charge(v_curr - v_prev), 0, p_due_on);
END $$;

-- (a) Seed data: 0, exactly 10 and above 10 units
INSERT INTO customers (full_name) VALUES ('Mary Phiri'), ('John Daka'), ('Susan Ngoma');
INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading) VALUES
  (1, '2026-09-01', 100.00, 100.00),   -- 0 units
  (1, '2026-10-01', 100.00, 110.00),   -- exactly 10
  (2, '2026-09-01',  50.00,  65.00),   -- 15
  (2, '2026-10-01',  65.00,  90.00),   -- 25
  (3, '2026-09-01', 200.00, 207.50),   -- 7.5
  (3, '2026-10-01', 207.50, 220.00);   -- 12.5

-- Tests
SELECT fn_water_charge(0) AS u0, fn_water_charge(10) AS u10, fn_water_charge(15) AS u15; -- 0.00, 50.00, 90.00
DO $$ BEGIN PERFORM fn_water_charge(-1);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading)
            VALUES (1, '2026-11-01', 110, 100);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

CALL pr_generate_bill(1, DATE '2026-10-15');
CALL pr_generate_bill(3, DATE '2026-10-15');
CALL pr_generate_bill(5, DATE '2026-10-15');
CALL pr_generate_bill(2, CURRENT_DATE + 14);
CALL pr_generate_bill(4, CURRENT_DATE + 14);
CALL pr_generate_bill(6, CURRENT_DATE + 14);
DO $$ BEGIN CALL pr_generate_bill(1, CURRENT_DATE);        -- already billed
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_generate_bill(999, CURRENT_DATE);      -- unknown reading
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

UPDATE bills SET amount_paid = 30 WHERE bill_id = 2;       -- reading 3 partly paid
UPDATE bills SET amount_paid = charge WHERE bill_id = 4;   -- settled

-- (e) View
CREATE OR REPLACE VIEW v_overdue_bills AS
SELECT c.full_name AS customer_name, b.due_on, b.charge - b.amount_paid AS outstanding_amount
FROM bills b
JOIN readings r ON r.reading_id = b.reading_id
JOIN customers c ON c.customer_id = r.customer_id
WHERE b.due_on < CURRENT_DATE AND b.amount_paid < b.charge;
SELECT * FROM v_overdue_bills;

-- (f) Partial index on unpaid bills, searched by due date
CREATE INDEX idx_bills_unpaid_due ON bills (due_on) WHERE amount_paid < charge;
ANALYZE bills;
SET enable_seqscan = off;
EXPLAIN SELECT bill_id, due_on, charge - amount_paid AS outstanding
FROM bills WHERE amount_paid < charge AND due_on < CURRENT_DATE;
RESET enable_seqscan;
-- Justification: overdue searches only care about unpaid bills filtered by a
-- due_on range. The partial index holds just unpaid bills, so it stays small
-- as paid history grows and supports the range scan on due_on.

-- (g) Scheduled job
CREATE OR REPLACE PROCEDURE pr_refresh_receivables()
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO receivable_snapshot (snapshot_date, total_due)
  SELECT CURRENT_DATE, COALESCE(SUM(charge - amount_paid), 0)
  FROM bills WHERE amount_paid < charge
  ON CONFLICT (snapshot_date) DO UPDATE SET total_due = EXCLUDED.total_due;
END $$;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('refresh-receivables', '30 0 * * *', $$CALL pr_refresh_receivables()$$);

CALL pr_refresh_receivables();
CALL pr_refresh_receivables();   -- rerun replaces today's total
SELECT * FROM receivable_snapshot;
