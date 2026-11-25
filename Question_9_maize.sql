DROP SCHEMA IF EXISTS q9 CASCADE;

CREATE SCHEMA q9;

SET search_path TO q9, public;

CREATE TABLE farmers (
    farmer_id      INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    farmer_number  VARCHAR(20)  NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL
);

CREATE TABLE deliveries (
    delivery_id   INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    farmer_id     INTEGER       NOT NULL REFERENCES farmers (farmer_id),
    grade         CHAR(1)       NOT NULL CHECK (grade IN ('A', 'B', 'C')),
    weight_kg     NUMERIC(10,2) NOT NULL CHECK (weight_kg > 0),
    unit_rate     NUMERIC(10,2) NOT NULL,
    total_value   NUMERIC(12,2) NOT NULL,
    delivered_on  DATE          NOT NULL,
    is_paid       BOOLEAN       NOT NULL DEFAULT FALSE
);

CREATE TABLE daily_purchases (
    purchase_date  DATE          PRIMARY KEY,
    total_weight   NUMERIC(14,2) NOT NULL CHECK (total_weight >= 0),
    total_value    NUMERIC(14,2) NOT NULL CHECK (total_value  >= 0)
);

INSERT INTO farmers (farmer_number, full_name) VALUES
    ('KBW-001', 'Mwila Banda'),
    ('KBW-002', 'Chanda Phiri'),
    ('KBW-003', 'Natasha Zulu');

CREATE OR REPLACE FUNCTION fn_maize_rate(p_grade TEXT)
RETURNS NUMERIC
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v_rate NUMERIC(10,2);
BEGIN
    IF p_grade IS NULL THEN
        RAISE EXCEPTION 'Grade must not be NULL';
    END IF;
    v_rate := CASE upper(trim(p_grade))
                  WHEN 'A' THEN 5.00
                  WHEN 'B' THEN 4.00
                  WHEN 'C' THEN 3.00
              END;
    IF v_rate IS NULL THEN
        RAISE EXCEPTION 'Unsupported grade "%": use A, B or C', p_grade;
    END IF;
    RETURN v_rate;
END;
$$;

CREATE OR REPLACE PROCEDURE pr_receive_delivery(
    p_farmer_id INTEGER,
    p_grade     TEXT,
    p_weight    NUMERIC,
    p_date      DATE DEFAULT CURRENT_DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM farmers WHERE farmer_id = p_farmer_id) THEN
        RAISE EXCEPTION 'Unknown farmer id %', p_farmer_id;
    END IF;
    IF p_weight IS NULL OR p_weight <= 0 THEN
        RAISE EXCEPTION 'Invalid weight %: must be greater than zero', p_weight;
    END IF;
    IF p_date IS NULL OR p_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'Invalid delivery date %', p_date;
    END IF;
    PERFORM fn_maize_rate(p_grade);
    INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid)
    VALUES (p_farmer_id, upper(trim(p_grade)), p_weight, p_date, FALSE);
END;
$$;

CREATE OR REPLACE FUNCTION trg_fn_deliveries_pricing()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.weight_kg IS NULL OR NEW.weight_kg <= 0 THEN
        RAISE EXCEPTION 'Invalid weight %: must be greater than zero', NEW.weight_kg;
    END IF;
    NEW.grade       := upper(NEW.grade);
    NEW.unit_rate   := fn_maize_rate(NEW.grade);
    NEW.total_value := round(NEW.weight_kg * NEW.unit_rate, 2);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_deliveries_pricing
BEFORE INSERT OR UPDATE ON deliveries
FOR EACH ROW
EXECUTE FUNCTION trg_fn_deliveries_pricing();

CALL pr_receive_delivery(1, 'A', 500.00, CURRENT_DATE - 2);

CALL pr_receive_delivery(1, 'B', 300.00, CURRENT_DATE - 1);

CALL pr_receive_delivery(2, 'C', 450.50, CURRENT_DATE - 2);

CALL pr_receive_delivery(2, 'A', 200.00, CURRENT_DATE - 1);

CALL pr_receive_delivery(3, 'B', 150.00, CURRENT_DATE - 1);

CALL pr_receive_delivery(3, 'C', 100.00, CURRENT_DATE - 1);

UPDATE deliveries SET is_paid = TRUE WHERE delivery_id IN (2, 5, 6);

CREATE OR REPLACE VIEW v_farmer_amount_due AS
SELECT f.farmer_number,
       f.full_name,
       COALESCE(SUM(d.total_value), 0)::NUMERIC(14,2) AS amount_due
FROM   farmers f
LEFT JOIN deliveries d
       ON d.farmer_id = f.farmer_id
      AND NOT d.is_paid
GROUP  BY f.farmer_id, f.farmer_number, f.full_name;

CREATE INDEX idx_deliveries_farmer_date ON deliveries (farmer_id, delivered_on);

ANALYZE deliveries;

SET enable_seqscan = off;

EXPLAIN ANALYZE
SELECT delivery_id, grade, weight_kg, total_value, delivered_on
FROM   deliveries
WHERE  farmer_id = 1
AND    delivered_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;

RESET enable_seqscan;

CREATE OR REPLACE PROCEDURE pr_refresh_purchases(p_day DATE)
LANGUAGE plpgsql
SET search_path = q9, public
AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'p_day must not be NULL';
    END IF;
    INSERT INTO daily_purchases (purchase_date, total_weight, total_value)
    SELECT p_day,
           COALESCE(SUM(weight_kg), 0),
           COALESCE(SUM(total_value), 0)
    FROM   deliveries
    WHERE  delivered_on = p_day
    ON CONFLICT (purchase_date) DO UPDATE
    SET    total_weight = EXCLUDED.total_weight,
           total_value  = EXCLUDED.total_value;
END;
$$;

SELECT cron.schedule(
    'q9_refresh_purchases',
    '30 1 * * *',
    $$CALL q9.pr_refresh_purchases(CURRENT_DATE - 1)$$
);
