# notrecinema-schema

Единственный источник истины для схемы PostgreSQL проекта notrecinema.
Раньше миграции жили внутри `notrecinema-app/database`, и `notrecinema-api`
был вынужден лезть в дерево соседнего репозитория, чтобы их применить.
Теперь и `notrecinema-app`, и `notrecinema-api`, и `notrecinema-worker`
ссылаются на этот пакет.

## Что внутри

- `migrations/*.sql` — миграции, применяются по имени файла в
  лексикографическом порядке, каждая — одной транзакцией.
- `grants.sql` — права `app_user` на схему `public`; переприменяется после
  каждого прогона миграций (не миграция сама по себе, `ALTER DEFAULT
  PRIVILEGES` действует только на объекты, созданные после своего вызова).
- `init.sh` — одноразовый бутстрап роли `app_user`, монтируется в
  `docker-entrypoint-initdb.d` официального образа `postgres`.
- `migrate.mjs` — раннер миграций (Node + `pg`), идемпотентен: хранит
  применённые файлы в `public.schema_migrations`.

## Использование

Как библиотека для `docker-compose.yml` соседних проектов:

```yaml
migrate:
  build:
    context: ../notrecinema-schema
  environment:
    MIGRATE_DATABASE_URL: postgresql://postgres:...@postgres:5432/...
```

Локально:

```bash
npm install
MIGRATE_DATABASE_URL=postgresql://postgres:pass@localhost:5432/notrecinema npm run migrate
```

## Добавление миграции

Новый файл `NNNN_описание.sql` в `migrations/`, номер — следующий по
порядку. Миграции не редактируются после того, как попали в `main` — только
новые файлы поверх.
