-- ICT371 Q6 Monthly Payroll Processing (PostgreSQL + pg_cron)
DROP TABLE IF EXISTS salary_audit, payroll, employees CASCADE;

-- (a) Tables
CREATE TABLE employees (
  employee_id  INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  full_name    VARCHAR(100) NOT NULL,
  basic_salary NUMERIC(12,2) NOT NULL CHECK (basic_salary >= 0),
  allowance    NUMERIC(12,2) NOT NULL CHECK (allowance >= 0),
  deduction    NUMERIC(12,2) NOT NULL CHECK (deduction >= 0),
  active       BOOLEAN NOT NULL DEFAULT TRUE
);
CREATE TABLE payroll (
  payroll_id  INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  employee_id INT NOT NULL REFERENCES employees(employee_id),
  pay_month   DATE NOT NULL CHECK (EXTRACT(DAY FROM pay_month) = 1),
  gross_pay   NUMERIC(12,2) NOT NULL CHECK (gross_pay >= 0),
  net_pay     NUMERIC(12,2) NOT NULL CHECK (net_pay >= 0),
  CONSTRAINT uq_payroll_emp_month UNIQUE (employee_id, pay_month)
);
CREATE TABLE salary_audit (
  audit_id    INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  employee_id INT NOT NULL REFERENCES employees(employee_id),
  old_salary  NUMERIC(12,2) NOT NULL,
  new_salary  NUMERIC(12,2) NOT NULL,
  changed_at  TIMESTAMP NOT NULL DEFAULT now()
);

-- (b) Function
CREATE OR REPLACE FUNCTION fn_net_pay(p_employee_id INT)
RETURNS NUMERIC LANGUAGE plpgsql AS $$
DECLARE v_net NUMERIC(12,2);
BEGIN
  SELECT basic_salary + allowance - deduction INTO v_net
  FROM employees WHERE employee_id = p_employee_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown employee %', p_employee_id;
  END IF;
  IF v_net < 0 THEN
    RAISE EXCEPTION 'Negative net pay (%) for employee %', v_net, p_employee_id;
  END IF;
  RETURN v_net;
END $$;

-- (c) Procedure: query FOR loop; an exception aborts and rolls back the whole call
CREATE OR REPLACE PROCEDURE pr_process_payroll(p_month DATE)
LANGUAGE plpgsql AS $$
DECLARE r RECORD; v_net NUMERIC(12,2);
BEGIN
  IF p_month IS NULL OR EXTRACT(DAY FROM p_month) <> 1 THEN
    RAISE EXCEPTION 'p_month must be the first day of a month, got %', p_month;
  END IF;
  FOR r IN SELECT employee_id, basic_salary, allowance
           FROM employees WHERE active ORDER BY employee_id
  LOOP
    v_net := fn_net_pay(r.employee_id);          -- raises on invalid calculation
    INSERT INTO payroll (employee_id, pay_month, gross_pay, net_pay)
    VALUES (r.employee_id, p_month, r.basic_salary + r.allowance, v_net)
    ON CONFLICT (employee_id, pay_month) DO NOTHING;   -- existing rows stay unchanged
  END LOOP;
END $$;

-- (d) Trigger
CREATE OR REPLACE FUNCTION trg_fn_salary_audit() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO salary_audit (employee_id, old_salary, new_salary)
  VALUES (OLD.employee_id, OLD.basic_salary, NEW.basic_salary);
  RETURN NEW;
END $$;
CREATE TRIGGER trg_salary_audit
AFTER UPDATE ON employees
FOR EACH ROW
WHEN (OLD.basic_salary IS DISTINCT FROM NEW.basic_salary)
EXECUTE FUNCTION trg_fn_salary_audit();

-- (a) Seed data: two payroll months, then one employee becomes inactive
INSERT INTO employees (full_name, basic_salary, allowance, deduction) VALUES
  ('Alice Mumba', 8000.00, 1500.00, 1200.00),
  ('Brian Tembo', 6500.00, 1000.00,  900.00),
  ('Chola Mwale', 7200.00, 1200.00, 1000.00),
  ('Dan Kunda',   5000.00,  800.00,  600.00);
CALL pr_process_payroll(DATE '2026-09-01');
CALL pr_process_payroll(DATE '2026-10-01');
UPDATE employees SET active = FALSE WHERE employee_id = 4;   -- inactive, history retained

-- Tests
SELECT fn_net_pay(1);                                        -- 8300.00
CALL pr_process_payroll(DATE '2026-10-01');                  -- rerun: nothing changes
SELECT COUNT(*) FROM payroll;                                -- still 8 (4 employees x 2 months)
DO $$ BEGIN CALL pr_process_payroll(DATE '2026-10-15');
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
UPDATE employees SET basic_salary = 8500.00 WHERE employee_id = 1;   -- audited
UPDATE employees SET basic_salary = 8500.00 WHERE employee_id = 1;   -- unchanged: no audit
SELECT * FROM salary_audit;
-- Whole-call failure demo: an employee whose deductions exceed pay
INSERT INTO employees (full_name, basic_salary, allowance, deduction) VALUES ('Bad Data', 100, 0, 500);
DO $$ BEGIN CALL pr_process_payroll(DATE '2026-11-01');
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Whole call failed: %', SQLERRM; END $$;
SELECT COUNT(*) FROM payroll WHERE pay_month = '2026-11-01';          -- 0 rows: rolled back
DELETE FROM employees WHERE full_name = 'Bad Data';

-- (e) View (inner join keeps payroll history of inactive staff)
CREATE OR REPLACE VIEW v_payroll_report AS
SELECT e.employee_id, e.full_name, p.pay_month, p.gross_pay, p.net_pay
FROM payroll p JOIN employees e ON e.employee_id = p.employee_id;
SELECT * FROM v_payroll_report ORDER BY pay_month, employee_id;

-- (f) Index: pay_month alone
CREATE INDEX idx_payroll_pay_month ON payroll (pay_month);
ANALYZE payroll;
SET enable_seqscan = off;
EXPLAIN SELECT * FROM v_payroll_report WHERE pay_month = DATE '2026-10-01';
RESET enable_seqscan;
-- Justification: the unique index is (employee_id, pay_month); pay_month is its
-- SECOND column so it cannot efficiently answer "all employees for a month".
-- A single-column pay_month index fills that gap without duplicating the
-- unique index.

-- (g) Scheduled job: 02:00 on day 1, processing the previous month
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('monthly-payroll', '0 2 1 * *',
  $$CALL pr_process_payroll((date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date)$$);

-- Inspect the job and its run history
SELECT jobid, jobname, schedule, command, active FROM cron.job;
SELECT jobid, status, return_message, start_time, end_time
FROM cron.job_run_details ORDER BY start_time DESC;
