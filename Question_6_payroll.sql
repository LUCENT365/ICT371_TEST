DROP SCHEMA IF EXISTS q6 CASCADE;

CREATE SCHEMA q6;

SET search_path TO q6, public;

CREATE TABLE employees (
    employee_id   INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name     VARCHAR(100)  NOT NULL,
    basic_salary  NUMERIC(12,2) NOT NULL CHECK (basic_salary >= 0),
    allowance     NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (allowance >= 0),
    deduction     NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (deduction >= 0),
    active        BOOLEAN       NOT NULL DEFAULT TRUE
);

CREATE TABLE payroll (
    payroll_id   INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    employee_id  INTEGER       NOT NULL REFERENCES employees (employee_id),
    pay_month    DATE          NOT NULL CHECK (EXTRACT(DAY FROM pay_month) = 1),
    gross_pay    NUMERIC(12,2) NOT NULL CHECK (gross_pay >= 0),
    net_pay      NUMERIC(12,2) NOT NULL CHECK (net_pay  >= 0),
    CONSTRAINT uq_payroll_employee_month UNIQUE (employee_id, pay_month)
);

CREATE TABLE salary_audit (
    audit_id     INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    employee_id  INTEGER       NOT NULL REFERENCES employees (employee_id),
    old_salary   NUMERIC(12,2) NOT NULL,
    new_salary   NUMERIC(12,2) NOT NULL,
    changed_at   TIMESTAMPTZ   NOT NULL DEFAULT now()
);

INSERT INTO employees (full_name, basic_salary, allowance, deduction, active) VALUES
    ('Mwila Banda',    8500.00, 1500.00, 1200.00, TRUE),
    ('Chanda Phiri',   6200.00,  800.00,  900.00, TRUE),
    ('Natasha Zulu',   9800.00, 2000.00, 1750.00, TRUE),
    ('Joseph Mulenga', 5000.00,  500.00,  600.00, TRUE),
    ('Grace Tembo',    7000.00,  700.00,  800.00, FALSE);

CREATE OR REPLACE FUNCTION fn_net_pay(p_employee_id INTEGER)
RETURNS NUMERIC
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_net NUMERIC(12,2);
BEGIN
    SELECT basic_salary + allowance - deduction
    INTO   v_net
    FROM   employees
    WHERE  employee_id = p_employee_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown employee id %', p_employee_id;
    END IF;
    IF v_net < 0 THEN
        RAISE EXCEPTION 'Net pay for employee % would be negative (K%)', p_employee_id, v_net;
    END IF;
    RETURN v_net;
END;
$$;

CREATE OR REPLACE PROCEDURE pr_process_payroll(p_month DATE)
LANGUAGE plpgsql
SET search_path = q6, public
AS $$
DECLARE
    r     RECORD;
    v_net NUMERIC(12,2);
BEGIN
    IF p_month IS NULL OR p_month <> date_trunc('month', p_month)::DATE THEN
        RAISE EXCEPTION 'Pay month % must be the first day of a month', p_month;
    END IF;
    FOR r IN
        SELECT employee_id, basic_salary, allowance
        FROM   employees
        WHERE  active
        ORDER  BY employee_id
    LOOP
        IF EXISTS (SELECT 1 FROM payroll
                   WHERE employee_id = r.employee_id AND pay_month = p_month) THEN
            CONTINUE;
        END IF;
        v_net := fn_net_pay(r.employee_id);
        INSERT INTO payroll (employee_id, pay_month, gross_pay, net_pay)
        VALUES (r.employee_id, p_month, r.basic_salary + r.allowance, v_net)
        ON CONFLICT (employee_id, pay_month) DO NOTHING;
    END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION trg_fn_salary_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.basic_salary IS DISTINCT FROM OLD.basic_salary THEN
        INSERT INTO salary_audit (employee_id, old_salary, new_salary, changed_at)
        VALUES (NEW.employee_id, OLD.basic_salary, NEW.basic_salary, now());
    END IF;
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_employees_salary_audit
AFTER UPDATE ON employees
FOR EACH ROW
EXECUTE FUNCTION trg_fn_salary_audit();

CALL pr_process_payroll((date_trunc('month', CURRENT_DATE) - INTERVAL '2 months')::DATE);

UPDATE employees SET active = FALSE WHERE employee_id = 4;

CALL pr_process_payroll((date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::DATE);

CREATE OR REPLACE VIEW v_payroll_report AS
SELECT p.payroll_id,
       e.employee_id,
       e.full_name,
       p.pay_month,
       p.gross_pay,
       p.net_pay
FROM   payroll p
JOIN   employees e ON e.employee_id = p.employee_id;

CREATE INDEX idx_payroll_pay_month ON payroll (pay_month);

ANALYZE payroll;

SET enable_seqscan = off;

EXPLAIN ANALYZE
SELECT employee_id, gross_pay, net_pay
FROM   payroll
WHERE  pay_month = (date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::DATE;

RESET enable_seqscan;

SELECT cron.schedule(
    'q6_monthly_payroll',
    '0 2 1 * *',
    $$CALL q6.pr_process_payroll((date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::DATE)$$
);

SELECT jobid, jobname, schedule, command, database, username, active
FROM   cron.job
WHERE  jobname = 'q6_monthly_payroll';

SELECT d.runid, d.status, d.return_message, d.start_time, d.end_time
FROM   cron.job_run_details d
JOIN   cron.job j ON j.jobid = d.jobid
WHERE  j.jobname = 'q6_monthly_payroll'
ORDER  BY d.start_time DESC;
