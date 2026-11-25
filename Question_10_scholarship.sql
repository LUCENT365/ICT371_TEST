DROP SCHEMA IF EXISTS q10 CASCADE;

CREATE SCHEMA q10;

SET search_path TO q10, public;

CREATE TABLE students (
    student_id      INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_number  VARCHAR(20)  NOT NULL UNIQUE,
    full_name       VARCHAR(100) NOT NULL
);

CREATE TABLE applications (
    application_id      INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_id          INTEGER       NOT NULL REFERENCES students (student_id),
    age_at_application  INTEGER       NOT NULL CHECK (age_at_application > 0),
    monthly_income      NUMERIC(12,2) NOT NULL CHECK (monthly_income >= 0),
    average_mark        NUMERIC(5,2)  NOT NULL CHECK (average_mark BETWEEN 0 AND 100),
    submitted_on        DATE          NOT NULL DEFAULT CURRENT_DATE,
    status              VARCHAR(8)    NOT NULL DEFAULT 'PENDING'
        CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED'))
);

CREATE TABLE decision_audit (
    audit_id        INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    application_id  INTEGER     NOT NULL REFERENCES applications (application_id),
    old_status      VARCHAR(8)  NOT NULL,
    new_status      VARCHAR(8)  NOT NULL,
    changed_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO students (student_number, full_name) VALUES
    ('2025030301', 'Mwila Banda'),
    ('2025030302', 'Chanda Phiri'),
    ('2025030303', 'Natasha Zulu'),
    ('2025030304', 'Joseph Mulenga');

INSERT INTO applications (student_id, age_at_application, monthly_income, average_mark, submitted_on) VALUES
    (1, 18, 3000.00, 70.00, CURRENT_DATE - 40),
    (1, 19, 3000.01, 75.00, CURRENT_DATE - 10),
    (2, 25, 2200.00, 82.00, CURRENT_DATE - 35),
    (2, 25, 1800.00, 69.99, CURRENT_DATE - 5),
    (3, 26, 1500.00, 88.00, CURRENT_DATE - 20),
    (4, 17,  900.00, 91.00, CURRENT_DATE - 15);

CREATE OR REPLACE FUNCTION fn_scholarship_eligible(
    p_age    INTEGER,
    p_income NUMERIC,
    p_mark   NUMERIC)
RETURNS BOOLEAN
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
        RAISE EXCEPTION 'Age, income and mark are all required (got %, %, %)', p_age, p_income, p_mark;
    END IF;
    IF p_age <= 0 THEN
        RAISE EXCEPTION 'Invalid age %: must be positive', p_age;
    END IF;
    IF p_income < 0 THEN
        RAISE EXCEPTION 'Invalid income %: must not be negative', p_income;
    END IF;
    IF p_mark < 0 OR p_mark > 100 THEN
        RAISE EXCEPTION 'Invalid mark %: must be between 0 and 100', p_mark;
    END IF;
    RETURN p_age BETWEEN 18 AND 25
       AND p_income <= 3000
       AND p_mark   >= 70;
END;
$$;

CREATE OR REPLACE PROCEDURE pr_assess_application(p_application_id INTEGER)
LANGUAGE plpgsql
AS $$
DECLARE
    v_app      applications%ROWTYPE;
    v_eligible BOOLEAN;
BEGIN
    SELECT * INTO v_app
    FROM   applications
    WHERE  application_id = p_application_id
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Application % does not exist', p_application_id;
    END IF;
    IF v_app.status <> 'PENDING' THEN
        RAISE EXCEPTION 'Application % has already been assessed (status %)',
                        p_application_id, v_app.status;
    END IF;
    v_eligible := fn_scholarship_eligible(v_app.age_at_application,
                                          v_app.monthly_income,
                                          v_app.average_mark);
    UPDATE applications
    SET    status = CASE WHEN v_eligible THEN 'APPROVED' ELSE 'REJECTED' END
    WHERE  application_id = p_application_id;
END;
$$;

CREATE OR REPLACE FUNCTION trg_fn_decision_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.status IS DISTINCT FROM OLD.status THEN
        INSERT INTO decision_audit (application_id, old_status, new_status, changed_at)
        VALUES (NEW.application_id, OLD.status, NEW.status, now());
    END IF;
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_applications_decision_audit
AFTER UPDATE ON applications
FOR EACH ROW
EXECUTE FUNCTION trg_fn_decision_audit();

CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT s.student_number,
       s.full_name,
       a.average_mark,
       a.status
FROM   applications a
JOIN   students s ON s.student_id = a.student_id
WHERE  a.status = 'APPROVED';

CREATE INDEX idx_applications_status_submitted ON applications (status, submitted_on);

ANALYZE applications;

SET enable_seqscan = off;

EXPLAIN ANALYZE
SELECT application_id, student_id, submitted_on
FROM   applications
WHERE  status = 'PENDING'
AND    submitted_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;

RESET enable_seqscan;

CREATE OR REPLACE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql
SET search_path = q10, public
AS $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN
        SELECT application_id
        FROM   applications
        WHERE  status = 'PENDING'
        ORDER  BY submitted_on, application_id
    LOOP
        CALL pr_assess_application(r.application_id);
    END LOOP;
END;
$$;

SELECT cron.schedule(
    'q10_assess_pending',
    '0 8 * * 1',
    $$CALL q10.pr_assess_pending()$$
);
