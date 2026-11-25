DROP SCHEMA IF EXISTS q5 CASCADE;

CREATE SCHEMA q5;

SET search_path TO q5, public;

CREATE TABLE students (
    student_id      INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_number  VARCHAR(20)  NOT NULL UNIQUE,
    full_name       VARCHAR(100) NOT NULL
);

CREATE TABLE rooms (
    room_id      INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    room_number  VARCHAR(10) NOT NULL UNIQUE,
    capacity     INTEGER     NOT NULL CHECK (capacity > 0)
);

CREATE TABLE allocations (
    allocation_id  INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_id     INTEGER     NOT NULL REFERENCES students (student_id),
    room_id        INTEGER     NOT NULL REFERENCES rooms (room_id),
    allocated_on   DATE        NOT NULL,
    released_on    DATE        NULL,
    status         VARCHAR(6)  NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE', 'ENDED')),
    CONSTRAINT chk_status_release CHECK (
           (status = 'ACTIVE' AND released_on IS NULL)
        OR (status = 'ENDED'  AND released_on IS NOT NULL)),
    CONSTRAINT chk_release_after_alloc CHECK (released_on IS NULL OR released_on >= allocated_on)
);

CREATE TABLE occupancy_snapshot (
    snapshot_date  DATE    NOT NULL,
    room_id        INTEGER NOT NULL REFERENCES rooms (room_id),
    occupied_beds  INTEGER NOT NULL CHECK (occupied_beds >= 0),
    free_beds      INTEGER NOT NULL,
    PRIMARY KEY (snapshot_date, room_id)
);

INSERT INTO rooms (room_number, capacity) VALUES
    ('A101', 2),
    ('A102', 3),
    ('A103', 2);

INSERT INTO students (student_number, full_name) VALUES
    ('2024020201', 'Mwila Banda'),
    ('2024020202', 'Chanda Phiri'),
    ('2024020203', 'Natasha Zulu'),
    ('2024020204', 'Joseph Mulenga'),
    ('2024020205', 'Grace Tembo'),
    ('2024020206', 'Peter Lungu');

CREATE OR REPLACE FUNCTION fn_free_beds(p_room_id INTEGER)
RETURNS INTEGER
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_capacity rooms.capacity%TYPE;
    v_active   INTEGER;
BEGIN
    SELECT capacity INTO v_capacity
    FROM   rooms
    WHERE  room_id = p_room_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room id %', p_room_id;
    END IF;
    SELECT COUNT(*) INTO v_active
    FROM   allocations
    WHERE  room_id = p_room_id
    AND    status  = 'ACTIVE';
    RETURN v_capacity - v_active;
END;
$$;

CREATE OR REPLACE PROCEDURE pr_allocate_room(
    p_student_id   INTEGER,
    p_room_id      INTEGER,
    p_allocated_on DATE DEFAULT CURRENT_DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_allocated_on IS NULL THEN
        RAISE EXCEPTION 'Allocation date must not be NULL';
    END IF;
    PERFORM 1 FROM students WHERE student_id = p_student_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student id %', p_student_id;
    END IF;
    PERFORM 1 FROM rooms WHERE room_id = p_room_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room id %', p_room_id;
    END IF;
    IF EXISTS (SELECT 1 FROM allocations
               WHERE student_id = p_student_id AND status = 'ACTIVE') THEN
        RAISE EXCEPTION 'Student % already has an ACTIVE allocation', p_student_id;
    END IF;
    IF fn_free_beds(p_room_id) <= 0 THEN
        RAISE EXCEPTION 'Room % is full', p_room_id;
    END IF;
    INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
    VALUES (p_student_id, p_room_id, p_allocated_on, NULL, 'ACTIVE');
END;
$$;

CREATE OR REPLACE FUNCTION trg_fn_allocations_rules()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_self_id  allocations.allocation_id%TYPE;
    v_capacity rooms.capacity%TYPE;
    v_others   INTEGER;
BEGIN
    IF NEW.status <> 'ACTIVE' THEN
        RETURN NEW;
    END IF;
    IF TG_OP = 'UPDATE' THEN
        v_self_id := OLD.allocation_id;
    END IF;
    PERFORM 1 FROM students WHERE student_id = NEW.student_id FOR UPDATE;
    SELECT capacity INTO v_capacity
    FROM   rooms
    WHERE  room_id = NEW.room_id
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room id %', NEW.room_id;
    END IF;
    IF EXISTS (SELECT 1 FROM allocations
               WHERE student_id = NEW.student_id
               AND   status = 'ACTIVE'
               AND   allocation_id IS DISTINCT FROM v_self_id) THEN
        RAISE EXCEPTION 'Student % already has an ACTIVE allocation', NEW.student_id;
    END IF;
    SELECT COUNT(*) INTO v_others
    FROM   allocations
    WHERE  room_id = NEW.room_id
    AND    status  = 'ACTIVE'
    AND    allocation_id IS DISTINCT FROM v_self_id;
    IF v_others >= v_capacity THEN
        RAISE EXCEPTION 'Room % is full (capacity %)', NEW.room_id, v_capacity;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_allocations_rules
BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW
EXECUTE FUNCTION trg_fn_allocations_rules();

INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status) VALUES
    (4, 3, CURRENT_DATE - 90, CURRENT_DATE - 60, 'ENDED'),
    (5, 1, CURRENT_DATE - 80, CURRENT_DATE - 50, 'ENDED');

CALL pr_allocate_room(1, 1, CURRENT_DATE - 30);

CALL pr_allocate_room(2, 1, CURRENT_DATE - 30);

CALL pr_allocate_room(3, 2, CURRENT_DATE - 20);

CALL pr_allocate_room(4, 2, CURRENT_DATE - 10);

CREATE OR REPLACE VIEW v_room_occupancy AS
SELECT r.room_id,
       r.room_number,
       r.capacity,
       COUNT(a.allocation_id)              AS occupied_beds,
       r.capacity - COUNT(a.allocation_id) AS free_beds
FROM   rooms r
LEFT JOIN allocations a
       ON a.room_id = r.room_id
      AND a.status  = 'ACTIVE'
GROUP  BY r.room_id, r.room_number, r.capacity;

CREATE INDEX idx_allocations_active_room ON allocations (room_id) WHERE status = 'ACTIVE';

ANALYZE allocations;

SET enable_seqscan = off;

EXPLAIN ANALYZE
SELECT COUNT(*) FROM allocations WHERE room_id = 1 AND status = 'ACTIVE';

RESET enable_seqscan;

CREATE OR REPLACE PROCEDURE pr_refresh_occupancy()
LANGUAGE plpgsql
SET search_path = q5, public
AS $$
BEGIN
    INSERT INTO occupancy_snapshot (snapshot_date, room_id, occupied_beds, free_beds)
    SELECT CURRENT_DATE, room_id, occupied_beds, free_beds
    FROM   v_room_occupancy
    ON CONFLICT (snapshot_date, room_id) DO UPDATE
    SET    occupied_beds = EXCLUDED.occupied_beds,
           free_beds     = EXCLUDED.free_beds;
END;
$$;

SELECT cron.schedule(
    'q5_refresh_occupancy',
    '55 23 * * *',
    $$CALL q5.pr_refresh_occupancy()$$
);
