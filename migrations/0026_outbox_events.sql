-- Outbox-таблица для атомарной публикации доменных событий вместе с
-- изменением данных: INSERT в бизнес-таблицу и INSERT сюда происходят в
-- одной транзакции, поэтому событие никогда не теряется (если transaction
-- закоммитилась, событие точно есть) и никогда не публикуется "из воздуха"
-- (если транзакция откатилась, события тоже нет). Отдельный поллер
-- (см. notrecinema-api/internal/outbox) вычитывает неопубликованные строки
-- и публикует их в NATS с ретраями.
--
-- RLS сознательно не включена: это внутренняя системная таблица, к ней не
-- обращаются от имени конкретного пользователя (как и к schema_migrations).

CREATE TABLE IF NOT EXISTS public.outbox_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  aggregate_type varchar(50) NOT NULL,
  aggregate_id uuid NOT NULL,
  event_type varchar(100) NOT NULL,
  payload jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  published_at timestamptz,
  attempts integer NOT NULL DEFAULT 0,
  last_error text
);

-- Частичный индекс: поллер всегда ищет именно неопубликованные строки,
-- и их всегда на несколько порядков меньше, чем опубликованных.
CREATE INDEX IF NOT EXISTS outbox_events_unpublished_index
  ON public.outbox_events (created_at)
  WHERE published_at IS NULL;
