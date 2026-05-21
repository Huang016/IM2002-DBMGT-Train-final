```mermaid
erDiagram
    %% ==========================================
    %% 1. 實體關係定義 (Relationships)
    %% ==========================================
    
    %% 基礎建設網絡關聯
    NATIONAL_RAIL_STATIONS ||--o{ NATIONAL_RAIL_SCHEDULES : "starts at"
    NATIONAL_RAIL_SCHEDULES ||--|| NATIONAL_RAIL_SEAT_LAYOUTS : "defines template for"
    METRO_STATIONS ||--o{ METRO_SCHEDULES : "starts at"

    %% 使用者與交易核心關聯
    REGISTERED_USERS ||--o{ BOOKINGS : "places"
    REGISTERED_USERS ||--o{ METRO_TRAVEL_HISTORY : "travels on"
    
    %% 訂單/行程與基礎建設的連結
    NATIONAL_RAIL_SCHEDULES ||--o{ BOOKINGS : "scheduled via"
    NATIONAL_RAIL_STATIONS ||--o{ BOOKINGS : "departs from"
    NATIONAL_RAIL_STATIONS ||--o{ BOOKINGS : "arrives at"
    METRO_SCHEDULES ||--o{ METRO_TRAVEL_HISTORY : "scheduled via"
    METRO_STATIONS ||--o{ METRO_TRAVEL_HISTORY : "enters from"
    METRO_STATIONS ||--o{ METRO_TRAVEL_HISTORY : "exits to"

    %% 付款與回饋
    BOOKINGS ||--|| PAYMENTS : "has"
    METRO_TRAVEL_HISTORY ||--|| PAYMENTS : "has"
    BOOKINGS ||--o| FEEDBACK : "receives"
    METRO_TRAVEL_HISTORY ||--o| FEEDBACK : "receives"
    REGISTERED_USERS ||--o{ FEEDBACK : "writes"

    %% ==========================================
    %% 2. 實體欄位定義 (Entities)
    %% ==========================================

    REGISTERED_USERS {
        string user_id PK
        string full_name
        string email
        string password
        string phone
        date date_of_birth
        string secret_question
        string secret_answer
        timestamp registered_at
        boolean is_active
    }

    NATIONAL_RAIL_STATIONS {
        string station_id PK
        string name
        string_array lines
        boolean is_interchange_national_rail
        string_array interchange_national_rail_lines
        boolean is_interchange_metro
        string interchange_metro_station_id
    }

    METRO_STATIONS {
        string station_id PK
        string name
        string_array lines
        boolean is_interchange_metro
        string_array interchange_metro_lines
        boolean is_interchange_national_rail
        string interchange_national_rail_station_id
    }

    NATIONAL_RAIL_SCHEDULES {
        string schedule_id PK
        string line
        string service_type
        string direction
        string origin_station_id
        string destination_station_id
        string_array stops_in_order
        string_array passed_through_stations
        string first_train_time
        string last_train_time
        jsonb travel_time_from_origin_min
        jsonb fare_classes
        int frequency_min
        string_array operates_on
    }

    METRO_SCHEDULES {
        string schedule_id PK
        string line
        string direction
        string origin_station_id
        string destination_station_id
        string_array stops_in_order
        string first_train_time
        string last_train_time
        jsonb travel_time_from_origin_min
        decimal base_fare_usd
        decimal per_stop_rate_usd
        int frequency_min
        string_array operates_on
    }

    NATIONAL_RAIL_SEAT_LAYOUTS {
        string layout_id PK
        string schedule_id
        jsonb coaches
    }

    BOOKINGS {
        string booking_id PK
        string user_id
        string schedule_id
        string origin_station_id
        string destination_station_id
        date travel_date
        string departure_time
        string ticket_type
        string fare_class
        string coach
        string seat_id
        int stops_travelled
        decimal amount_usd
        string status
        timestamp booked_at
        timestamp travelled_at
    }

    METRO_TRAVEL_HISTORY {
        string trip_id PK
        string user_id
        string schedule_id
        string origin_station_id
        string destination_station_id
        date travel_date
        string ticket_type
        string day_pass_ref
        int stops_travelled
        decimal amount_usd
        string status
        timestamp purchased_at
        timestamp travelled_at
    }

    PAYMENTS {
        string payment_id PK
        string booking_id
        decimal amount_usd
        string method
        string status
        timestamp paid_at
    }

    FEEDBACK {
        string feedback_id PK
        string booking_id
        string user_id
        int rating
        string comment
        timestamp submitted_at
    }