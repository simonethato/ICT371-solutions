-- ICT371 Q9 Farmer Cooperative Maize Deliveries (PostgreSQL + pg_cron)
DROP TABLE IF EXISTS daily_purchases, deliveries, farmers CASCADE;

-- (a) Tables
CREATE TABLE farmers (
  farmer_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  farmer_number VARCHAR(20) NOT NULL UNIQUE,
  full_name     VARCHAR(100) NOT NULL
);
CREATE TABLE deliveries (
  delivery_id  INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  farmer_id    INT NOT NULL REFERENCES farmers(farmer_id),
  grade        CHAR(1) NOT NULL CHECK (grade IN ('A', 'B', 'C')),
  weight_kg    NUMERIC(10,2) NOT NULL CHECK (weight_kg > 0),
  unit_rate    NUMERIC(10,2) NOT NULL,      -- filled by the trigger
  total_value  NUMERIC(12,2) NOT NULL,      -- filled by the trigger
  delivered_on DATE NOT NULL DEFAULT CURRENT_DATE,
  is_paid      BOOLEAN NOT NULL DEFAULT FALSE
);
CREATE TABLE daily_purchases (
  purchase_date DATE PRIMARY KEY,
  total_weight  NUMERIC(12,2) NOT NULL,
  total_value   NUMERIC(14,2) NOT NULL
);

-- (b) Function
CREATE OR REPLACE FUNCTION fn_maize_rate(p_grade VARCHAR)
RETURNS NUMERIC LANGUAGE plpgsql AS $$
BEGIN
  IF p_grade IS NULL THEN
    RAISE EXCEPTION 'Grade must not be NULL';
  END IF;
  IF p_grade = 'A' THEN RETURN 5.00;
  ELSIF p_grade = 'B' THEN RETURN 4.00;
  ELSIF p_grade = 'C' THEN RETURN 3.00;
  END IF;
  RAISE EXCEPTION 'Unsupported grade %. Use A, B or C', p_grade;
END $$;

-- (d) Trigger: one pricing rule for procedure and direct SQL
CREATE OR REPLACE FUNCTION trg_fn_delivery_pricing() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.weight_kg IS NULL OR NEW.weight_kg <= 0 THEN
    RAISE EXCEPTION 'Weight must be greater than zero';
  END IF;
  NEW.unit_rate   := fn_maize_rate(NEW.grade);
  NEW.total_value := ROUND(NEW.weight_kg * NEW.unit_rate, 2);
  RETURN NEW;
END $$;
CREATE TRIGGER trg_delivery_pricing
BEFORE INSERT OR UPDATE ON deliveries
FOR EACH ROW EXECUTE FUNCTION trg_fn_delivery_pricing();

-- (c) Procedure: inserts basic fields only
CREATE OR REPLACE PROCEDURE pr_receive_delivery(p_farmer_id INT, p_grade VARCHAR, p_weight NUMERIC, p_date DATE)
LANGUAGE plpgsql AS $$
BEGIN
  IF p_weight IS NULL OR p_weight <= 0 THEN
    RAISE EXCEPTION 'Weight must be greater than zero';
  END IF;
  IF p_date IS NULL THEN
    RAISE EXCEPTION 'Delivery date is required';
  END IF;
  PERFORM fn_maize_rate(p_grade);                    -- rejects NULL / unsupported grade
  PERFORM 1 FROM farmers WHERE farmer_id = p_farmer_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown farmer %', p_farmer_id;
  END IF;
  INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid)
  VALUES (p_farmer_id, p_grade, p_weight, p_date, FALSE);   -- unit_rate/total_value by trigger
END $$;

-- (a) Seed data (loaded after the trigger; direct SQL gets the same pricing)
INSERT INTO farmers (farmer_number, full_name) VALUES
  ('F001', 'Joseph Zimba'), ('F002', 'Agnes Moyo'), ('F003', 'Patrick Sinkala');
INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid) VALUES
  (1, 'A', 100.00, CURRENT_DATE - 3, FALSE),   -- K500 unpaid
  (1, 'B',  50.50, CURRENT_DATE - 2, TRUE),
  (2, 'C', 200.00, CURRENT_DATE - 2, FALSE),   -- K600 unpaid
  (2, 'A',  80.00, CURRENT_DATE - 1, TRUE),
  (3, 'B', 120.00, CURRENT_DATE - 1, TRUE),
  (3, 'C',  75.25, CURRENT_DATE - 1, TRUE);

-- Tests
SELECT fn_maize_rate('A'), fn_maize_rate('B'), fn_maize_rate('C');
CALL pr_receive_delivery(3, 'A', 60.00, CURRENT_DATE);
DO $$ BEGIN CALL pr_receive_delivery(99, 'A', 10, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_receive_delivery(1, 'D', 10, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_receive_delivery(1, 'A', -5, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN INSERT INTO deliveries (farmer_id, grade, weight_kg, unit_rate, total_value)
            VALUES (1, 'A', 10, 99, 990);            -- direct SQL cannot override pricing
            RAISE NOTICE 'Stored rate: %', (SELECT unit_rate FROM deliveries ORDER BY delivery_id DESC LIMIT 1);
            RAISE EXCEPTION 'rollback demo';
EXCEPTION WHEN OTHERS THEN RAISE NOTICE '%', SQLERRM; END $$;
SELECT * FROM deliveries ORDER BY delivery_id;

-- (e) View (LEFT JOIN + COALESCE gives zero for farmers with nothing unpaid)
CREATE OR REPLACE VIEW v_farmer_amount_due AS
SELECT f.farmer_number, f.full_name,
       COALESCE(SUM(d.total_value) FILTER (WHERE NOT d.is_paid), 0) AS unpaid_amount
FROM farmers f
LEFT JOIN deliveries d ON d.farmer_id = f.farmer_id
GROUP BY f.farmer_id, f.farmer_number, f.full_name;
SELECT * FROM v_farmer_amount_due ORDER BY farmer_number;

-- (f) Composite index
CREATE INDEX idx_deliveries_farmer_date ON deliveries (farmer_id, delivered_on);
ANALYZE deliveries;
SET enable_seqscan = off;
EXPLAIN SELECT * FROM deliveries
WHERE farmer_id = 1 AND delivered_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
RESET enable_seqscan;
-- Justification: equality on farmer_id then range on delivered_on follows the
-- left-to-right rule, so a farmer's deliveries between two dates are read from
-- one contiguous index range; the same index helps the unpaid-amount view.

-- (g) Scheduled job
CREATE OR REPLACE PROCEDURE pr_refresh_purchases(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO daily_purchases (purchase_date, total_weight, total_value)
  SELECT p_day, COALESCE(SUM(weight_kg), 0), COALESCE(SUM(total_value), 0)
  FROM deliveries WHERE delivered_on = p_day
  ON CONFLICT (purchase_date) DO UPDATE
    SET total_weight = EXCLUDED.total_weight, total_value = EXCLUDED.total_value;
END $$;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('refresh-purchases', '30 1 * * *',
  $$CALL pr_refresh_purchases(CURRENT_DATE - 1)$$);

CALL pr_refresh_purchases(CURRENT_DATE - 1);
CALL pr_refresh_purchases(CURRENT_DATE - 1);   -- rerun replaces, never adds again
SELECT * FROM daily_purchases;
