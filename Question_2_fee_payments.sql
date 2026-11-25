DROP SCHEMA IF EXISTS q2 CASCADE;

CREATE SCHEMA q2;

SET search_path TO q2, public;

CREATE TABLE students (
    student_id      INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_number  VARCHAR(20)   NOT NULL UNIQUE,
    full_name       VARCHAR(100)  NOT NULL,
    fee_due         NUMERIC(12,2) NOT NULL CHECK (fee_due >= 0)
);

CREATE TABLE payments (
    payment_id  INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_id  INTEGER       NOT NULL REFERENCES students (student_id),
    amount      NUMERIC(12,2) NOT NULL CHECK (amount > 0),
    paid_on     DATE          NOT NULL DEFAULT CURRENT_DATE
);

CREATE TABLE payment_audit (
    audit_id    INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    payment_id  INTEGER       NOT NULL REFERENCES payments (payment_id),
    student_id  INTEGER       NOT NULL REFERENCES students (student_id),
    amount      NUMERIC(12,2) NOT NULL,
    logged_at   TIMESTAMPTZ   NOT NULL DEFAULT now()
);

CREATE TABLE daily_collections (
    collection_date  DATE          PRIMARY KEY,
    payment_count    INTEGER       NOT NULL CHECK (payment_count >= 0),
    total_amount     NUMERIC(14,2) NOT NULL CHECK (total_amount >= 0)
);

INSERT INTO students (student_number, full_name, fee_due) VALUES
    ('2023010101', 'Mwila Banda',    15000.00),
    ('2023010102', 'Chanda Phiri',   12000.00),
    ('2023010103', 'Natasha Zulu',    9000.00);

CREATE OR REPLACE FUNCTION fn_fee_balance(p_student_id INTEGER)
RETURNS NUMERIC
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_fee  students.fee_due%TYPE;
    v_paid NUMERIC(12,2);
BEGIN
    SELECT fee_due INTO v_fee
    FROM   students
    WHERE  student_id = p_student_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student id %', p_student_id;
    END IF;
    SELECT COALESCE(SUM(amount), 0) INTO v_paid
    FROM   payments
    WHERE  student_id = p_student_id;
    RETURN v_fee - v_paid;
END;
$$;

CREATE OR REPLACE PROCEDURE pr_receive_payment(
    p_student_id INTEGER,
    p_amount     NUMERIC,
    p_paid_on    DATE DEFAULT CURRENT_DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_balance NUMERIC(12,2);
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Invalid payment amount %: must be greater than zero', p_amount;
    END IF;
    IF p_amount <> round(p_amount, 2) THEN
        RAISE EXCEPTION 'Invalid payment amount %: at most 2 decimal places', p_amount;
    END IF;
    IF p_paid_on IS NULL OR p_paid_on > CURRENT_DATE THEN
        RAISE EXCEPTION 'Invalid payment date %', p_paid_on;
    END IF;
    PERFORM 1 FROM students WHERE student_id = p_student_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student id %', p_student_id;
    END IF;
    v_balance := fn_fee_balance(p_student_id);
    IF p_amount > v_balance THEN
        RAISE EXCEPTION 'Payment of K% exceeds outstanding balance of K% for student %',
                        p_amount, v_balance, p_student_id;
    END IF;
    INSERT INTO payments (student_id, amount, paid_on)
    VALUES (p_student_id, p_amount, p_paid_on);
END;
$$;

CREATE OR REPLACE FUNCTION trg_fn_payments_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO payment_audit (payment_id, student_id, amount, logged_at)
    VALUES (NEW.payment_id, NEW.student_id, NEW.amount, now());
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_payments_audit
AFTER INSERT ON payments
FOR EACH ROW
EXECUTE FUNCTION trg_fn_payments_audit();

CALL pr_receive_payment(1, 5000.00, CURRENT_DATE - 3);

CALL pr_receive_payment(2, 3000.00, CURRENT_DATE - 3);

CALL pr_receive_payment(1, 4000.00, CURRENT_DATE - 2);

CALL pr_receive_payment(2, 2500.00, CURRENT_DATE - 1);

CALL pr_receive_payment(2, 1500.00, CURRENT_DATE - 1);

CALL pr_receive_payment(1, 6000.00, CURRENT_DATE - 1);

CREATE OR REPLACE VIEW v_fee_balances AS
SELECT s.student_number,
       s.full_name,
       s.fee_due - COALESCE(p.total_paid, 0) AS outstanding_balance
FROM   students s
LEFT JOIN (SELECT student_id, SUM(amount) AS total_paid
           FROM   payments
           GROUP  BY student_id) p
       ON p.student_id = s.student_id
WHERE  s.fee_due - COALESCE(p.total_paid, 0) > 0;

CREATE INDEX idx_payments_student_paidon ON payments (student_id, paid_on);

ANALYZE payments;

SET enable_seqscan = off;

EXPLAIN ANALYZE
SELECT payment_id, amount, paid_on
FROM   payments
WHERE  student_id = 2
AND    paid_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;

RESET enable_seqscan;

CREATE OR REPLACE PROCEDURE pr_refresh_collections(p_day DATE)
LANGUAGE plpgsql
SET search_path = q2, public
AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'p_day must not be NULL';
    END IF;
    INSERT INTO daily_collections (collection_date, payment_count, total_amount)
    SELECT p_day, COUNT(*), COALESCE(SUM(amount), 0)
    FROM   payments
    WHERE  paid_on = p_day
    ON CONFLICT (collection_date) DO UPDATE
    SET    payment_count = EXCLUDED.payment_count,
           total_amount  = EXCLUDED.total_amount;
END;
$$;

SELECT cron.schedule(
    'q2_refresh_collections',
    '0 1 * * *',
    $$CALL q2.pr_refresh_collections(CURRENT_DATE - 1)$$
);
