-- ============================================================
-- FlyPass VPN — Схема базы данных PostgreSQL
-- Создаётся автоматически при первом запуске контейнера
-- ============================================================

-- Включаем расширения
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";    -- UUID генерация
CREATE EXTENSION IF NOT EXISTS "pg_trgm";      -- Быстрый поиск по строкам

-- ============================================================
-- ТАБЛИЦА: users — все пользователи бота
-- ============================================================
CREATE TABLE IF NOT EXISTS users (
    id              BIGSERIAL PRIMARY KEY,
    tg_id           BIGINT UNIQUE NOT NULL,          -- Telegram user ID
    username        VARCHAR(64),                      -- @username (может быть NULL)
    first_name      VARCHAR(128),                     -- Имя в Telegram
    last_name       VARCHAR(128),                     -- Фамилия
    phone           VARCHAR(20),                      -- Телефон (если дал доступ)
    language_code   VARCHAR(8) DEFAULT 'ru',          -- Язык клиента
    balance         NUMERIC(10,2) DEFAULT 0.00,       -- Внутренний баланс в рублях
    is_banned       BOOLEAN DEFAULT FALSE,            -- Заблокирован?
    ban_reason      TEXT,                             -- Причина бана
    referred_by     BIGINT REFERENCES users(id),      -- Кто пригласил (user.id)
    trial_used      BOOLEAN DEFAULT FALSE,            -- Использовал триал?
    trial_used_at   TIMESTAMPTZ,                      -- Когда использовал триал
    trial_ip        INET,                             -- IP при использовании триала
    gift_activated  BOOLEAN DEFAULT FALSE,            -- Активировал подарок?
    marzban_id      VARCHAR(128),                     -- ID пользователя в Marzban
    sub_token       UUID DEFAULT uuid_generate_v4(),  -- Токен для sub-ссылки
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);

-- Индексы для быстрого поиска
CREATE INDEX IF NOT EXISTS idx_users_tg_id      ON users(tg_id);
CREATE INDEX IF NOT EXISTS idx_users_referred_by ON users(referred_by);
CREATE INDEX IF NOT EXISTS idx_users_sub_token   ON users(sub_token);
CREATE INDEX IF NOT EXISTS idx_users_username    ON users USING gin(username gin_trgm_ops);

-- ============================================================
-- ТАБЛИЦА: subscriptions — подписки пользователей
-- ============================================================
CREATE TABLE IF NOT EXISTS subscriptions (
    id              BIGSERIAL PRIMARY KEY,
    user_id         BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    plan            VARCHAR(32) NOT NULL,             -- 'basic' | 'family' | 'team' | 'trial' | 'gift'
    devices_limit   INT NOT NULL,                     -- 3, 6 или 9
    months          INT NOT NULL,                     -- 0 (триал/подарок), 1, 3, 6, 12
    price_paid      NUMERIC(10,2) DEFAULT 0.00,       -- Сколько заплатил
    started_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at      TIMESTAMPTZ NOT NULL,             -- Когда истекает
    is_active       BOOLEAN DEFAULT TRUE,
    marzban_user    VARCHAR(128),                     -- username в Marzban
    node_id         INT REFERENCES server_nodes(id),  -- На каком VPN-узле
    -- Уведомления об истечении
    notified_24h    BOOLEAN DEFAULT FALSE,            -- Уведомлён за 24ч?
    notified_1h     BOOLEAN DEFAULT FALSE,            -- Уведомлён за 1ч? (для триала)
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_subs_user_id    ON subscriptions(user_id);
CREATE INDEX IF NOT EXISTS idx_subs_expires_at ON subscriptions(expires_at);
CREATE INDEX IF NOT EXISTS idx_subs_is_active  ON subscriptions(is_active);
CREATE INDEX IF NOT EXISTS idx_subs_marzban    ON subscriptions(marzban_user);

-- ============================================================
-- ТАБЛИЦА: server_nodes — VPN-узлы
-- ============================================================
CREATE TABLE IF NOT EXISTS server_nodes (
    id              SERIAL PRIMARY KEY,
    name            VARCHAR(64) NOT NULL,             -- 'Germany', 'Netherlands' и т.д.
    country_code    VARCHAR(4) NOT NULL,              -- 'DE', 'NL', 'FI' и т.д.
    flag_emoji      VARCHAR(8),                       -- '🇩🇪', '🇳🇱' и т.д.
    ip_address      INET NOT NULL,
    marzban_url     TEXT NOT NULL,                    -- https://node-de.flypass.ru
    marzban_token   TEXT,                             -- API токен узла
    is_active       BOOLEAN DEFAULT TRUE,
    is_maintenance  BOOLEAN DEFAULT FALSE,            -- На обслуживании
    sort_order      INT DEFAULT 0,                    -- Порядок в списке
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================
-- ТАБЛИЦА: payments — все платежи
-- ============================================================
CREATE TABLE IF NOT EXISTS payments (
    id              BIGSERIAL PRIMARY KEY,
    user_id         BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    yookassa_id     VARCHAR(128) UNIQUE,              -- ID платежа в YooKassa
    amount          NUMERIC(10,2) NOT NULL,
    currency        VARCHAR(8) DEFAULT 'RUB',
    status          VARCHAR(32) NOT NULL DEFAULT 'pending',
    -- 'pending' | 'waiting_for_capture' | 'succeeded' | 'canceled' | 'refunded'
    payment_type    VARCHAR(32) NOT NULL,
    -- 'subscription' | 'balance_topup' | 'gift_purchase'
    plan            VARCHAR(32),                      -- Тариф (если подписка)
    months          INT,                              -- Срок (если подписка)
    subscription_id BIGINT REFERENCES subscriptions(id),
    gift_id         BIGINT REFERENCES gifts(id),
    description     TEXT,
    metadata        JSONB DEFAULT '{}',               -- Дополнительные данные
    paid_at         TIMESTAMPTZ,
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_payments_user_id     ON payments(user_id);
CREATE INDEX IF NOT EXISTS idx_payments_yookassa_id ON payments(yookassa_id);
CREATE INDEX IF NOT EXISTS idx_payments_status      ON payments(status);

-- ============================================================
-- ТАБЛИЦА: referrals — реферальные связи
-- ============================================================
CREATE TABLE IF NOT EXISTS referrals (
    id              BIGSERIAL PRIMARY KEY,
    referrer_id     BIGINT NOT NULL REFERENCES users(id),   -- Кто пригласил
    referred_id     BIGINT NOT NULL REFERENCES users(id),   -- Кого пригласили
    level           INT NOT NULL DEFAULT 1,                  -- 1 или 2
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(referrer_id, referred_id)
);

CREATE INDEX IF NOT EXISTS idx_referrals_referrer ON referrals(referrer_id);
CREATE INDEX IF NOT EXISTS idx_referrals_referred ON referrals(referred_id);

-- ============================================================
-- ТАБЛИЦА: referral_bonuses — начисления по рефералам
-- ============================================================
CREATE TABLE IF NOT EXISTS referral_bonuses (
    id              BIGSERIAL PRIMARY KEY,
    user_id         BIGINT NOT NULL REFERENCES users(id),   -- Кому начислено
    from_user_id    BIGINT NOT NULL REFERENCES users(id),   -- От кого (реферал)
    payment_id      BIGINT NOT NULL REFERENCES payments(id),
    level           INT NOT NULL,                           -- 1 или 2
    percent         NUMERIC(5,2) NOT NULL,                  -- 20.00 или 5.00
    amount          NUMERIC(10,2) NOT NULL,                 -- Начисленная сумма
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_ref_bonuses_user_id ON referral_bonuses(user_id);

-- ============================================================
-- ТАБЛИЦА: gifts — подарочные подписки
-- ============================================================
CREATE TABLE IF NOT EXISTS gifts (
    id              BIGSERIAL PRIMARY KEY,
    buyer_id        BIGINT NOT NULL REFERENCES users(id),   -- Кто купил
    recipient_id    BIGINT REFERENCES users(id),            -- Кто активировал
    token           UUID DEFAULT uuid_generate_v4() UNIQUE, -- Уникальный токен ссылки
    plan            VARCHAR(32) NOT NULL,                    -- 'basic_1m' и т.д.
    devices_limit   INT NOT NULL DEFAULT 1,
    months          INT NOT NULL,
    price_paid      NUMERIC(10,2) NOT NULL,
    is_used         BOOLEAN DEFAULT FALSE,
    activated_at    TIMESTAMPTZ,
    expires_gift_at TIMESTAMPTZ,                            -- Срок самого подарка (не подписки)
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_gifts_token     ON gifts(token);
CREATE INDEX IF NOT EXISTS idx_gifts_buyer_id  ON gifts(buyer_id);

-- ============================================================
-- ТАБЛИЦА: balance_transactions — история баланса
-- ============================================================
CREATE TABLE IF NOT EXISTS balance_transactions (
    id              BIGSERIAL PRIMARY KEY,
    user_id         BIGINT NOT NULL REFERENCES users(id),
    amount          NUMERIC(10,2) NOT NULL,                 -- + пополнение, - списание
    balance_after   NUMERIC(10,2) NOT NULL,                 -- Баланс после операции
    type            VARCHAR(32) NOT NULL,
    -- 'topup' | 'referral_bonus' | 'spend_subscription' | 'spend_gift' | 'admin_adjustment' | 'refund'
    description     TEXT,
    payment_id      BIGINT REFERENCES payments(id),
    admin_id        BIGINT REFERENCES users(id),            -- Если изменил админ
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_balance_tx_user_id ON balance_transactions(user_id);

-- ============================================================
-- ТАБЛИЦА: admin_logs — все действия администраторов
-- ============================================================
CREATE TABLE IF NOT EXISTS admin_logs (
    id              BIGSERIAL PRIMARY KEY,
    admin_id        BIGINT NOT NULL REFERENCES users(id),
    admin_username  VARCHAR(64),
    action          VARCHAR(64) NOT NULL,
    -- 'ban_user' | 'unban_user' | 'extend_sub' | 'change_balance' |
    -- 'broadcast' | 'generate_gift' | 'delete_user' | 'add_node' и т.д.
    target_user_id  BIGINT REFERENCES users(id),
    target_data     JSONB DEFAULT '{}',                    -- Что именно изменено
    ip_address      INET,
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_admin_logs_admin_id ON admin_logs(admin_id);
CREATE INDEX IF NOT EXISTS idx_admin_logs_created  ON admin_logs(created_at DESC);

-- ============================================================
-- ТАБЛИЦА: trial_protection — защита триала от обхода
-- ============================================================
CREATE TABLE IF NOT EXISTS trial_protection (
    id              BIGSERIAL PRIMARY KEY,
    tg_id           BIGINT UNIQUE NOT NULL,
    ip_address      INET,
    device_hash     VARCHAR(128),                          -- Fingerprint устройства
    used_at         TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_trial_ip     ON trial_protection(ip_address);
CREATE INDEX IF NOT EXISTS idx_trial_device ON trial_protection(device_hash);

-- ============================================================
-- ТАБЛИЦА: broadcasts — рассылки
-- ============================================================
CREATE TABLE IF NOT EXISTS broadcasts (
    id              BIGSERIAL PRIMARY KEY,
    admin_id        BIGINT NOT NULL REFERENCES users(id),
    text            TEXT NOT NULL,
    target          VARCHAR(32) DEFAULT 'all',
    -- 'all' | 'active' | 'plan_basic' | 'plan_family' | 'plan_team' | 'node_X'
    sent_count      INT DEFAULT 0,
    failed_count    INT DEFAULT 0,
    status          VARCHAR(16) DEFAULT 'pending',         -- 'pending' | 'running' | 'done'
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    finished_at     TIMESTAMPTZ
);

-- ============================================================
-- ФУНКЦИЯ: автоматически обновляет updated_at
-- ============================================================
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Применяем триггер к нужным таблицам
CREATE TRIGGER trg_users_updated_at
    BEFORE UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

CREATE TRIGGER trg_subscriptions_updated_at
    BEFORE UPDATE ON subscriptions
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

CREATE TRIGGER trg_payments_updated_at
    BEFORE UPDATE ON payments
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- ============================================================
-- НАЧАЛЬНЫЕ ДАННЫЕ: тарифные планы (справочник)
-- ============================================================
CREATE TABLE IF NOT EXISTS plans (
    id              SERIAL PRIMARY KEY,
    code            VARCHAR(32) UNIQUE NOT NULL,  -- 'basic', 'family', 'team'
    name            VARCHAR(64) NOT NULL,
    devices_limit   INT NOT NULL,
    price_1m        NUMERIC(10,2),
    price_3m        NUMERIC(10,2),
    price_6m        NUMERIC(10,2),
    price_12m       NUMERIC(10,2),
    is_active       BOOLEAN DEFAULT TRUE
);

INSERT INTO plans (code, name, devices_limit, price_1m, price_3m, price_6m, price_12m)
VALUES
    ('basic',  'Базовый',  3, 170.00,  480.00,  900.00,  1680.00),
    ('family', 'Семейный', 6, 329.00,  999.00,  1790.00, 3499.00),
    ('team',   'Команда',  9, 499.00,  1479.00, 2699.00, 4990.00)
ON CONFLICT (code) DO NOTHING;

-- ============================================================
-- НАЧАЛЬНЫЕ ДАННЫЕ: VPN-узлы (добавь свои IP после деплоя)
-- ============================================================
INSERT INTO server_nodes (name, country_code, flag_emoji, ip_address, marzban_url, sort_order)
VALUES
    ('Germany',     'DE', '🇩🇪', '1.2.3.4', 'https://node-de.flypass.ru', 1),
    ('Netherlands', 'NL', '🇳🇱', '1.2.3.5', 'https://node-nl.flypass.ru', 2),
    ('Finland',     'FI', '🇫🇮', '1.2.3.6', 'https://node-fi.flypass.ru', 3),
    ('Latvia',      'LV', '🇱🇻', '1.2.3.7', 'https://node-lv.flypass.ru', 4),
    ('France',      'FR', '🇫🇷', '1.2.3.8', 'https://node-fr.flypass.ru', 5),
    ('Poland',      'PL', '🇵🇱', '1.2.3.9', 'https://node-pl.flypass.ru', 6)
ON CONFLICT DO NOTHING;
