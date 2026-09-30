-- Таблица идемпотентности для notrecinema-worker: NATS JetStream гарантирует
-- at-least-once доставку, то есть одно и то же сообщение может прийти
-- повторно (redelivery после падения воркера, network partition и т.д.).
-- Воркер перед обработкой пытается вставить event_id сюда; если строка уже
-- есть (PRIMARY KEY конфликт) — событие уже обработано, просто ack и выход.

CREATE TABLE IF NOT EXISTS public.worker_processed_events (
  event_id uuid PRIMARY KEY,
  processed_at timestamptz NOT NULL DEFAULT NOW()
);
