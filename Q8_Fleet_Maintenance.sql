-- ICT371 Q8 Transport Fleet Maintenance (PostgreSQL + pg_cron)
DROP TABLE IF EXISTS service_alerts, trips, vehicles CASCADE;

-- (a) Tables
CREATE TABLE vehicles (
  vehicle_id            INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  registration          VARCHAR(20) NOT NULL UNIQUE,
  current_odometer      INT NOT NULL CHECK (current_odometer >= 0),
  last_service_odometer INT NOT NULL CHECK (last_service_odometer >= 0),
  CONSTRAINT ck_service_le_current CHECK (last_service_odometer <= current_odometer)
);
CREATE TABLE trips (
  trip_id        INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  vehicle_id     INT NOT NULL REFERENCES vehicles(vehicle_id),
  trip_on        DATE NOT NULL,
  start_odometer INT NOT NULL CHECK (start_odometer >= 0),
  end_odometer   INT NOT NULL CHECK (end_odometer >= 0)
);
CREATE TABLE service_alerts (
  vehicle_id       INT PRIMARY KEY REFERENCES vehicles(vehicle_id),
  km_since_service INT NOT NULL,
  flagged_on       DATE NOT NULL DEFAULT CURRENT_DATE
);

-- (b) Function
CREATE OR REPLACE FUNCTION fn_service_due(p_vehicle_id INT)
RETURNS BOOLEAN LANGUAGE plpgsql AS $$
DECLARE v_cur INT; v_last INT;
BEGIN
  SELECT current_odometer, last_service_odometer INTO v_cur, v_last
  FROM vehicles WHERE vehicle_id = p_vehicle_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown vehicle %', p_vehicle_id;
  END IF;
  RETURN (v_cur - v_last) >= 5000;
END $$;

-- (d) Trigger: validates and advances the odometer exactly once per trip
CREATE OR REPLACE FUNCTION trg_fn_trip_odometer() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_cur INT;
BEGIN
  SELECT current_odometer INTO v_cur FROM vehicles
  WHERE vehicle_id = NEW.vehicle_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown vehicle %', NEW.vehicle_id;
  END IF;
  IF NEW.start_odometer <> v_cur THEN
    RAISE EXCEPTION 'Start odometer % does not match vehicle current odometer %',
      NEW.start_odometer, v_cur;
  END IF;
  IF NEW.end_odometer <= NEW.start_odometer THEN
    RAISE EXCEPTION 'End odometer % must be greater than start odometer %',
      NEW.end_odometer, NEW.start_odometer;
  END IF;
  UPDATE vehicles SET current_odometer = NEW.end_odometer
  WHERE vehicle_id = NEW.vehicle_id;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_trip_odometer
BEFORE INSERT ON trips
FOR EACH ROW EXECUTE FUNCTION trg_fn_trip_odometer();

-- (c) Procedure (does NOT touch the odometer; the trigger does)
CREATE OR REPLACE PROCEDURE pr_record_trip(p_vehicle_id INT, p_trip_on DATE, p_start INT, p_end INT)
LANGUAGE plpgsql AS $$
BEGIN
  IF p_trip_on IS NULL OR p_start IS NULL OR p_end IS NULL THEN
    RAISE EXCEPTION 'Trip date, start and end odometer are required';
  END IF;
  PERFORM 1 FROM vehicles WHERE vehicle_id = p_vehicle_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown vehicle %', p_vehicle_id;
  END IF;
  IF p_end <= p_start THEN
    RAISE EXCEPTION 'End odometer must be greater than start odometer';
  END IF;
  INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
  VALUES (p_vehicle_id, p_trip_on, p_start, p_end);
END $$;

-- (a) Seed data (vehicles directly; trips through the procedure)
INSERT INTO vehicles (registration, current_odometer, last_service_odometer) VALUES
  ('BAB 1001', 10000,  4000),   -- 6000 km since service (due)
  ('BAC 2002', 20000, 18000),   -- 2000 km (not due)
  ('BAD 3003', 30000, 25000);   -- exactly 5000 km (due)
CALL pr_record_trip(1, CURRENT_DATE - 6, 10000, 10200);
CALL pr_record_trip(1, CURRENT_DATE - 3, 10200, 10500);
CALL pr_record_trip(2, CURRENT_DATE - 5, 20000, 20300);
CALL pr_record_trip(2, CURRENT_DATE - 2, 20300, 20800);
CALL pr_record_trip(3, CURRENT_DATE - 4, 30000, 30400);
CALL pr_record_trip(3, CURRENT_DATE - 1, 30400, 31000);

-- Tests
SELECT vehicle_id, current_odometer, fn_service_due(vehicle_id) FROM vehicles ORDER BY 1;
DO $$ BEGIN CALL pr_record_trip(1, CURRENT_DATE, 9999, 10600);   -- wrong start
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_record_trip(1, CURRENT_DATE, 10500, 10400);  -- end <= start
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_record_trip(99, CURRENT_DATE, 0, 10);        -- unknown vehicle
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

-- (e) View
CREATE OR REPLACE VIEW v_service_due AS
SELECT registration, current_odometer - last_service_odometer AS km_since_service
FROM vehicles
WHERE current_odometer - last_service_odometer >= 5000;
SELECT * FROM v_service_due;

-- (f) Index
CREATE INDEX idx_trips_vehicle_date ON trips (vehicle_id, trip_on);
ANALYZE trips;
SET enable_seqscan = off;
EXPLAIN SELECT * FROM trips
WHERE vehicle_id = 1 AND trip_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
RESET enable_seqscan;
-- Justification: equality on vehicle_id then a range on trip_on, so one vehicle's
-- trips in a period are read directly from a single ordered index range.

-- (g) Scheduled job: upsert alerts for due vehicles, delete alerts no longer due
CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO service_alerts (vehicle_id, km_since_service, flagged_on)
  SELECT vehicle_id, current_odometer - last_service_odometer, CURRENT_DATE
  FROM vehicles
  WHERE current_odometer - last_service_odometer >= 5000
  ON CONFLICT (vehicle_id) DO UPDATE SET km_since_service = EXCLUDED.km_since_service;

  DELETE FROM service_alerts sa
  WHERE NOT EXISTS (SELECT 1 FROM vehicles v
                    WHERE v.vehicle_id = sa.vehicle_id
                      AND v.current_odometer - v.last_service_odometer >= 5000);
END $$;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('refresh-service-alerts', '0 6 * * 1', $$CALL pr_refresh_service_alerts()$$);

CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts;                                  -- vehicles 1 and 3
UPDATE vehicles SET last_service_odometer = current_odometer WHERE vehicle_id = 1;  -- serviced
CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts;                                  -- vehicle 1 removed
