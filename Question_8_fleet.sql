DROP SCHEMA IF EXISTS q8 CASCADE;

CREATE SCHEMA q8;

SET search_path TO q8, public;

CREATE TABLE vehicles (
    vehicle_id             INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    registration           VARCHAR(15) NOT NULL UNIQUE,
    current_odometer       INTEGER     NOT NULL CHECK (current_odometer >= 0),
    last_service_odometer  INTEGER     NOT NULL CHECK (last_service_odometer >= 0),
    CONSTRAINT chk_service_not_ahead CHECK (last_service_odometer <= current_odometer)
);

CREATE TABLE trips (
    trip_id         INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    vehicle_id      INTEGER NOT NULL REFERENCES vehicles (vehicle_id),
    trip_on         DATE    NOT NULL,
    start_odometer  INTEGER NOT NULL CHECK (start_odometer >= 0),
    end_odometer    INTEGER NOT NULL,
    CONSTRAINT chk_trip_distance CHECK (end_odometer > start_odometer)
);

CREATE TABLE service_alerts (
    vehicle_id        INTEGER PRIMARY KEY REFERENCES vehicles (vehicle_id),
    km_since_service  INTEGER NOT NULL CHECK (km_since_service >= 0),
    flagged_on        DATE    NOT NULL DEFAULT CURRENT_DATE
);

INSERT INTO vehicles (registration, current_odometer, last_service_odometer) VALUES
    ('ABZ 1234', 120000, 116500),
    ('BAF 5678',  45200,  45000),
    ('ALT 9012',  80300,  74000);

CREATE OR REPLACE FUNCTION fn_service_due(p_vehicle_id INTEGER)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_km INTEGER;
BEGIN
    SELECT current_odometer - last_service_odometer
    INTO   v_km
    FROM   vehicles
    WHERE  vehicle_id = p_vehicle_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle id %', p_vehicle_id;
    END IF;
    RETURN v_km >= 5000;
END;
$$;

CREATE OR REPLACE PROCEDURE pr_record_trip(
    p_vehicle_id INTEGER,
    p_trip_on    DATE,
    p_start      INTEGER,
    p_end        INTEGER)
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM vehicles WHERE vehicle_id = p_vehicle_id) THEN
        RAISE EXCEPTION 'Unknown vehicle id %', p_vehicle_id;
    END IF;
    IF p_trip_on IS NULL OR p_start IS NULL OR p_end IS NULL THEN
        RAISE EXCEPTION 'Trip date and odometer values are required';
    END IF;
    IF p_end <= p_start THEN
        RAISE EXCEPTION 'End odometer % must be greater than start odometer %', p_end, p_start;
    END IF;
    INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
    VALUES (p_vehicle_id, p_trip_on, p_start, p_end);
END;
$$;

CREATE OR REPLACE FUNCTION trg_fn_trips_odometer()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_current vehicles.current_odometer%TYPE;
BEGIN
    SELECT current_odometer INTO v_current
    FROM   vehicles
    WHERE  vehicle_id = NEW.vehicle_id
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle id %', NEW.vehicle_id;
    END IF;
    IF NEW.start_odometer IS NULL OR NEW.end_odometer IS NULL
       OR NEW.end_odometer <= NEW.start_odometer THEN
        RAISE EXCEPTION 'Invalid mileage: start %, end %', NEW.start_odometer, NEW.end_odometer;
    END IF;
    IF NEW.start_odometer <> v_current THEN
        RAISE EXCEPTION 'Trip start % does not match vehicle %''s current odometer %',
                        NEW.start_odometer, NEW.vehicle_id, v_current;
    END IF;
    UPDATE vehicles
    SET    current_odometer = NEW.end_odometer
    WHERE  vehicle_id = NEW.vehicle_id;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_trips_odometer
BEFORE INSERT ON trips
FOR EACH ROW
EXECUTE FUNCTION trg_fn_trips_odometer();

CALL pr_record_trip(1, CURRENT_DATE - 6, 120000, 120800);

CALL pr_record_trip(1, CURRENT_DATE - 3, 120800, 121700);

CALL pr_record_trip(2, CURRENT_DATE - 5,  45200,  45550);

CALL pr_record_trip(2, CURRENT_DATE - 2,  45550,  45800);

CALL pr_record_trip(3, CURRENT_DATE - 4,  80300,  80950);

CALL pr_record_trip(3, CURRENT_DATE - 1,  80950,  81400);

CREATE OR REPLACE VIEW v_service_due AS
SELECT registration,
       current_odometer - last_service_odometer AS km_since_service
FROM   vehicles
WHERE  fn_service_due(vehicle_id);

CREATE INDEX idx_trips_vehicle_trip_on ON trips (vehicle_id, trip_on);

ANALYZE trips;

SET enable_seqscan = off;

EXPLAIN ANALYZE
SELECT trip_id, trip_on, start_odometer, end_odometer
FROM   trips
WHERE  vehicle_id = 1
AND    trip_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;

RESET enable_seqscan;

CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql
SET search_path = q8, public
AS $$
BEGIN
    INSERT INTO service_alerts (vehicle_id, km_since_service, flagged_on)
    SELECT vehicle_id,
           current_odometer - last_service_odometer,
           CURRENT_DATE
    FROM   vehicles
    WHERE  fn_service_due(vehicle_id)
    ON CONFLICT (vehicle_id) DO UPDATE
    SET    km_since_service = EXCLUDED.km_since_service;
    DELETE FROM service_alerts sa
    WHERE  NOT fn_service_due(sa.vehicle_id);
END;
$$;

SELECT cron.schedule(
    'q8_refresh_service_alerts',
    '0 6 * * 1',
    $$CALL q8.pr_refresh_service_alerts()$$
);
