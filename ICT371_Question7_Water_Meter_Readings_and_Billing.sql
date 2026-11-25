
/* ============================================================
   ICT371 - ADVANCED DATABASE
   QUESTION 7: WATER METER READINGS AND BILLING

   Student Name: [Enter your full name]
   Student Number: [Enter your student number]

   This script creates the tables, sample data, function,
   procedure, trigger, view, index and scheduled job.
   ============================================================ */


/* ============================================================
   PART 1: CLEAN UP OLD QUESTION 7 OBJECTS
   ============================================================ */

DROP VIEW IF EXISTS v_overdue_bills CASCADE;

DROP TABLE IF EXISTS receivable_snapshot CASCADE;
DROP TABLE IF EXISTS bills CASCADE;
DROP TABLE IF EXISTS readings CASCADE;
DROP TABLE IF EXISTS customers CASCADE;


/* ============================================================
   PART 2: CREATE TABLES
   ============================================================ */

CREATE TABLE customers (
    customer_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name VARCHAR(100) NOT NULL
);


CREATE TABLE readings (
    reading_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id INTEGER NOT NULL,
    reading_month DATE NOT NULL,
    previous_reading NUMERIC(12,2) NOT NULL,
    current_reading NUMERIC(12,2) NOT NULL,

    CONSTRAINT fk_reading_customer
        FOREIGN KEY (customer_id)
        REFERENCES customers(customer_id),

    CONSTRAINT uq_customer_reading_month
        UNIQUE (customer_id, reading_month),

    CONSTRAINT chk_previous_reading
        CHECK (previous_reading >= 0),

    CONSTRAINT chk_current_reading
        CHECK (current_reading >= 0),

    CONSTRAINT chk_reading_month
        CHECK (EXTRACT(DAY FROM reading_month) = 1)
);


CREATE TABLE bills (
    bill_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    reading_id INTEGER NOT NULL UNIQUE,
    charge NUMERIC(12,2) NOT NULL,
    amount_paid NUMERIC(12,2) NOT NULL DEFAULT 0,
    due_on DATE NOT NULL,

    CONSTRAINT fk_bill_reading
        FOREIGN KEY (reading_id)
        REFERENCES readings(reading_id),

    CONSTRAINT chk_bill_charge
        CHECK (charge >= 0),

    CONSTRAINT chk_amount_paid
        CHECK (amount_paid >= 0 AND amount_paid <= charge)
);


CREATE TABLE receivable_snapshot (
    snapshot_date DATE PRIMARY KEY,
    total_due NUMERIC(14,2) NOT NULL
        CHECK (total_due >= 0)
);


/* ============================================================
   PART 3: INSERT THREE CUSTOMERS
   ============================================================ */

INSERT INTO customers (full_name)
VALUES
    ('John Banda'),
    ('Mary Phiri'),
    ('Peter Zulu');


/* Check the customers */

SELECT *
FROM customers
ORDER BY customer_id;


/* ============================================================
   PART 4: CREATE THE WATER CHARGE FUNCTION
   First 10 units = K5 per unit.
   Units above 10 = K8 per unit.
   ============================================================ */

CREATE OR REPLACE FUNCTION fn_water_charge(p_units NUMERIC)
RETURNS NUMERIC(12,2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_charge NUMERIC(12,2);
BEGIN
    IF p_units IS NULL THEN
        RAISE EXCEPTION 'Water consumption cannot be NULL';
    END IF;

    IF p_units < 0 THEN
        RAISE EXCEPTION 'Water consumption cannot be negative';
    END IF;

    IF p_units <= 10 THEN
        v_charge := p_units * 5;
    ELSE
        v_charge := (10 * 5) + ((p_units - 10) * 8);
    END IF;

    RETURN ROUND(v_charge, 2);
END;
$$;


/* Test the function */

SELECT
    0 AS units,
    fn_water_charge(0) AS charge

UNION ALL

SELECT
    10,
    fn_water_charge(10)

UNION ALL

SELECT
    15,
    fn_water_charge(15)

UNION ALL

SELECT
    8,
    fn_water_charge(8);


/* ============================================================
   PART 5: CREATE THE READING VALIDATION TRIGGER
   A current reading cannot be lower than the previous reading.
   ============================================================ */

CREATE OR REPLACE FUNCTION fn_validate_water_reading()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.current_reading < NEW.previous_reading THEN
        RAISE EXCEPTION
            'Invalid meter reading: current reading (%) cannot be lower than previous reading (%)',
            NEW.current_reading,
            NEW.previous_reading;
    END IF;

    RETURN NEW;
END;
$$;


DROP TRIGGER IF EXISTS trg_validate_water_reading
ON readings;


CREATE TRIGGER trg_validate_water_reading
BEFORE INSERT OR UPDATE
ON readings
FOR EACH ROW
EXECUTE FUNCTION fn_validate_water_reading();


/* ============================================================
   PART 6: INSERT SIX VALID METER READINGS
   The readings cover:
   - Zero consumption
   - Exactly 10 units
   - More than 10 units
   ============================================================ */

INSERT INTO readings
    (customer_id, reading_month, previous_reading, current_reading)
VALUES

    -- John Banda: 0 units in current month
    (1, DATE_TRUNC('month', CURRENT_DATE)::DATE, 100, 100),

    -- John Banda: exactly 10 units in previous month
    (1, (DATE_TRUNC('month', CURRENT_DATE)
         - INTERVAL '1 month')::DATE, 100, 110),

    -- Mary Phiri: 15 units in current month
    (2, DATE_TRUNC('month', CURRENT_DATE)::DATE, 50, 65),

    -- Mary Phiri: 8 units in previous month
    (2, (DATE_TRUNC('month', CURRENT_DATE)
         - INTERVAL '1 month')::DATE, 200, 208),

    -- Peter Zulu: 15 units in current month
    (3, DATE_TRUNC('month', CURRENT_DATE)::DATE, 80, 95),

    -- Peter Zulu: 0 units in previous month
    (3, (DATE_TRUNC('month', CURRENT_DATE)
         - INTERVAL '1 month')::DATE, 40, 40);


/* Check the six readings */

SELECT
    r.reading_id,
    c.full_name,
    r.reading_month,
    r.previous_reading,
    r.current_reading,
    (r.current_reading - r.previous_reading) AS units_consumed
FROM readings r
JOIN customers c
    ON r.customer_id = c.customer_id
ORDER BY r.reading_id;


/* ============================================================
   PART 7: CREATE THE BILL GENERATION PROCEDURE
   The procedure calculates consumption and generates a bill.
   ============================================================ */

CREATE OR REPLACE PROCEDURE pr_generate_bill(
    p_reading_id INTEGER,
    p_due_on DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_previous_reading NUMERIC(12,2);
    v_current_reading NUMERIC(12,2);
    v_units NUMERIC(12,2);
    v_charge NUMERIC(12,2);
BEGIN
    SELECT previous_reading, current_reading
    INTO v_previous_reading, v_current_reading
    FROM readings
    WHERE reading_id = p_reading_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Cannot generate bill: reading ID % does not exist',
            p_reading_id;
    END IF;

    IF p_due_on IS NULL THEN
        RAISE EXCEPTION 'Bill due date cannot be NULL';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM bills
        WHERE reading_id = p_reading_id
    ) THEN
        RAISE EXCEPTION
            'A bill already exists for reading ID %',
            p_reading_id;
    END IF;

    v_units := v_current_reading - v_previous_reading;

    v_charge := fn_water_charge(v_units);

    INSERT INTO bills (
        reading_id,
        charge,
        amount_paid,
        due_on
    )
    VALUES (
        p_reading_id,
        v_charge,
        0,
        p_due_on
    );

END;
$$;


/* ============================================================
   PART 8: GENERATE SIX BILLS THROUGH THE PROCEDURE
   All sample bills are due five days ago so overdue bills
   can be demonstrated.
   ============================================================ */

DO $$
DECLARE
    v_reading RECORD;
BEGIN
    FOR v_reading IN
        SELECT reading_id
        FROM readings
        ORDER BY reading_id
    LOOP
        CALL pr_generate_bill(
            v_reading.reading_id,
            CURRENT_DATE - 5
        );
    END LOOP;
END;
$$;


/* ============================================================
   PART 9: UPDATE SAMPLE PAYMENTS
   John fully pays his previous-month bill.
   Mary makes a partial payment on her previous-month bill.
   Other bills remain unpaid.
   ============================================================ */

UPDATE bills b
SET amount_paid =
    CASE
        WHEN c.full_name = 'John Banda'
             AND r.reading_month =
                 (DATE_TRUNC('month', CURRENT_DATE)
                  - INTERVAL '1 month')::DATE
        THEN b.charge

        WHEN c.full_name = 'Mary Phiri'
             AND r.reading_month =
                 (DATE_TRUNC('month', CURRENT_DATE)
                  - INTERVAL '1 month')::DATE
        THEN LEAST(20, b.charge)

        ELSE 0
    END
FROM readings r
JOIN customers c
    ON c.customer_id = r.customer_id
WHERE b.reading_id = r.reading_id;


/* Check all generated bills and payments */

SELECT
    b.bill_id,
    c.full_name,
    r.reading_month,
    (r.current_reading - r.previous_reading) AS units_consumed,
    b.charge,
    b.amount_paid,
    (b.charge - b.amount_paid) AS outstanding_amount,
    b.due_on
FROM bills b
JOIN readings r
    ON b.reading_id = r.reading_id
JOIN customers c
    ON r.customer_id = c.customer_id
ORDER BY b.bill_id;


/* ============================================================
   PART 10: CREATE THE OVERDUE BILLS VIEW
   Show only bills that are overdue and not fully paid.
   ============================================================ */

CREATE OR REPLACE VIEW v_overdue_bills AS
SELECT
    c.full_name AS customer_name,
    b.due_on,
    (b.charge - b.amount_paid) AS outstanding_amount
FROM bills b
JOIN readings r
    ON b.reading_id = r.reading_id
JOIN customers c
    ON r.customer_id = c.customer_id
WHERE b.due_on < CURRENT_DATE
  AND b.amount_paid < b.charge;


/* Display overdue bills */

SELECT *
FROM v_overdue_bills
ORDER BY due_on, customer_name;


/* ============================================================
   PART 11: CREATE AN INDEX FOR OVERDUE BILL SEARCHES

   This partial index supports searches for bills that are
   not fully paid, ordered or filtered by due date.
   ============================================================ */

CREATE INDEX IF NOT EXISTS idx_bills_overdue_due_on
ON bills (due_on)
WHERE amount_paid < charge;


/* Matching query for the index */

SELECT
    bill_id,
    due_on,
    charge,
    amount_paid,
    (charge - amount_paid) AS outstanding_amount
FROM bills
WHERE due_on < CURRENT_DATE
  AND amount_paid < charge
ORDER BY due_on;


/* EXPLAIN query plan */

EXPLAIN
SELECT
    bill_id,
    due_on,
    charge,
    amount_paid
FROM bills
WHERE due_on < CURRENT_DATE
  AND amount_paid < charge
ORDER BY due_on;


/* ============================================================
   PART 12: CREATE THE RECEIVABLES REFRESH PROCEDURE

   It stores today's total unpaid bill balances.
   Re-running it replaces today's value instead of adding
   the same total again.
   ============================================================ */

CREATE OR REPLACE PROCEDURE pr_refresh_receivables()
LANGUAGE plpgsql
AS $$
DECLARE
    v_total_due NUMERIC(14,2);
BEGIN
    SELECT COALESCE(
        SUM(charge - amount_paid),
        0
    )
    INTO v_total_due
    FROM bills
    WHERE amount_paid < charge;

    INSERT INTO receivable_snapshot (
        snapshot_date,
        total_due
    )
    VALUES (
        CURRENT_DATE,
        v_total_due
    )
    ON CONFLICT (snapshot_date)
    DO UPDATE SET
        total_due = EXCLUDED.total_due;

END;
$$;


/* Run the procedure once to create today's snapshot */

CALL pr_refresh_receivables();


/* Display the receivables snapshot */

SELECT *
FROM receivable_snapshot
ORDER BY snapshot_date;


/* ============================================================
   PART 13: SCHEDULE THE DAILY JOB AT 00:30

   The pg_cron extension must be installed and configured
   by the PostgreSQL server for automatic scheduling.
   ============================================================ */

DO $$
BEGIN
    EXECUTE 'CREATE EXTENSION IF NOT EXISTS pg_cron';

    EXECUTE $schedule$
        SELECT cron.unschedule(jobid)
        FROM cron.job
        WHERE jobname = 'ict371_daily_receivables'
    $schedule$;

    EXECUTE $schedule$
        SELECT cron.schedule(
            'ict371_daily_receivables',
            '30 0 * * *',
            'CALL pr_refresh_receivables();'
        )
    $schedule$;

    RAISE NOTICE
        'Daily receivables job scheduled for 00:30';

EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE
            'Automatic scheduling was not configured: %',
            SQLERRM;
END;
$$;


/* ============================================================
   PART 14: FINAL VERIFICATION QUERIES
   ============================================================ */


/* 1. Confirm the number of customers */

SELECT COUNT(*) AS total_customers
FROM customers;


/* 2. Confirm the number of readings */

SELECT COUNT(*) AS total_readings
FROM readings;


/* 3. Confirm the number of generated bills */

SELECT COUNT(*) AS total_bills
FROM bills;


/* 4. Display all customer readings */

SELECT
    c.full_name,
    r.reading_month,
    r.previous_reading,
    r.current_reading,
    (r.current_reading - r.previous_reading) AS units_consumed
FROM customers c
JOIN readings r
    ON c.customer_id = r.customer_id
ORDER BY c.customer_id, r.reading_month;


/* 5. Display all bills */

SELECT
    c.full_name,
    b.charge,
    b.amount_paid,
    (b.charge - b.amount_paid) AS outstanding_amount,
    b.due_on
FROM bills b
JOIN readings r
    ON b.reading_id = r.reading_id
JOIN customers c
    ON r.customer_id = c.customer_id
ORDER BY c.customer_id, r.reading_month;


/* 6. Display overdue bills */

SELECT *
FROM v_overdue_bills;


/* 7. Display today's receivables snapshot */

SELECT *
FROM receivable_snapshot
WHERE snapshot_date = CURRENT_DATE;


/* 8. Confirm the index exists */

SELECT
    indexname,
    indexdef
FROM pg_indexes
WHERE tablename = 'bills';


/* 9. Confirm the trigger exists */

SELECT
    trigger_name,
    event_manipulation,
    action_timing
FROM information_schema.triggers
WHERE event_object_table = 'readings';


/* 10. Confirm the procedures and functions */

SELECT
    routine_name,
    routine_type
FROM information_schema.routines
WHERE routine_name IN (
    'fn_water_charge',
    'fn_validate_water_reading',
    'pr_generate_bill',
    'pr_refresh_receivables'
)
ORDER BY routine_name;
