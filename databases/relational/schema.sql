-- ============================================================
--  TransitFlow PostgreSQL Schema
--  Seed data is loaded separately by: python skeleton/seed_postgres.py
--
--  TWO ROLES:
--     1. Relational  → dual-network transit data you design below
--     2. Vector      → policy documents for RAG (provided — do not modify)
-- ============================================================

-- ============================================================
--  STUDENT TASK — Design and create your relational tables here
-- ============================================================

-- =========================================================================
-- 1. 獨立主表 (無任何外鍵，必須最先建立)
-- =========================================================================

-- 使用者帳號表
CREATE TABLE users (
    user_id VARCHAR(10) PRIMARY KEY,
    full_name VARCHAR(100) NOT NULL,
    email VARCHAR(100) UNIQUE NOT NULL,
    password VARCHAR(255) NOT NULL, -- 註：業界實務密碼長度給寬一點以利未來雜湊加密
    phone VARCHAR(20),
    date_of_birth DATE,
    secret_question TEXT,
    secret_answer TEXT,
    registered_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    is_active BOOLEAN DEFAULT TRUE
);

-- 國家鐵路車站表
CREATE TABLE national_rail_stations (
    station_id VARCHAR(10) PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    lines VARCHAR(10)[], -- PostgreSQL 的字串陣列，用來存 JSON 中的 ["NR1", "NR2"]
    is_interchange_national_rail BOOLEAN DEFAULT FALSE,
    interchange_national_rail_lines VARCHAR(10)[],
    is_interchange_metro BOOLEAN DEFAULT FALSE,
    interchange_metro_station_id VARCHAR(10)
);

-- 城市地鐵車站表
CREATE TABLE metro_stations (
    station_id VARCHAR(10) PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    lines VARCHAR(10)[],
    is_interchange_metro BOOLEAN DEFAULT FALSE,
    interchange_metro_lines VARCHAR(10)[],
    is_interchange_national_rail BOOLEAN DEFAULT FALSE,
    interchange_national_rail_station_id VARCHAR(10)
);

-- =========================================================================
-- 2. 第二層表 (依賴上述車站主表)
-- =========================================================================

-- 國家鐵路時刻表
CREATE TABLE national_rail_schedules (
    schedule_id VARCHAR(20) PRIMARY KEY,
    line VARCHAR(10) NOT NULL,
    service_type VARCHAR(20) NOT NULL, -- normal, express
    direction VARCHAR(20) NOT NULL,
    origin_station_id VARCHAR(10) REFERENCES national_rail_stations(station_id),
    destination_station_id VARCHAR(10) REFERENCES national_rail_stations(station_id),
    stops_in_order VARCHAR(10)[],
    passed_through_stations VARCHAR(10)[],
    first_train_time VARCHAR(5),
    last_train_time VARCHAR(5),
    travel_time_from_origin_min JSONB, -- 使用 JSONB 儲存深層嵌套的 JSON 物件
    fare_classes JSONB,                -- 儲存 standard 與 first 的費率明細
    frequency_min INT,
    operates_on VARCHAR(5)[]           -- 存 ["mon", "tue", ...]
);

-- 城市地鐵時刻表
CREATE TABLE metro_schedules (
    schedule_id VARCHAR(20) PRIMARY KEY,
    line VARCHAR(10) NOT NULL,
    direction VARCHAR(20) NOT NULL,
    origin_station_id VARCHAR(10) REFERENCES metro_stations(station_id),
    destination_station_id VARCHAR(10) REFERENCES metro_stations(station_id),
    stops_in_order VARCHAR(10)[],
    first_train_time VARCHAR(5),
    last_train_time VARCHAR(5),
    travel_time_from_origin_min JSONB,
    base_fare_usd NUMERIC(5, 2),       -- 精準處理金額，採用 NUMERIC 型態
    per_stop_rate_usd NUMERIC(5, 2),
    frequency_min INT,
    operates_on VARCHAR(5)[]
);

-- 國家鐵路座位模板表
CREATE TABLE national_rail_seat_layouts (
    layout_id VARCHAR(10) PRIMARY KEY,
    schedule_id VARCHAR(20) REFERENCES national_rail_schedules(schedule_id),
    coaches JSONB NOT NULL -- 內含車廂及詳細座位清單的 JSON 數組
);

-- =========================================================================
-- 3. 交易交易紀錄表 (核心橋樑表，依賴使用者、班次與車站)
-- =========================================================================

-- 國家鐵路訂票紀錄表
CREATE TABLE bookings (
    booking_id VARCHAR(20) PRIMARY KEY,
    user_id VARCHAR(10) REFERENCES users(user_id),
    schedule_id VARCHAR(20) REFERENCES national_rail_schedules(schedule_id),
    origin_station_id VARCHAR(10) REFERENCES national_rail_stations(station_id),
    destination_station_id VARCHAR(10) REFERENCES national_rail_stations(station_id),
    travel_date DATE NOT NULL,
    departure_time VARCHAR(5),
    ticket_type VARCHAR(20), -- single, return
    fare_class VARCHAR(20),  -- standard, first
    coach VARCHAR(5),
    seat_id VARCHAR(10),
    stops_travelled INT,
    amount_usd NUMERIC(10, 2) NOT NULL,
    status VARCHAR(20) NOT NULL, -- completed, cancelled, confirmed
    booked_at TIMESTAMPTZ,
    travelled_at TIMESTAMPTZ
);

-- 城市地鐵搭乘歷史紀錄表
CREATE TABLE metro_travel_history (
    trip_id VARCHAR(20) PRIMARY KEY,
    user_id VARCHAR(10) REFERENCES users(user_id),
    schedule_id VARCHAR(20) REFERENCES metro_schedules(schedule_id),
    origin_station_id VARCHAR(10) REFERENCES metro_stations(station_id),
    destination_station_id VARCHAR(10) REFERENCES metro_stations(station_id),
    travel_date DATE NOT NULL,
    ticket_type VARCHAR(20), -- single, day_pass
    day_pass_ref VARCHAR(20), -- 指向同張 day_pass 的首次扣款 trip_id
    stops_travelled INT,
    amount_usd NUMERIC(10, 2) NOT NULL,
    status VARCHAR(20) NOT NULL,
    purchased_at TIMESTAMPTZ,
    travelled_at TIMESTAMPTZ
);

-- =========================================================================
-- 4. 付款與回饋表 (最後建立，因其依賴上述所有的交易單據)
-- =========================================================================

-- 統一付款紀錄表
CREATE TABLE payments (
    payment_id VARCHAR(10) PRIMARY KEY,
    booking_id VARCHAR(20) NOT NULL, -- 由於地鐵和國鐵共用此表，此欄位動態填入 BKxxx 或 MTxxx
    amount_usd NUMERIC(10, 2) NOT NULL,
    method VARCHAR(50) NOT NULL,    -- credit_card, ewallet, debit_card
    status VARCHAR(20) NOT NULL,    -- paid, refunded
    paid_at TIMESTAMPTZ NOT NULL
);

-- 乘客回饋評價表
CREATE TABLE feedback (
    feedback_id VARCHAR(10) PRIMARY KEY,
    booking_id VARCHAR(20) NOT NULL, -- 動態填入 BKxxx 或 MTxxx
    user_id VARCHAR(10) REFERENCES users(user_id),
    rating INT CHECK (rating >= 1 AND rating <= 5), -- 限制星星評分必須在 1 ~ 5 之間
    comment TEXT,
    submitted_at TIMESTAMPTZ NOT NULL
);




-- ============================================================
--  VECTOR SCHEMA  (RAG / Help Desk) — do not modify
-- ============================================================

CREATE EXTENSION IF NOT EXISTS vector;

CREATE TABLE IF NOT EXISTS policy_documents (
    id          SERIAL       PRIMARY KEY,
    title       VARCHAR(200) NOT NULL,
    category    VARCHAR(50)  NOT NULL,  -- 'refund', 'booking', 'conduct'
    content     TEXT         NOT NULL,
    -- 768-dim  → Ollama nomic-embed-text (default)
    -- 3072-dim → Gemini gemini-embedding-001
    -- If you switch LLM_PROVIDER to gemini, change to vector(3072) and reset the database.
    embedding   vector(768),
    source_file VARCHAR(200),
    created_at  TIMESTAMPTZ  DEFAULT NOW()
);

-- Index for fast cosine similarity search
CREATE INDEX IF NOT EXISTS ON policy_documents USING hnsw (embedding vector_cosine_ops);
