-- ICT371 Q5 Hostel Room Allocation (PostgreSQL + pg_cron)
DROP TABLE IF EXISTS occupancy_snapshot, allocations, rooms, students CASCADE;

-- (a) Tables
CREATE TABLE students (
  student_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  student_number VARCHAR(20) NOT NULL UNIQUE,
  full_name      VARCHAR(100) NOT NULL
);
CREATE TABLE rooms (
  room_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  room_number VARCHAR(10) NOT NULL UNIQUE,
  capacity    INT NOT NULL CHECK (capacity > 0)
);
CREATE TABLE allocations (
  allocation_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  student_id    INT NOT NULL REFERENCES students(student_id),
  room_id       INT NOT NULL REFERENCES rooms(room_id),
  allocated_on  DATE NOT NULL,
  released_on   DATE,
  status        VARCHAR(10) NOT NULL CHECK (status IN ('ACTIVE', 'ENDED')),
  CONSTRAINT ck_status_release CHECK (
    (status = 'ACTIVE' AND released_on IS NULL) OR
    (status = 'ENDED'  AND released_on IS NOT NULL)),
  CONSTRAINT ck_release_order CHECK (released_on IS NULL OR released_on >= allocated_on)
);
CREATE TABLE occupancy_snapshot (
  snapshot_date DATE NOT NULL,
  room_id       INT NOT NULL REFERENCES rooms(room_id),
  occupied_beds INT NOT NULL,
  free_beds     INT NOT NULL,
  PRIMARY KEY (snapshot_date, room_id)
);

-- (b) Function
CREATE OR REPLACE FUNCTION fn_free_beds(p_room_id INT)
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE v_cap INT;
BEGIN
  SELECT capacity INTO v_cap FROM rooms WHERE room_id = p_room_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown room %', p_room_id;
  END IF;
  RETURN v_cap - (SELECT COUNT(*)::INT FROM allocations
                  WHERE room_id = p_room_id AND status = 'ACTIVE');
END $$;

-- (d) Trigger: enforces rules for direct SQL too
CREATE OR REPLACE FUNCTION trg_fn_allocation_rules() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_cap INT; v_cnt INT;
BEGIN
  IF NEW.status = 'ACTIVE' THEN
    SELECT capacity INTO v_cap FROM rooms WHERE room_id = NEW.room_id FOR UPDATE; -- lock room
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Unknown room %', NEW.room_id;
    END IF;
    IF EXISTS (SELECT 1 FROM allocations
               WHERE student_id = NEW.student_id AND status = 'ACTIVE'
                 AND allocation_id IS DISTINCT FROM NEW.allocation_id) THEN
      RAISE EXCEPTION 'Student % already has an ACTIVE allocation', NEW.student_id;
    END IF;
    SELECT COUNT(*) INTO v_cnt FROM allocations
    WHERE room_id = NEW.room_id AND status = 'ACTIVE'
      AND allocation_id IS DISTINCT FROM NEW.allocation_id;     -- exclude row being updated
    IF v_cnt >= v_cap THEN
      RAISE EXCEPTION 'Room % is full (capacity %)', NEW.room_id, v_cap;
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_allocation_rules
BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW EXECUTE FUNCTION trg_fn_allocation_rules();

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_allocate_room(p_student_id INT, p_room_id INT, p_allocated_on DATE)
LANGUAGE plpgsql AS $$
BEGIN
  IF p_allocated_on IS NULL THEN
    RAISE EXCEPTION 'Allocation date is required';
  END IF;
  PERFORM 1 FROM students WHERE student_id = p_student_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown student %', p_student_id; END IF;
  PERFORM 1 FROM rooms WHERE room_id = p_room_id FOR UPDATE;   -- serialise per room
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown room %', p_room_id; END IF;
  IF EXISTS (SELECT 1 FROM allocations WHERE student_id = p_student_id AND status = 'ACTIVE') THEN
    RAISE EXCEPTION 'Student % already has an ACTIVE allocation', p_student_id;
  END IF;
  IF fn_free_beds(p_room_id) <= 0 THEN
    RAISE EXCEPTION 'Room % has no free beds', p_room_id;
  END IF;
  INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
  VALUES (p_student_id, p_room_id, p_allocated_on, NULL, 'ACTIVE');
END $$;

-- (a) Seed data: R101 full, R102 partly occupied, R103 empty (history only)
INSERT INTO students (student_number, full_name) VALUES
  ('H001', 'Alice Mumba'), ('H002', 'Brian Tembo'), ('H003', 'Chola Mwale'),
  ('H004', 'Dan Kunda'),   ('H005', 'Eve Sakala'),  ('H006', 'Frank Lungu');
INSERT INTO rooms (room_number, capacity) VALUES ('R101', 2), ('R102', 3), ('R103', 2);
INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status) VALUES
  (1, 1, CURRENT_DATE - 60, NULL, 'ACTIVE'),
  (2, 1, CURRENT_DATE - 60, NULL, 'ACTIVE'),
  (3, 2, CURRENT_DATE - 30, NULL, 'ACTIVE'),
  (4, 3, CURRENT_DATE - 90, CURRENT_DATE - 20, 'ENDED');
CALL pr_allocate_room(5, 2, CURRENT_DATE);

-- Tests
SELECT room_id, fn_free_beds(room_id) AS free_beds FROM rooms ORDER BY room_id; -- 0, 1, 2
DO $$ BEGIN CALL pr_allocate_room(6, 1, CURRENT_DATE);   -- full room
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_allocate_room(1, 3, CURRENT_DATE);   -- already ACTIVE
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN INSERT INTO allocations (student_id, room_id, allocated_on, status)  -- direct SQL
            VALUES (6, 1, CURRENT_DATE, 'ACTIVE');
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

-- (e) View (LEFT JOIN keeps empty rooms)
CREATE OR REPLACE VIEW v_room_occupancy AS
SELECT r.room_id, r.room_number, r.capacity,
       COUNT(a.allocation_id)::INT AS occupied_beds,
       r.capacity - COUNT(a.allocation_id)::INT AS free_beds
FROM rooms r
LEFT JOIN allocations a ON a.room_id = r.room_id AND a.status = 'ACTIVE'
GROUP BY r.room_id, r.room_number, r.capacity;
SELECT * FROM v_room_occupancy ORDER BY room_id;

-- (f) Partial index on ACTIVE rows
CREATE INDEX idx_alloc_active_room ON allocations (room_id) WHERE status = 'ACTIVE';
ANALYZE allocations;
SET enable_seqscan = off;
EXPLAIN SELECT * FROM allocations WHERE room_id = 2 AND status = 'ACTIVE';
RESET enable_seqscan;
-- Justification: only ACTIVE rows occupy beds and every capacity check filters
-- by room and ACTIVE; ENDED history grows forever but is kept out of the index.

-- (g) Scheduled job
CREATE OR REPLACE PROCEDURE pr_refresh_occupancy()
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO occupancy_snapshot (snapshot_date, room_id, occupied_beds, free_beds)
  SELECT CURRENT_DATE, r.room_id, COUNT(a.allocation_id), r.capacity - COUNT(a.allocation_id)
  FROM rooms r
  LEFT JOIN allocations a ON a.room_id = r.room_id AND a.status = 'ACTIVE'
  GROUP BY r.room_id, r.capacity
  ON CONFLICT (snapshot_date, room_id) DO UPDATE
    SET occupied_beds = EXCLUDED.occupied_beds, free_beds = EXCLUDED.free_beds;
END $$;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('refresh-occupancy', '55 23 * * *', $$CALL pr_refresh_occupancy()$$);

CALL pr_refresh_occupancy();
CALL pr_refresh_occupancy();   -- rerun replaces values, one row per date and room
SELECT * FROM occupancy_snapshot ORDER BY room_id;
