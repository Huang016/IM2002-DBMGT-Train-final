# AI Session Context — TransitFlow

**How to use this file:**
At the start of every AI coding session, paste the full contents of this file as your first message to your AI assistant. This gives the AI the context it needs to produce code that fits your codebase and is consistent with your teammates' work.

**Who maintains this file:**
Whoever makes a schema change, seed-data change, vector/RAG change, or architectural decision updates this file in the same commit. Treat it like a team contract.

---

## Project Overview

TransitFlow is a Python-based AI chat assistant for a fictional transit operator. It queries PostgreSQL for relational data, pgvector for policy/RAG search, and Neo4j for graph route queries. The assistant uses an LLM to answer user questions through a Gradio web UI.

The student implementation focus is:

1. Design and maintain the PostgreSQL schema in `databases/relational/schema.sql`.
2. Seed relational mock data with `skeleton/seed_postgres.py`.
3. Seed policy/vector documents with `skeleton/seed_vectors.py`.
4. Implement relational query functions in `databases/relational/queries.py`.
5. Implement graph query functions in `databases/graph/queries.py`.

## Tech Stack

- Language: Python 3.11+
- Relational DB: PostgreSQL via `psycopg2` with `RealDictCursor`
- Vector DB: pgvector inside PostgreSQL
- Graph DB: Neo4j via the `neo4j` Python driver
- Web UI: Gradio
- LLM: Google Gemini or local Ollama, configured through `.env` and `skeleton/config.py`
- Seed data folder: `train-mock-data/`

## Coding Conventions

- **Naming:** use `snake_case` for Python names and SQL identifiers.
- **Docstrings:** all functions must have a docstring with `Args:` and `Returns:` sections.
- **Return types:** use type hints. Read-only functions return `list[dict]`, `Optional[dict]`, or the exact contract stated below.
- **Empty results:** return `[]` or `None`, never raise an exception for ordinary "not found" cases.
- **SQL safety:** use `%s` placeholders for all user inputs. Never string-format user input into SQL.
- **Relational pattern:** use `_connect()` helper + `psycopg2.extras.RealDictCursor`:

```python
with _connect() as conn:
    with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute("SELECT ... WHERE id = %s", (some_id,))
        return [dict(row) for row in cur.fetchall()]
```

- **Graph pattern:** use `_driver()` helper + Neo4j session:

```python
with _driver() as driver:
    with driver.session() as session:
        result = session.run("MATCH ...", station_id=station_id)
        return [dict(record) for record in result]
```

---

## Agreed Relational Schema

The current agreed schema is the full revised `schema.sql`. It uses split transaction tables, flattened national-rail seats, separate platform tables, monthly passes, loyalty points, and a pgvector-backed `policy_documents` table.

```sql
-- ============================================================
-- TransitFlow PostgreSQL Schema — full revised version
-- Changes included:
-- 1) registered_users.password -> password_hash with Argon2id format check
-- 2) Removed circular FK constraints between metro_stations and national_rail_stations
--    for interchange columns, so seed_postgres.py can load station JSON safely.
-- 3) Added DROP TABLE IF EXISTS and CREATE INDEX IF NOT EXISTS so this file can be rerun.
-- 4) Added available-seat lookup / anti-double-booking indexes for national rail bookings.
-- 5) Kept secret_answer as plain text; only password is hashed.
-- 6) Added get_available_national_rail_seats() function.
-- Seed data is loaded separately by: python skeleton/seed_postgres.py
-- ============================================================

-- ============================================================
-- 0. Reset tables for repeatable schema execution
-- ============================================================
DROP TABLE IF EXISTS metro_feedback CASCADE;
DROP TABLE IF EXISTS national_rail_feedback CASCADE;
DROP TABLE IF EXISTS metro_payments CASCADE;
DROP TABLE IF EXISTS national_rail_payments CASCADE;
DROP TABLE IF EXISTS metro_trips CASCADE;
DROP TABLE IF EXISTS metro_monthly_passes CASCADE;
DROP TABLE IF EXISTS national_rail_bookings CASCADE;
DROP TABLE IF EXISTS national_rail_seats CASCADE;
DROP TABLE IF EXISTS metro_schedules CASCADE;
DROP TABLE IF EXISTS national_rail_schedules CASCADE;
DROP TABLE IF EXISTS metro_stations CASCADE;
DROP TABLE IF EXISTS national_rail_stations CASCADE;
DROP TABLE IF EXISTS national_rail_platforms CASCADE;
DROP TABLE IF EXISTS metro_platforms CASCADE;
DROP TABLE IF EXISTS registered_users CASCADE;
DROP TABLE IF EXISTS policy_documents CASCADE;

-- ============================================================
-- 1. Independent master tables
-- ============================================================

CREATE TABLE registered_users (
    user_id          VARCHAR(10)  PRIMARY KEY,
    full_name        VARCHAR(200) NOT NULL,
    email            VARCHAR(255) NOT NULL UNIQUE,
    password_hash    VARCHAR(255) NOT NULL CHECK (password_hash LIKE '$argon2id$%'),
    phone            VARCHAR(20),
    date_of_birth    DATE NOT NULL,
    secret_question  VARCHAR(255),
    secret_answer    VARCHAR(255) ,
    registered_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    is_active        BOOLEAN NOT NULL DEFAULT TRUE,
    loyalty_points INTEGER NOT NULL DEFAULT 0 CHECK (loyalty_points >= 0)
);

-- National rail stations. Arrays / nested route-neighbour data are kept as JSONB
-- because the source JSON stores them as arrays of strings/objects.
CREATE TABLE national_rail_stations (
    station_id                         VARCHAR(10) PRIMARY KEY,
    name                               VARCHAR(200) NOT NULL,
    lines                              JSONB NOT NULL,
    is_interchange_national_rail       BOOLEAN NOT NULL DEFAULT FALSE,
    interchange_national_rail_lines    JSONB NOT NULL DEFAULT '[]'::jsonb,
    is_interchange_metro               BOOLEAN NOT NULL DEFAULT FALSE,
    -- No FK here to avoid circular seed dependency with metro_stations.
    interchange_metro_station_id       VARCHAR(10),
    adjacent_stations                  JSONB NOT NULL DEFAULT '[]'::jsonb
);

CREATE TABLE metro_stations (
    station_id                             VARCHAR(10) PRIMARY KEY,
    name                                   VARCHAR(200) NOT NULL,
    lines                                  JSONB NOT NULL,
    is_interchange_metro                   BOOLEAN NOT NULL DEFAULT FALSE,
    interchange_metro_lines                JSONB NOT NULL DEFAULT '[]'::jsonb,
    is_interchange_national_rail           BOOLEAN NOT NULL DEFAULT FALSE,
    -- No FK here to avoid circular seed dependency with national_rail_stations.
    interchange_national_rail_station_id   VARCHAR(10),
    adjacent_stations                      JSONB NOT NULL DEFAULT '[]'::jsonb
);

-- ============================================================
-- 2. Schedule and seat tables
-- ============================================================

CREATE TABLE national_rail_schedules (
    schedule_id                 VARCHAR(20) PRIMARY KEY,
    line                        VARCHAR(10) NOT NULL,
    service_type                VARCHAR(20) NOT NULL CHECK (service_type IN ('normal', 'express')),
    direction                   VARCHAR(20) NOT NULL CHECK (direction IN ('northbound', 'southbound', 'eastbound', 'westbound')),
    origin_station_id           VARCHAR(10) NOT NULL REFERENCES national_rail_stations(station_id) ON DELETE RESTRICT,
    destination_station_id      VARCHAR(10) NOT NULL REFERENCES national_rail_stations(station_id) ON DELETE RESTRICT,
    stops_in_order              JSONB NOT NULL,
    travel_time_from_origin_min JSONB NOT NULL,
    fare_classes                JSONB NOT NULL,
    first_train_time            TIME NOT NULL,
    last_train_time             TIME NOT NULL,
    frequency_min               INTEGER NOT NULL CHECK (frequency_min > 0),
    operates_on                 JSONB NOT NULL
);

CREATE TABLE metro_schedules (
    schedule_id                 VARCHAR(20) PRIMARY KEY,
    line                        VARCHAR(10) NOT NULL,
    direction                   VARCHAR(20) NOT NULL CHECK (direction IN ('northbound', 'southbound', 'eastbound', 'westbound')),
    origin_station_id           VARCHAR(10) NOT NULL REFERENCES metro_stations(station_id) ON DELETE RESTRICT,
    destination_station_id      VARCHAR(10) NOT NULL REFERENCES metro_stations(station_id) ON DELETE RESTRICT,
    stops_in_order              JSONB NOT NULL,
    travel_time_from_origin_min JSONB NOT NULL,
    base_fare_usd               NUMERIC(10,2) NOT NULL CHECK (base_fare_usd >= 0),
    per_stop_rate_usd           NUMERIC(10,2) NOT NULL CHECK (per_stop_rate_usd >= 0),
    first_train_time            TIME NOT NULL,
    last_train_time             TIME NOT NULL,
    frequency_min               INTEGER NOT NULL CHECK (frequency_min > 0),
    operates_on                 JSONB NOT NULL
);

-- The seat-layout JSON is nested, but tutorial recommends flattening seats for easy querying.
CREATE TABLE national_rail_seats (
    schedule_id   VARCHAR(20) NOT NULL REFERENCES national_rail_schedules(schedule_id) ON DELETE CASCADE,
    seat_id       VARCHAR(10) NOT NULL,
    coach         VARCHAR(5) NOT NULL,
    fare_class    VARCHAR(20) NOT NULL CHECK (fare_class IN ('first', 'standard')),
    seat_row      INTEGER NOT NULL CHECK (seat_row > 0),
    seat_column   VARCHAR(5) NOT NULL,
    PRIMARY KEY (schedule_id, seat_id)
);
-- ============================================================
-- 3. platform
-- ============================================================
CREATE TABLE national_rail_platforms (
    platform_id VARCHAR(40) PRIMARY KEY,

    schedule_id VARCHAR(20) NOT NULL
        REFERENCES national_rail_schedules(schedule_id)
        ON DELETE CASCADE,

    station_id VARCHAR(10) NOT NULL
        REFERENCES national_rail_stations(station_id)
        ON DELETE RESTRICT,

    direction VARCHAR(20) NOT NULL
        CHECK (direction IN ('northbound', 'southbound', 'eastbound', 'westbound')),

    platform_number INTEGER NOT NULL
        CHECK (platform_number BETWEEN 1 AND 4),

    UNIQUE (schedule_id, station_id)
);

CREATE TABLE metro_platforms (
    platform_id VARCHAR(40) PRIMARY KEY,

    schedule_id VARCHAR(20) NOT NULL
        REFERENCES metro_schedules(schedule_id)
        ON DELETE CASCADE,

    station_id VARCHAR(10) NOT NULL
        REFERENCES metro_stations(station_id)
        ON DELETE RESTRICT,

    direction VARCHAR(20) NOT NULL
        CHECK (direction IN ('northbound', 'southbound', 'eastbound', 'westbound')),

    platform_number INTEGER NOT NULL
        CHECK (platform_number BETWEEN 1 AND 4),

    UNIQUE (schedule_id, station_id)
);
-- ============================================================
-- 4. Transaction tables
-- ============================================================

CREATE TABLE national_rail_bookings (
    booking_id              VARCHAR(20) PRIMARY KEY,
    user_id                 VARCHAR(10) NOT NULL REFERENCES registered_users(user_id) ON DELETE RESTRICT,
    schedule_id             VARCHAR(20) NOT NULL REFERENCES national_rail_schedules(schedule_id) ON DELETE RESTRICT,
    origin_station_id       VARCHAR(10) NOT NULL REFERENCES national_rail_stations(station_id) ON DELETE RESTRICT,
    destination_station_id  VARCHAR(10) NOT NULL REFERENCES national_rail_stations(station_id) ON DELETE RESTRICT,
    travel_date             DATE NOT NULL,
    departure_time          TIME NOT NULL,
    ticket_type             VARCHAR(20) NOT NULL CHECK (ticket_type IN ('single', 'return')),
    fare_class              VARCHAR(20) NOT NULL CHECK (fare_class IN ('first', 'standard')),
    coach                   VARCHAR(5) NOT NULL,
    seat_id                 VARCHAR(10) NOT NULL,
    stops_travelled         INTEGER NOT NULL CHECK (stops_travelled >= 0),
    amount_usd              NUMERIC(10,2) NOT NULL CHECK (amount_usd >= 0),
    status                  VARCHAR(20) NOT NULL CHECK (status IN ('confirmed', 'completed', 'cancelled')),
    booked_at               TIMESTAMPTZ NOT NULL,
    travelled_at            TIMESTAMPTZ,
    FOREIGN KEY (schedule_id, seat_id)
        REFERENCES national_rail_seats(schedule_id, seat_id)
        ON DELETE RESTRICT
);
CREATE TABLE metro_monthly_passes (
    pass_id          VARCHAR(20) PRIMARY KEY,
    user_id          VARCHAR(10) NOT NULL REFERENCES registered_users(user_id) ON DELETE RESTRICT,
    valid_from       DATE NOT NULL,
    valid_until      DATE NOT NULL,
    price_usd        NUMERIC(10,2) NOT NULL CHECK (price_usd >= 0),
    purchased_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE TABLE metro_trips (
    trip_id                 VARCHAR(20) PRIMARY KEY,
    user_id                 VARCHAR(10) NOT NULL REFERENCES registered_users(user_id) ON DELETE RESTRICT,
    schedule_id             VARCHAR(20) NOT NULL REFERENCES metro_schedules(schedule_id) ON DELETE RESTRICT,
    origin_station_id       VARCHAR(10) NOT NULL REFERENCES metro_stations(station_id) ON DELETE RESTRICT,
    destination_station_id  VARCHAR(10) NOT NULL REFERENCES metro_stations(station_id) ON DELETE RESTRICT,
    travel_date             DATE NOT NULL,
    -- 允許使用 monthly_pass 作為票種
    ticket_type             VARCHAR(20) NOT NULL CHECK (ticket_type IN ('single', 'day_pass', 'monthly_pass')),
    day_pass_ref            VARCHAR(20) REFERENCES metro_trips(trip_id) ON DELETE SET NULL,
    -- 如果這趟旅程是用月票搭的，就指向該張月票
    monthly_pass_ref        VARCHAR(20) REFERENCES metro_monthly_passes(pass_id) ON DELETE SET NULL,
    stops_travelled         INTEGER CHECK (stops_travelled IS NULL OR stops_travelled >= 0),
    amount_usd              NUMERIC(10,2) NOT NULL CHECK (amount_usd >= 0),
    status                  VARCHAR(20) NOT NULL CHECK (status IN ('completed', 'cancelled')),
    purchased_at            TIMESTAMPTZ,
    travelled_at            TIMESTAMPTZ
);

-- ============================================================
-- 5. Split payment and feedback tables, matching the ERD
-- ============================================================
-- The original payments / feedback JSON uses a field named "booking_id" for both
-- national rail bookings (BKxxx) and metro trips (MTxxx).
-- To match the ERD, seed_postgres.py should route rows by prefix:
--   BKxxx -> national_rail_payments / national_rail_feedback.booking_id
--   MTxxx -> metro_payments / metro_feedback.trip_id

CREATE TABLE national_rail_payments (
    payment_id       VARCHAR(15) PRIMARY KEY,
    booking_id       VARCHAR(20) NOT NULL REFERENCES national_rail_bookings(booking_id) ON DELETE RESTRICT,
    amount_usd       NUMERIC(10,2) NOT NULL CHECK (amount_usd >= 0),
    method           VARCHAR(50) NOT NULL CHECK (method IN ('credit_card', 'debit_card', 'ewallet')),
    status           VARCHAR(20) NOT NULL CHECK (status IN ('paid', 'refunded')),
    paid_at          TIMESTAMPTZ NOT NULL
);

CREATE TABLE metro_payments (
    payment_id       VARCHAR(15) PRIMARY KEY,
    trip_id          VARCHAR(20) NOT NULL REFERENCES metro_trips(trip_id) ON DELETE RESTRICT,
    amount_usd       NUMERIC(10,2) NOT NULL CHECK (amount_usd >= 0),
    method           VARCHAR(50) NOT NULL CHECK (method IN ('credit_card', 'debit_card', 'ewallet')),
    status           VARCHAR(20) NOT NULL CHECK (status IN ('paid', 'refunded')),
    paid_at          TIMESTAMPTZ NOT NULL
);

CREATE TABLE national_rail_feedback (
    feedback_id      VARCHAR(15) PRIMARY KEY,
    booking_id       VARCHAR(20) NOT NULL REFERENCES national_rail_bookings(booking_id) ON DELETE RESTRICT,
    user_id          VARCHAR(10) NOT NULL REFERENCES registered_users(user_id) ON DELETE RESTRICT,
    rating           INTEGER NOT NULL CHECK (rating BETWEEN 1 AND 5),
    comment          TEXT,
    submitted_at     TIMESTAMPTZ NOT NULL
);

CREATE TABLE metro_feedback (
    feedback_id      VARCHAR(15) PRIMARY KEY,
    trip_id          VARCHAR(20) NOT NULL REFERENCES metro_trips(trip_id) ON DELETE RESTRICT,
    user_id          VARCHAR(10) NOT NULL REFERENCES registered_users(user_id) ON DELETE RESTRICT,
    rating           INTEGER NOT NULL CHECK (rating BETWEEN 1 AND 5),
    comment          TEXT,
    submitted_at     TIMESTAMPTZ NOT NULL
);

-- ============================================================
-- 6. Indexes
-- ============================================================

CREATE INDEX IF NOT EXISTS idx_national_rail_stations_lines_gin ON national_rail_stations USING GIN (lines);
CREATE INDEX IF NOT EXISTS idx_metro_stations_lines_gin ON metro_stations USING GIN (lines);
CREATE INDEX IF NOT EXISTS idx_national_rail_schedules_operates_on_gin ON national_rail_schedules USING GIN (operates_on);
CREATE INDEX IF NOT EXISTS idx_metro_schedules_operates_on_gin ON metro_schedules USING GIN (operates_on);

CREATE INDEX IF NOT EXISTS idx_national_rail_schedules_origin ON national_rail_schedules(origin_station_id);
CREATE INDEX IF NOT EXISTS idx_national_rail_schedules_destination ON national_rail_schedules(destination_station_id);
CREATE INDEX IF NOT EXISTS idx_metro_schedules_origin ON metro_schedules(origin_station_id);
CREATE INDEX IF NOT EXISTS idx_metro_schedules_destination ON metro_schedules(destination_station_id);

CREATE INDEX IF NOT EXISTS idx_national_rail_bookings_user_id ON national_rail_bookings(user_id);
CREATE INDEX IF NOT EXISTS idx_national_rail_bookings_schedule_id ON national_rail_bookings(schedule_id);
CREATE INDEX IF NOT EXISTS idx_national_rail_bookings_travel_date ON national_rail_bookings(travel_date);
CREATE INDEX IF NOT EXISTS idx_nrb_origin ON national_rail_bookings(origin_station_id);
CREATE INDEX IF NOT EXISTS idx_nrb_dest ON national_rail_bookings(destination_station_id);
CREATE INDEX IF NOT EXISTS idx_mt_origin ON metro_trips(origin_station_id);
CREATE INDEX IF NOT EXISTS idx_mt_dest ON metro_trips(destination_station_id);
-- Available-seat lookup index:
-- Used by queries that find seats in national_rail_seats that are NOT occupied
-- by confirmed / completed bookings for the same schedule + date + departure time.
CREATE INDEX IF NOT EXISTS idx_national_rail_bookings_available_seats
ON national_rail_bookings (schedule_id, travel_date, departure_time, seat_id)
WHERE status IN ('confirmed', 'completed');

-- Prevent double-booking the same seat on the same scheduled departure.
-- Cancelled bookings are excluded, so a cancelled seat can be sold again.
CREATE UNIQUE INDEX IF NOT EXISTS uq_national_rail_active_seat_booking
ON national_rail_bookings (schedule_id, travel_date, departure_time, seat_id)
WHERE status IN ('confirmed', 'completed');

-- Helps seat-filtering screens such as first/standard class or coach filters.
CREATE INDEX IF NOT EXISTS idx_national_rail_seats_schedule_class_coach
ON national_rail_seats (schedule_id, fare_class, coach);

CREATE INDEX IF NOT EXISTS idx_metro_trips_user_id ON metro_trips(user_id);
CREATE INDEX IF NOT EXISTS idx_metro_trips_schedule_id ON metro_trips(schedule_id);
CREATE INDEX IF NOT EXISTS idx_metro_trips_travel_date ON metro_trips(travel_date);

CREATE INDEX IF NOT EXISTS idx_national_rail_payments_booking_id ON national_rail_payments(booking_id);
CREATE INDEX IF NOT EXISTS idx_metro_payments_trip_id ON metro_payments(trip_id);
CREATE INDEX IF NOT EXISTS idx_national_rail_feedback_booking_id ON national_rail_feedback(booking_id);
CREATE INDEX IF NOT EXISTS idx_national_rail_feedback_user_id ON national_rail_feedback(user_id);
CREATE INDEX IF NOT EXISTS idx_metro_feedback_trip_id ON metro_feedback(trip_id);
CREATE INDEX IF NOT EXISTS idx_metro_feedback_user_id ON metro_feedback(user_id);
CREATE INDEX IF NOT EXISTS idx_metro_monthly_passes_user ON metro_monthly_passes(user_id);

--Helps platform lookup  that show which platforms serve a given station/line/direction.
CREATE INDEX IF NOT EXISTS idx_national_rail_platforms_schedule_station
ON national_rail_platforms(schedule_id, station_id);
CREATE INDEX IF NOT EXISTS idx_metro_platforms_schedule_station
ON metro_platforms(schedule_id, station_id);
-- ============================================================
-- 7. Available seats function
-- ============================================================
-- Calculates available seats dynamically from:
--   national_rail_seats - confirmed/completed national_rail_bookings
-- Usage example:
-- SELECT *
-- FROM get_available_national_rail_seats('NR_SCH01', DATE '2026-04-02', TIME '07:00');

CREATE OR REPLACE FUNCTION get_available_national_rail_seats(
    p_schedule_id VARCHAR,
    p_travel_date DATE,
    p_departure_time TIME
)
RETURNS TABLE (
    schedule_id VARCHAR,
    seat_id VARCHAR,
    coach VARCHAR,
    fare_class VARCHAR,
    seat_row INTEGER,
    seat_column VARCHAR
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        s.schedule_id,
        s.seat_id,
        s.coach,
        s.fare_class,
        s.seat_row,
        s.seat_column
    FROM national_rail_seats s
    WHERE s.schedule_id = p_schedule_id
      AND NOT EXISTS (
          SELECT 1
          FROM national_rail_bookings b
          WHERE b.schedule_id = s.schedule_id
            AND b.travel_date = p_travel_date
            AND b.departure_time = p_departure_time
            AND b.seat_id = s.seat_id
            AND b.status IN ('confirmed', 'completed')
      )
    ORDER BY s.coach, s.seat_row, s.seat_column;
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- 8. VECTOR SCHEMA  (RAG / Help Desk)do not modify
-- ============================================================

CREATE EXTENSION IF NOT EXISTS vector;

CREATE TABLE policy_documents (
    id          SERIAL       PRIMARY KEY,
    title       VARCHAR(200) NOT NULL,
    category    VARCHAR(50)  NOT NULL,  -- 'refund', 'booking', 'conduct'
    content     TEXT         NOT NULL,
    embedding   vector(768),
    source_file VARCHAR(200),
    created_at  TIMESTAMPTZ  DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS policy_documents_embedding_hnsw_idx
ON policy_documents USING hnsw (embedding vector_cosine_ops);
```

---

## PostgreSQL Seed Design (`skeleton/seed_postgres.py`)

`seed_postgres.py` loads mock JSON data from `train-mock-data/` and inserts it into the revised split schema. It is safe to re-run because all insert helpers use `ON CONFLICT DO NOTHING`.

Run order:

1. Start Docker services.
2. Apply schema:
   ```bash
   psql ... -f databases/relational/schema.sql
   ```
3. Seed PostgreSQL:
   ```bash
   python skeleton/seed_postgres.py
   ```

Important seed behavior:

- Uses `skeleton/config.py` for PostgreSQL connection settings.
- Loads station JSON first, then schedules, platforms, seats, users, transactions, payments, feedback, and loyalty points.
- `registered_users.password_hash` is generated from the JSON `password` field.
- The schema currently keeps `secret_answer` as plain text. It is **not** named `secret_answer_hash` in the current SQL.
- `national_rail_seat_layouts.json` is flattened into `national_rail_seats`.
- `bookings.json` is inserted into `national_rail_bookings`.
- `metro_travel_history.json` is inserted into `metro_trips`.
- `payments.json` is split by transaction id prefix:
  - `BK...` → `national_rail_payments.booking_id`
  - `MT...` → `metro_payments.trip_id`
- `feedback.json` is split by transaction id prefix:
  - `BK...` → `national_rail_feedback.booking_id`
  - `MT...` → `metro_feedback.trip_id`
- Platform assignment is generated from schedule direction:
  - `northbound` → platform `1`
  - `southbound` → platform `2`
  - `eastbound` → platform `3`
  - `westbound` → platform `4`
- Platform tables are generated from each schedule's `stops_in_order`:
  - `national_rail_platforms`
  - `metro_platforms`
- Current loyalty-point update counts only paid national-rail bookings:
  - joins `national_rail_bookings` + `national_rail_payments`
  - requires booking status `confirmed` or `completed`
  - requires payment status `paid`
  - points formula: `FLOOR(amount_usd * 10)`

Known seed/schema alignment notes:

- `metro_monthly_passes` exists in schema, but the current seed file does not load a monthly-pass JSON file.
- `metro_trips.monthly_pass_ref` exists in schema, but the current `seed_metro_trips()` insert column list does not include it.
- If monthly passes are required in the final demo, add a seeder for `metro_monthly_passes` and include `monthly_pass_ref` in `seed_metro_trips()`.
- If metro trips should also add loyalty points, extend `update_loyalty_points()` to include `metro_trips` + `metro_payments` where trip status is `completed` and payment status is `paid`.

---

## Vector / RAG Seed Design (`skeleton/seed_vectors.py`)

`seed_vectors.py` loads policy documents directly from `train-mock-data/`, embeds them with the configured LLM provider, and stores them in the PostgreSQL `policy_documents` table.

Run after Docker and schema setup:

```bash
python skeleton/seed_vectors.py
```

Policy source mapping:

- `refund_policy.json`
  - one vector document per refund policy entry
  - category: `refund`
- `ticket_types.json`
  - one vector document per ticket type
  - category: `booking`
- `booking_rules.json`
  - one vector document per section:
    - `national_rail`
    - `metro`
    - `general_rules`
  - category: `booking`
- `travel_policies.json`
  - one vector document per section:
    - `metro`
    - `national_rail`
  - category: `conduct`

Embedding behavior:

- Uses `skeleton.llm_provider.llm`.
- Calls `llm.embed(doc["content"])` for each document.
- Validates embedding length against `llm.embed_dim`.
- Stores documents through `store_policy_document(...)` from `databases/relational/queries.py`.
- If Gemini is used, it sleeps briefly between calls to avoid rate-limit issues.

Relational query functions must therefore include a compatible `store_policy_document(...)` helper and vector search helper, such as `query_policy_vector_search(...)`, if the UI needs RAG policy answers.

---

## Agreed Graph Schema

Node labels:

- `Station`: unified station node for both Metro and National Rail.
  - Use property `network` to distinguish systems: `metro` or `rail`.
  - This allows graph queries such as `query_delay_ripple` to calculate N-hop effects across both systems.

Relationship types:

- `CONNECTS_TO`: operational connection between adjacent stations on the same line.
- `INTERCHANGE_TO`: physical transfer connection between a Metro station and a National Rail station.

Key properties:

- `Station` properties:
  - `station_id` — unique station id, for example `MS01` or `NR01`
  - `name` — station name
  - `network` — `metro` or `rail`
  - `lines` — list of lines serving the station, for example `["M1", "M2"]`
- `CONNECTS_TO` properties:
  - `line` — route/line name, for example `M1` or `NR1`
  - `service_type` — `normal` or `express`; Metro can use `metro` or `normal` depending on graph seeding convention
  - `travel_time_min` — edge weight for shortest-time route queries
  - `fare_standard` — edge weight for cheapest-route standard fare
  - `fare_first` — first-class fare weight for National Rail edges; Metro can omit this or set it equal to standard fare
- `INTERCHANGE_TO` properties:
  - `travel_time_min` — walking/transfer time, default `0` if not modeled
  - `fare` — transfer cost, default `0.0`

Graph implementation notes:

- Use one unified `Station` label rather than separate `MetroStation` and `RailStation` labels.
- Use `station_id` as the unique lookup key.
- When creating paths, avoid using an undefined Cypher variable named `station`; use the actual bound variable name, such as `s`, `origin`, `destination`, or `n`.
- Build `CONNECTS_TO` relationships from adjacent station order or schedule stop order.
- Build `INTERCHANGE_TO` relationships from the interchange station id fields in station JSON/schema.

---

## Function Signatures We Are Implementing

These are fixed contracts. AI-generated code must match these signatures exactly unless the team intentionally changes the UI contract.

### Relational (`databases/relational/queries.py`)

```python
# Read-only
def query_national_rail_availability(origin_id: str, destination_id: str, travel_date: Optional[str] = None) -> list[dict]: ...
def query_national_rail_fare(schedule_id: str, fare_class: str, stops_travelled: int) -> Optional[dict]: ...
def query_metro_schedules(origin_id: str, destination_id: str) -> list[dict]: ...
def query_metro_fare(schedule_id: str, stops_travelled: int) -> Optional[dict]: ...
def query_available_seats(schedule_id: str, travel_date: str, fare_class: str) -> list[dict]: ...
def query_user_profile(user_email: str) -> Optional[dict]: ...
def query_user_bookings(user_email: str) -> dict: ...  # returns {"national_rail": [...], "metro": [...]}
def query_payment_info(booking_id: str) -> Optional[dict]: ...
def query_policy_vector_search(query_embedding: list[float], limit: int = 5) -> list[dict]: ...
def store_policy_document(title: str, category: str, content: str, embedding: list[float], source_file: str = "") -> int: ...

# Write operations
def execute_booking(user_id, schedule_id, origin_station_id, destination_station_id, travel_date, fare_class, seat_id, ticket_type="single") -> tuple[bool, dict | str]: ...
def execute_cancellation(booking_id: str, user_id: str) -> tuple[bool, dict | str]: ...

# Auth
def register_user(email, first_name, surname, year_of_birth, password, secret_question, secret_answer) -> tuple[bool, str]: ...
def login_user(email: str, password: str) -> Optional[dict]: ...
def get_user_secret_question(email: str) -> Optional[str]: ...
def verify_secret_answer(email: str, answer: str) -> bool: ...
def update_password(email: str, new_password: str) -> bool: ...
```

Relational implementation notes:

- Use current table names:
  - `national_rail_bookings`, not `bookings`
  - `national_rail_payments`, not `rail_payments`
  - `national_rail_feedback`, not `rail_feedback`
  - `metro_trips`, not `metro_travel_history`
- For `query_user_bookings`, join user email through `registered_users`, then return both:
  - national rail rows from `national_rail_bookings`
  - metro rows from `metro_trips`
- For `query_payment_info`, route by prefix:
  - `BK...` should query `national_rail_payments`
  - `MT...` should query `metro_payments`
- For seat availability, the SQL function `get_available_national_rail_seats(schedule_id, travel_date, departure_time)` requires `departure_time`. If the Python function only receives `schedule_id`, `travel_date`, and `fare_class`, the implementation must either:
  - derive the departure time from the selected schedule/booking flow, or
  - update the function contract to include `departure_time`.
- For password functions, generate and verify Argon2id-compatible hashes for `password_hash`.
- The current schema stores `secret_answer` as plain text. If the team wants secret answers hashed, update both schema and seeder together.
- When a successful paid booking is created, loyalty points should be updated consistently with the team rule.

### Graph (`databases/graph/queries.py`)

```python
def query_shortest_route(origin_id: str, destination_id: str, network: str = "auto") -> dict: ...
def query_cheapest_route(origin_id: str, destination_id: str, network: str = "auto", fare_class: str = "standard") -> dict: ...
def query_alternative_routes(origin_id, destination_id, avoid_station_id, network="auto", max_routes=3) -> list[list[dict]]: ...
def query_interchange_path(origin_id: str, destination_id: str) -> dict: ...
def query_delay_ripple(delayed_station_id: str, hops: int = 2) -> list[dict]: ...
def query_station_connections(station_id: str) -> list[dict]: ...
```

---

## Team Decisions Log

- [x] Relational schema uses split transaction tables instead of polymorphic references.
  - Why: payments and feedback JSON use one `booking_id` field for both rail and metro, but the database keeps separate FK-safe tables.
- [x] National Rail bookings use `national_rail_bookings`; Metro travel records use `metro_trips`.
  - Why: this matches the current schema and `seed_postgres.py`.
- [x] Payments are split into `national_rail_payments` and `metro_payments` by id prefix.
  - Why: `BK...` means National Rail booking; `MT...` means Metro trip.
- [x] Feedback is split into `national_rail_feedback` and `metro_feedback` by id prefix.
  - Why: keeps foreign keys clear and avoids nullable polymorphic reference columns.
- [x] National Rail seats are flattened into `national_rail_seats`.
  - Why: easier to query available seats and prevent double-booking than nested JSON layout.
- [x] Seat double-booking is prevented with a partial unique index on active National Rail bookings.
  - Why: cancelled seats should become available again, but confirmed/completed seats should not be sold twice.
- [x] Station `lines`, `adjacent_stations`, and schedule stop data are stored as JSONB.
  - Why: the source JSON stores arrays and nested route-neighbour data directly.
- [x] Interchange station columns do not use circular FK constraints.
  - Why: this avoids seeding dependency problems between `metro_stations` and `national_rail_stations`.
- [x] Platform tables are generated from schedule direction and stops.
  - Why: the assignment requires knowing which platform each service departs from.
- [x] Platform number rule is direction-based.
  - Why: deterministic and easy to explain: northbound 1, southbound 2, eastbound 3, westbound 4.
- [x] `registered_users.password_hash` must use an Argon2id-format hash.
  - Why: passwords should not be stored in plain text, and schema enforces `$argon2id$%`.
- [x] `secret_answer` is currently plain text in schema.
  - Why: this is what the current schema and seeder use. Change schema + seed together if hashing is required.
- [x] Loyalty points are stored on `registered_users.loyalty_points`.
  - Why: user profile is the simplest place to keep accumulated points.
- [x] Current seed updates loyalty points from paid National Rail transactions only.
  - Why: this is what current `update_loyalty_points()` implements. Extend it for Metro if required.
- [x] Policy and rule knowledge is stored in `policy_documents` with pgvector.
  - Why: refund rules, ticket types, booking rules, and travel policies are better answered through RAG/vector search.
- [x] Graph uses unified `Station` nodes with `CONNECTS_TO` and `INTERCHANGE_TO` relationships.
  - Why: shortest route, cheapest route, interchange, and delay ripple queries can work across both networks.

---

## Prompts That Worked

### Schema / AI session update prompt

```text
Please update AI Session Context to match these files exactly: schema.sql, seed_postgres.py, and seed_vectors.py. Remove old table names, keep the fixed query function contracts, and add notes where the seed file and schema currently differ.
```

### Query implementation prompt

```text
Implement databases/relational/queries.py using the current schema table names: national_rail_bookings, metro_trips, national_rail_payments, metro_payments, national_rail_feedback, metro_feedback, national_rail_seats, national_rail_platforms, metro_platforms, and policy_documents. Use RealDictCursor, %s placeholders, return [] or None for not found, and match the fixed function signatures in AI Session Context.
```

### Graph implementation prompt

```text
Implement databases/graph/queries.py using unified Station nodes and CONNECTS_TO / INTERCHANGE_TO relationships. Do not reference undefined Cypher variables such as station. Use station_id as the lookup key and support network="auto".
```
