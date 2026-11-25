DROP SCHEMA IF EXISTS q4 CASCADE;

CREATE SCHEMA q4;

SET search_path TO q4, public;

CREATE TABLE patients (
    patient_id  INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name   VARCHAR(100) NOT NULL
);

CREATE TABLE doctors (
    doctor_id  INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name  VARCHAR(100) NOT NULL
);

CREATE TABLE appointments (
    appointment_id   INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    patient_id       INTEGER     NOT NULL REFERENCES patients (patient_id),
    doctor_id        INTEGER     NOT NULL REFERENCES doctors (doctor_id),
    appointment_day  DATE        NOT NULL,
    slot_time        TIME        NOT NULL
        CHECK (slot_time IN (TIME '09:00', TIME '10:00', TIME '11:00', TIME '12:00')),
    status           VARCHAR(10) NOT NULL DEFAULT 'BOOKED'
        CHECK (status IN ('BOOKED', 'ATTENDED', 'CANCELLED'))
);

CREATE TABLE clinic_summary (
    summary_date     DATE    PRIMARY KEY,
    booked_count     INTEGER NOT NULL CHECK (booked_count    >= 0),
    attended_count   INTEGER NOT NULL CHECK (attended_count  >= 0),
    cancelled_count  INTEGER NOT NULL CHECK (cancelled_count >= 0)
);

INSERT INTO patients (full_name) VALUES ('Mwila Banda'), ('Chanda Phiri'), ('Natasha Zulu');

INSERT INTO doctors  (full_name) VALUES ('Dr J. Mulenga'), ('Dr G. Tembo'), ('Dr P. Lungu');

CREATE OR REPLACE FUNCTION fn_daily_load(p_doctor_id INTEGER, p_day DATE)
RETURNS INTEGER
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_count INTEGER;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM doctors WHERE doctor_id = p_doctor_id) THEN
        RAISE EXCEPTION 'Unknown doctor id %', p_doctor_id;
    END IF;
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'p_day must not be NULL';
    END IF;
    SELECT COUNT(*) INTO v_count
    FROM   appointments
    WHERE  doctor_id       = p_doctor_id
    AND    appointment_day = p_day
    AND    status <> 'CANCELLED';
    RETURN v_count;
END;
$$;

CREATE OR REPLACE PROCEDURE pr_book_appointment(
    p_patient_id INTEGER,
    p_doctor_id  INTEGER,
    p_day        DATE,
    p_slot       TIME)
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM patients WHERE patient_id = p_patient_id) THEN
        RAISE EXCEPTION 'Unknown patient id %', p_patient_id;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM doctors WHERE doctor_id = p_doctor_id) THEN
        RAISE EXCEPTION 'Unknown doctor id %', p_doctor_id;
    END IF;
    IF p_day IS NULL OR p_day < CURRENT_DATE THEN
        RAISE EXCEPTION 'Cannot book on % : date is missing or in the past', p_day;
    END IF;
    IF p_slot IS NULL OR p_slot NOT IN (TIME '09:00', TIME '10:00', TIME '11:00', TIME '12:00') THEN
        RAISE EXCEPTION 'Unsupported slot %: use 09:00, 10:00, 11:00 or 12:00', p_slot;
    END IF;
    INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status)
    VALUES (p_patient_id, p_doctor_id, p_day, p_slot, 'BOOKED');
END;
$$;

CREATE OR REPLACE FUNCTION trg_fn_appointments_no_clash()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_self_id appointments.appointment_id%TYPE;
BEGIN
    IF NEW.status = 'CANCELLED' THEN
        RETURN NEW;
    END IF;
    IF TG_OP = 'UPDATE' THEN
        v_self_id := OLD.appointment_id;
    END IF;
    PERFORM pg_advisory_xact_lock(NEW.doctor_id, NEW.appointment_day - DATE '2000-01-01');
    IF EXISTS (
        SELECT 1
        FROM   appointments a
        WHERE  a.doctor_id       = NEW.doctor_id
        AND    a.appointment_day = NEW.appointment_day
        AND    a.slot_time       = NEW.slot_time
        AND    a.status <> 'CANCELLED'
        AND    a.appointment_id IS DISTINCT FROM v_self_id
    ) THEN
        RAISE EXCEPTION 'Slot clash: doctor % already has an appointment on % at %',
                        NEW.doctor_id, NEW.appointment_day, NEW.slot_time;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_appointments_no_clash
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW
EXECUTE FUNCTION trg_fn_appointments_no_clash();

INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status) VALUES
    (1, 1, CURRENT_DATE - 1, '09:00', 'ATTENDED'),
    (2, 1, CURRENT_DATE - 1, '10:00', 'CANCELLED'),
    (3, 1, CURRENT_DATE - 1, '10:00', 'ATTENDED');

CALL pr_book_appointment(1, 2, CURRENT_DATE,     '10:00');

CALL pr_book_appointment(2, 3, CURRENT_DATE,     '11:00');

CALL pr_book_appointment(3, 1, CURRENT_DATE + 1, '09:00');

CREATE OR REPLACE VIEW v_today_appointments AS
SELECT a.slot_time,
       p.full_name AS patient_name,
       d.full_name AS doctor_name
FROM   appointments a
JOIN   patients p ON p.patient_id = a.patient_id
JOIN   doctors  d ON d.doctor_id  = a.doctor_id
WHERE  a.appointment_day = CURRENT_DATE
AND    a.status = 'BOOKED';

CREATE INDEX idx_appointments_day_doctor ON appointments (appointment_day, doctor_id);

ANALYZE appointments;

SET enable_seqscan = off;

EXPLAIN ANALYZE
SELECT appointment_id, slot_time, status
FROM   appointments
WHERE  appointment_day = CURRENT_DATE
AND    doctor_id = 2;

RESET enable_seqscan;

CREATE OR REPLACE PROCEDURE pr_refresh_clinic_summary(p_day DATE)
LANGUAGE plpgsql
SET search_path = q4, public
AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'p_day must not be NULL';
    END IF;
    INSERT INTO clinic_summary (summary_date, booked_count, attended_count, cancelled_count)
    SELECT p_day,
           COUNT(*) FILTER (WHERE status = 'BOOKED'),
           COUNT(*) FILTER (WHERE status = 'ATTENDED'),
           COUNT(*) FILTER (WHERE status = 'CANCELLED')
    FROM   appointments
    WHERE  appointment_day = p_day
    ON CONFLICT (summary_date) DO UPDATE
    SET    booked_count    = EXCLUDED.booked_count,
           attended_count  = EXCLUDED.attended_count,
           cancelled_count = EXCLUDED.cancelled_count;
END;
$$;

SELECT cron.schedule(
    'q4_refresh_clinic_summary',
    '0 1 * * *',
    $$CALL q4.pr_refresh_clinic_summary(CURRENT_DATE - 1)$$
);
