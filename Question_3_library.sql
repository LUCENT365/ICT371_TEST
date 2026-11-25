DROP SCHEMA IF EXISTS q3 CASCADE;

CREATE SCHEMA q3;

SET search_path TO q3, public;

CREATE TABLE books (
    book_id  INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    title    VARCHAR(200) NOT NULL
);

CREATE TABLE loans (
    loan_id        INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    book_id        INTEGER       NOT NULL REFERENCES books (book_id),
    borrower_name  VARCHAR(100)  NOT NULL,
    borrowed_on    DATE          NOT NULL,
    due_on         DATE          NOT NULL,
    returned_on    DATE          NULL,
    fine_amount    NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (fine_amount >= 0),
    CONSTRAINT chk_due_after_borrow    CHECK (due_on >= borrowed_on),
    CONSTRAINT chk_return_after_borrow CHECK (returned_on IS NULL OR returned_on >= borrowed_on)
);

CREATE TABLE loan_audit (
    audit_id         INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    loan_id          INTEGER     NOT NULL REFERENCES loans (loan_id),
    old_returned_on  DATE        NULL,
    new_returned_on  DATE        NULL,
    changed_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE overdue_summary (
    snapshot_date  DATE          PRIMARY KEY,
    overdue_count  INTEGER       NOT NULL CHECK (overdue_count >= 0),
    total_fine     NUMERIC(12,2) NOT NULL CHECK (total_fine >= 0)
);

INSERT INTO books (title) VALUES
    ('Database System Concepts'),
    ('Things Fall Apart'),
    ('Introduction to Algorithms');

INSERT INTO loans (book_id, borrower_name, borrowed_on, due_on) VALUES
    (1, 'Mwila Banda',   CURRENT_DATE - 30, CURRENT_DATE - 16),
    (2, 'Chanda Phiri',  CURRENT_DATE - 20, CURRENT_DATE - 6),
    (3, 'Natasha Zulu',  CURRENT_DATE - 5,  CURRENT_DATE + 9),
    (1, 'Joseph Mulenga',CURRENT_DATE - 40, CURRENT_DATE - 26),
    (2, 'Grace Tembo',   CURRENT_DATE - 35, CURRENT_DATE - 21),
    (3, 'Peter Lungu',   CURRENT_DATE - 14, CURRENT_DATE - 7);

CREATE OR REPLACE FUNCTION fn_loan_fine(p_loan_id INTEGER, p_as_of DATE)
RETURNS NUMERIC
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_due      loans.due_on%TYPE;
    v_returned loans.returned_on%TYPE;
    v_end      DATE;
BEGIN
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'p_as_of must not be NULL';
    END IF;
    SELECT due_on, returned_on
    INTO   v_due, v_returned
    FROM   loans
    WHERE  loan_id = p_loan_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan id %', p_loan_id;
    END IF;
    IF v_returned IS NOT NULL THEN
        v_end := LEAST(p_as_of, v_returned);
    ELSE
        v_end := p_as_of;
    END IF;
    RETURN GREATEST(v_end - v_due, 0) * 2.00;
END;
$$;

CREATE OR REPLACE PROCEDURE pr_return_loan(p_loan_id INTEGER, p_returned_on DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_borrowed loans.borrowed_on%TYPE;
    v_returned loans.returned_on%TYPE;
    v_fine     NUMERIC(10,2);
BEGIN
    IF p_returned_on IS NULL THEN
        RAISE EXCEPTION 'Return date must not be NULL';
    END IF;
    SELECT borrowed_on, returned_on
    INTO   v_borrowed, v_returned
    FROM   loans
    WHERE  loan_id = p_loan_id
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan id %', p_loan_id;
    END IF;
    IF v_returned IS NOT NULL THEN
        RAISE EXCEPTION 'Loan % was already returned on %', p_loan_id, v_returned;
    END IF;
    IF p_returned_on < v_borrowed THEN
        RAISE EXCEPTION 'Return date % is before borrow date %', p_returned_on, v_borrowed;
    END IF;
    IF p_returned_on > CURRENT_DATE THEN
        RAISE EXCEPTION 'Return date % is in the future', p_returned_on;
    END IF;
    v_fine := fn_loan_fine(p_loan_id, p_returned_on);
    UPDATE loans
    SET    returned_on = p_returned_on,
           fine_amount = v_fine
    WHERE  loan_id = p_loan_id;
END;
$$;

CREATE OR REPLACE FUNCTION trg_fn_loans_return_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.returned_on IS DISTINCT FROM OLD.returned_on THEN
        INSERT INTO loan_audit (loan_id, old_returned_on, new_returned_on, changed_at)
        VALUES (NEW.loan_id, OLD.returned_on, NEW.returned_on, now());
    END IF;
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_loans_return_audit
AFTER UPDATE ON loans
FOR EACH ROW
EXECUTE FUNCTION trg_fn_loans_return_audit();

CALL pr_return_loan(4, CURRENT_DATE - 27);

CALL pr_return_loan(5, CURRENT_DATE - 18);

CALL pr_return_loan(6, CURRENT_DATE - 7);

CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT l.loan_id,
       b.title,
       l.borrower_name,
       l.due_on,
       fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_as_of_today
FROM   loans l
JOIN   books b ON b.book_id = l.book_id
WHERE  l.returned_on IS NULL
AND    l.due_on < CURRENT_DATE;

CREATE INDEX idx_loans_open_by_book ON loans (book_id) WHERE returned_on IS NULL;

ANALYZE loans;

SET enable_seqscan = off;

EXPLAIN ANALYZE
SELECT loan_id, borrower_name, borrowed_on, due_on
FROM   loans
WHERE  book_id = 1
AND    returned_on IS NULL;

RESET enable_seqscan;

CREATE OR REPLACE PROCEDURE pr_refresh_overdue(p_as_of DATE)
LANGUAGE plpgsql
SET search_path = q3, public
AS $$
BEGIN
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'p_as_of must not be NULL';
    END IF;
    INSERT INTO overdue_summary (snapshot_date, overdue_count, total_fine)
    SELECT p_as_of,
           COUNT(*),
           COALESCE(SUM(fn_loan_fine(loan_id, p_as_of)), 0)
    FROM   loans
    WHERE  borrowed_on <= p_as_of
    AND    (returned_on IS NULL OR returned_on > p_as_of)
    AND    due_on < p_as_of
    ON CONFLICT (snapshot_date) DO UPDATE
    SET    overdue_count = EXCLUDED.overdue_count,
           total_fine    = EXCLUDED.total_fine;
END;
$$;

SELECT cron.schedule(
    'q3_refresh_overdue',
    '10 0 * * *',
    $$CALL q3.pr_refresh_overdue(CURRENT_DATE)$$
);
