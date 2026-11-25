-- ICT371 Q3 Library Returns and Overdue Fines (PostgreSQL + pg_cron)
DROP TABLE IF EXISTS overdue_summary, loan_audit, loans, books CASCADE;

-- (a) Tables
CREATE TABLE books (
  book_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  title   VARCHAR(150) NOT NULL
);
CREATE TABLE loans (
  loan_id       INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  book_id       INT NOT NULL REFERENCES books(book_id),
  borrower_name VARCHAR(100) NOT NULL,
  borrowed_on   DATE NOT NULL,
  due_on        DATE NOT NULL,
  returned_on   DATE,
  fine_amount   NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (fine_amount >= 0),
  CONSTRAINT ck_due_after_borrow CHECK (due_on >= borrowed_on),
  CONSTRAINT ck_return_after_borrow CHECK (returned_on IS NULL OR returned_on >= borrowed_on)
);
CREATE TABLE loan_audit (
  audit_id         INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  loan_id          INT NOT NULL REFERENCES loans(loan_id),
  old_returned_on  DATE,
  new_returned_on  DATE,
  changed_at       TIMESTAMP NOT NULL DEFAULT now()
);
CREATE TABLE overdue_summary (
  snapshot_date DATE PRIMARY KEY,
  overdue_count INT NOT NULL,
  total_fine    NUMERIC(12,2) NOT NULL
);

-- (b) Function: K2 per day late, never negative, stops at the return date
CREATE OR REPLACE FUNCTION fn_loan_fine(p_loan_id INT, p_as_of DATE)
RETURNS NUMERIC LANGUAGE plpgsql AS $$
DECLARE v_due DATE; v_ret DATE;
BEGIN
  IF p_as_of IS NULL THEN
    RAISE EXCEPTION 'As-of date is required';
  END IF;
  SELECT due_on, returned_on INTO v_due, v_ret FROM loans WHERE loan_id = p_loan_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown loan %', p_loan_id;
  END IF;
  RETURN 2 * GREATEST(LEAST(p_as_of, COALESCE(v_ret, p_as_of)) - v_due, 0);
END $$;

-- (c) Procedure: return date and final fine stored in ONE update
CREATE OR REPLACE PROCEDURE pr_return_loan(p_loan_id INT, p_returned_on DATE)
LANGUAGE plpgsql AS $$
DECLARE v_borrowed DATE; v_due DATE; v_ret DATE;
BEGIN
  IF p_returned_on IS NULL THEN
    RAISE EXCEPTION 'Return date is required';
  END IF;
  SELECT borrowed_on, due_on, returned_on INTO v_borrowed, v_due, v_ret
  FROM loans WHERE loan_id = p_loan_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown loan %', p_loan_id;
  END IF;
  IF v_ret IS NOT NULL THEN
    RAISE EXCEPTION 'Loan % was already returned on %', p_loan_id, v_ret;
  END IF;
  IF p_returned_on < v_borrowed THEN
    RAISE EXCEPTION 'Return date % is before borrow date %', p_returned_on, v_borrowed;
  END IF;
  UPDATE loans
  SET returned_on = p_returned_on,
      fine_amount = 2 * GREATEST(p_returned_on - v_due, 0)
  WHERE loan_id = p_loan_id;
END $$;

-- (d) Trigger
CREATE OR REPLACE FUNCTION trg_fn_loan_audit() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO loan_audit (loan_id, old_returned_on, new_returned_on)
  VALUES (OLD.loan_id, OLD.returned_on, NEW.returned_on);
  RETURN NEW;
END $$;
CREATE TRIGGER trg_loan_audit
AFTER UPDATE ON loans
FOR EACH ROW
WHEN (OLD.returned_on IS DISTINCT FROM NEW.returned_on)
EXECUTE FUNCTION trg_fn_loan_audit();

-- (a) Seed data
INSERT INTO books (title) VALUES ('Database Systems'), ('Operating Systems'), ('Computer Networks');
INSERT INTO loans (book_id, borrower_name, borrowed_on, due_on) VALUES
  (1, 'Alice Mumba',  CURRENT_DATE - 30, CURRENT_DATE - 16),  -- open, overdue
  (1, 'Brian Tembo',  CURRENT_DATE - 5,  CURRENT_DATE + 9),   -- open, on time
  (2, 'Chola Mwale',  CURRENT_DATE - 40, CURRENT_DATE - 26),  -- returned late
  (2, 'Dan Kunda',    CURRENT_DATE - 20, CURRENT_DATE - 6),   -- returned on due date
  (3, 'Eve Sakala',   CURRENT_DATE - 10, CURRENT_DATE + 4),   -- open, not due
  (3, 'Frank Lungu',  CURRENT_DATE - 12, CURRENT_DATE - 2);   -- open, overdue
CALL pr_return_loan(3, CURRENT_DATE - 20);   -- 6 days late -> K12
CALL pr_return_loan(4, CURRENT_DATE - 6);    -- on due date -> K0

-- Tests
SELECT loan_id, fn_loan_fine(loan_id, CURRENT_DATE) AS fine_today, fine_amount FROM loans ORDER BY loan_id;
DO $$ BEGIN CALL pr_return_loan(3, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_return_loan(999, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_return_loan(1, CURRENT_DATE - 100);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
SELECT * FROM loan_audit;

-- (e) View
CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT l.loan_id, b.title, l.borrower_name, l.due_on,
       fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_as_of_today
FROM loans l JOIN books b ON b.book_id = l.book_id
WHERE l.returned_on IS NULL AND l.due_on < CURRENT_DATE;
SELECT * FROM v_overdue_loans;

-- (f) Partial index: only unreturned loans are indexed, keyed by book
CREATE INDEX idx_loans_open_by_book ON loans (book_id) WHERE returned_on IS NULL;
ANALYZE loans;
SET enable_seqscan = off;
EXPLAIN SELECT * FROM loans WHERE book_id = 1 AND returned_on IS NULL;
RESET enable_seqscan;
-- Justification: the index is small (returned loans are excluded) and
-- matches the query predicate exactly, so one book's open loans are found directly.

-- (g) Scheduled job: overdue loans as of p_as_of (unreturned on that date and past due)
CREATE OR REPLACE PROCEDURE pr_refresh_overdue(p_as_of DATE)
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO overdue_summary (snapshot_date, overdue_count, total_fine)
  SELECT p_as_of, COUNT(*), COALESCE(SUM(fn_loan_fine(loan_id, p_as_of)), 0)
  FROM loans
  WHERE borrowed_on <= p_as_of
    AND (returned_on IS NULL OR returned_on > p_as_of)
    AND due_on < p_as_of
  ON CONFLICT (snapshot_date) DO UPDATE
    SET overdue_count = EXCLUDED.overdue_count, total_fine = EXCLUDED.total_fine;
END $$;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('refresh-overdue', '10 0 * * *', $$CALL pr_refresh_overdue(CURRENT_DATE)$$);

CALL pr_refresh_overdue(CURRENT_DATE);
CALL pr_refresh_overdue(CURRENT_DATE);   -- rerun replaces same snapshot_date
SELECT * FROM overdue_summary;
