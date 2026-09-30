import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import pg from 'pg';

const rootDirectory = dirname(fileURLToPath(import.meta.url));
const migrationsDirectory = join(rootDirectory, 'migrations');
const grantsPath = join(rootDirectory, 'grants.sql');

// Минимальный загрузчик .env для ручных/локальных запусков (docker-compose
// сам прокидывает переменные окружения, там это no-op) — не тащим dotenv
// ради одного скрипта.
function loadDotEnvIfPresent() {
  const envPath = join(rootDirectory, '.env');
  if (!existsSync(envPath)) return;

  for (const line of readFileSync(envPath, 'utf8').split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;

    const equalsIndex = trimmed.indexOf('=');
    if (equalsIndex === -1) continue;

    const key = trimmed.slice(0, equalsIndex).trim();
    let value = trimmed.slice(equalsIndex + 1).trim();
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }

    process.env[key] ??= value;
  }
}

loadDotEnvIfPresent();

function resolveConnectionString() {
  if (process.env.MIGRATE_DATABASE_URL) {
    return process.env.MIGRATE_DATABASE_URL;
  }

  const { POSTGRES_USER, POSTGRES_PASSWORD, POSTGRES_DB, DB_HOST, DB_PORT } =
    process.env;

  if (POSTGRES_USER && POSTGRES_PASSWORD && POSTGRES_DB) {
    const host = DB_HOST || 'localhost';
    const port = DB_PORT || '5432';
    return `postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${host}:${port}/${POSTGRES_DB}`;
  }

  throw new Error(
    'Нет строки подключения для миграций: задайте MIGRATE_DATABASE_URL, ' +
      'либо POSTGRES_USER/POSTGRES_PASSWORD/POSTGRES_DB (те же ' +
      'суперпользовательские credentials, которыми init.sh создаёт ' +
      'app_user). DATABASE_URL намеренно не используется здесь — под ней ' +
      'подключается app_user, который не владеет схемой и не может ' +
      'выполнять DDL.',
  );
}

async function ensureMigrationsTable(client) {
  await client.query(`
    CREATE TABLE IF NOT EXISTS public.schema_migrations (
      filename text PRIMARY KEY,
      applied_at timestamptz NOT NULL DEFAULT NOW()
    )
  `);
}

async function getAppliedMigrations(client) {
  const result = await client.query(
    'SELECT filename FROM public.schema_migrations',
  );
  return new Set(result.rows.map((row) => row.filename));
}

async function applyMigration(client, filename, sql) {
  await client.query('BEGIN');
  try {
    await client.query(sql);
    await client.query(
      'INSERT INTO public.schema_migrations (filename) VALUES ($1)',
      [filename],
    );
    await client.query('COMMIT');
  } catch (error) {
    await client.query('ROLLBACK');
    throw new Error(`Миграция ${filename} упала: ${error.message}`, {
      cause: error,
    });
  }
}

async function main() {
  const client = new pg.Client({ connectionString: resolveConnectionString() });
  await client.connect();

  try {
    await ensureMigrationsTable(client);
    const applied = await getAppliedMigrations(client);

    const filenames = readdirSync(migrationsDirectory)
      .filter((name) => name.endsWith('.sql'))
      .sort();

    let appliedCount = 0;
    for (const filename of filenames) {
      if (applied.has(filename)) continue;

      const sql = readFileSync(join(migrationsDirectory, filename), 'utf8');
      console.log(`Применяю ${filename} ...`);
      await applyMigration(client, filename, sql);
      appliedCount += 1;
    }

    if (appliedCount === 0) {
      console.log('Нет непримененных миграций.');
    } else {
      console.log(`Применено миграций: ${appliedCount}.`);
    }

    // Гранты — не миграция, их нужно перевыполнять каждый раз, чтобы права
    // покрывали таблицы/функции, созданные только что применённой
    // миграцией: ALTER DEFAULT PRIVILEGES действует лишь на объекты,
    // созданные ПОСЛЕ своего выполнения.
    console.log('Переприменяю grants.sql ...');
    await client.query(readFileSync(grantsPath, 'utf8'));

    console.log('Готово.');
  } finally {
    await client.end();
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
