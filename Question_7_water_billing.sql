DROP SCHEMA IF EXISTS q7 CASCADE;

CREATE SCHEMA q7;

SET search_path TO q7, public;

CREATE TABLE customers (
    customer_id  INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name    VARCHAR(100) NOT NULL
);

CREATE TABLE readings (
    reading_id        INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id       INTEGER       NOT NULL REFERENCES customers (customer_id),
    reading_month     DATE          NOT NULL CHECK (EXTRACT(DAY FROM reading_month) = 1),
    previous_reading  NUMERIC(12,2) NOT NULL CHECK (previous_reading >= 0),
    current_reading   NUMERIC(12,2) NOT NULL CHECK (current_reading  >= 0),
    CONSTRAINT uq_readings_customer_month UNIQUE (customer_id, reading_month)
);

CREATE TABLE bills (
    bill_id      INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    reading_id   INTEGER       NOT NULL UNIQUE REFERENCES readings (reading_id),
    charge       NUMERIC(12,2) NOT NULL CHECK (charge >= 0),
    amount_paid  NUMERIC(12,2) NOT NULL DEFAULT 0,
    due_on       DATE          NOT NULL,
    CONSTRAINT chk_amount_paid CHECK (amount_paid BETWEEN 0 AND charge)
);

CREATE TABLE receivable_snapshot (
    snapshot_date  DATE          PRIMARY KEY,
    total_due      NUMERIC(14,2) NOT NULL CHECK (total_due >= 0)
);

INSERT INTO customers (full_name) VALUES ('Mwila Banda'), ('Chanda Phiri'), ('Natasha Zulu');

CREATE OR REPLACE FUNCTION fn_water_charge(p_units NUMERIC)
RETURNS NUMERIC
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF p_units IS NULL OR p_units < 0 THEN
        RAISE EXCEPTION 'Invalid consumption %: must be zero or more', p_units;
    END IF;
    RETURN round(LEAST(p_units, 10) * 5.00
               + GREATEST(p_units - 10, 0) * 8.00, 2);
END;
$$;

CREATE OR REPLACE PROCEDURE pr_generate_bill(p_reading_id INTEGER, p_due_on DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_prev   readings.previous_reading%TYPE;
    v_curr   readings.current_reading%TYPE;
    v_month  readings.reading_month%TYPE;
    v_charge NUMERIC(12,2);
BEGIN
    SELECT previous_reading, current_reading, reading_month
    INTO   v_prev, v_curr, v_month
    FROM   readings
    WHERE  reading_id = p_reading_id
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown reading id %', p_reading_id;
    END IF;
    IF EXISTS (SELECT 1 FROM bills WHERE reading_id = p_reading_id) THEN
        RAISE EXCEPTION 'Reading % has already been billed', p_reading_id;
    END IF;
    IF p_due_on IS NULL OR p_due_on < v_month THEN
        RAISE EXCEPTION 'Invalid due date % for reading month %', p_due_on, v_month;
    END IF;
    v_charge := fn_water_charge(v_curr - v_prev);
    INSERT INTO bills (reading_id, charge, amount_paid, due_on)
    VALUES (p_reading_id, v_charge, 0, p_due_on);
END;
$$;

CREATE OR REPLACE FUNCTION trg_fn_readings_validate()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.current_reading < NEW.previous_reading THEN
        RAISE EXCEPTION 'Reading rejected for customer % (%): current % is below previous %',
                        NEW.customer_id, NEW.reading_month,
                        NEW.current_reading, NEW.previous_reading;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_readings_validate
BEFORE INSERT OR UPDATE ON readings
FOR EACH ROW
EXECUTE FUNCTION trg_fn_readings_validate();

INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading) VALUES
    (1, (date_trunc('month', CURRENT_DATE) - INTERVAL '2 months')::DATE, 100.00, 100.00),
    (1, (date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::DATE,  100.00, 110.00),
    (2, (date_trunc('month', CURRENT_DATE) - INTERVAL '2 months')::DATE, 250.00, 263.50),
    (2, (date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::DATE,  263.50, 280.00),
    (3, (date_trunc('month', CURRENT_DATE) - INTERVAL '2 months')::DATE,  40.00,  47.00),
    (3, (date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::DATE,   47.00,  72.00);

CALL pr_generate_bill(1, CURRENT_DATE - 20);

CALL pr_generate_bill(2, CURRENT_DATE - 1);

CALL pr_generate_bill(3, CURRENT_DATE - 20);

CALL pr_generate_bill(4, CURRENT_DATE + 10);

CALL pr_generate_bill(5, CURRENT_DATE - 20);

CALL pr_generate_bill(6, CURRENT_DATE + 10);

UPDATE bills SET amount_paid = charge WHERE reading_id = 3;

UPDATE bills SET amount_paid = 20.00  WHERE reading_id = 5;

CREATE OR REPLACE VIEW v_overdue_bills AS
SELECT b.bill_id,
       c.full_name,
       b.due_on,
       b.charge - b.amount_paid AS outstanding_amount
FROM   bills b
JOIN   readings  r ON r.reading_id  = b.reading_id
JOIN   customers c ON c.customer_id = r.customer_id
WHERE  b.due_on < CURRENT_DATE
AND    b.amount_paid < b.charge;

CREATE INDEX idx_bills_unpaid_due_on ON bills (due_on) WHERE amount_paid < charge;

ANALYZE bills;

SET enable_seqscan = off;

EXPLAIN ANALYZE
SELECT bill_id, due_on, charge - amount_paid AS outstanding
FROM   bills
WHERE  due_on < CURRENT_DATE
AND    amount_paid < charge;

RESET enable_seqscan;

CREATE OR REPLACE PROCEDURE pr_refresh_receivables()
LANGUAGE plpgsql
SET search_path = q7, public
AS $$
BEGIN
    INSERT INTO receivable_snapshot (snapshot_date, total_due)
    SELECT CURRENT_DATE, COALESCE(SUM(charge - amount_paid), 0)
    FROM   bills
    WHERE  amount_paid < charge
    ON CONFLICT (snapshot_date) DO UPDATE
    SET    total_due = EXCLUDED.total_due;
END;
$$;

SELECT cron.schedule(
    'q7_refresh_receivables',
    '30 0 * * *',
    $$CALL q7.pr_refresh_receivables()$$
);
