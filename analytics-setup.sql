-- ============================================================================
-- Приёмник обезличенной статистики «Мой ритм сегодня»
--
-- Выполнить целиком в SQL Editor проекта Supabase.
-- Личные данные женщин сюда не попадают: только событие, дата и источник.
-- ============================================================================

create table if not exists public.events (
  id          bigserial primary key,
  event       text not null,
  event_date  date not null,
  source      text not null default 'direct',
  created_at  timestamptz not null default now(),

  -- принимаем только известные коды: посторонний мусор в таблицу не попадёт
  constraint events_known_code check (event in (
    'OPEN', 'START', 'RESULT', 'TRY_TODAY',
    'FIT_YES', 'FIT_PARTLY', 'FIT_NO',
    'EVENING_START', 'EVENING_DONE',
    'HELPED', 'NO_CHANGE', 'DID_NOT_FIT',
    'RETURN_D1', 'RETURN_D7'
  )),

  -- источник: латиница, цифры, дефис и подчёркивание, не длиннее 32 символов
  constraint events_source_format check (source ~ '^[A-Za-z0-9_-]{1,32}$'),

  -- дата события не может быть из будущего или из глубокого прошлого
  constraint events_date_sane check (event_date between date '2026-01-01' and current_date + 1)
);

create index if not exists events_date_idx   on public.events (event_date desc);
create index if not exists events_source_idx on public.events (source, event_date desc);

-- ============================================================================
-- Доступ
-- ============================================================================

alter table public.events enable row level security;

-- Приложение отправляет события публичным ключом anon: вставлять можно,
-- читать нельзя. Иначе статистику увидел бы любой, кто открыл исходный код сайта.
drop policy if exists "events_insert_anon" on public.events;
create policy "events_insert_anon" on public.events
  for insert to anon with check (true);

-- Читает только тот, кто вошёл в админ-панель под своей учётной записью.
drop policy if exists "events_select_auth" on public.events;
create policy "events_select_auth" on public.events
  for select to authenticated using (true);

-- Права на удаление и изменение не выдаются никому: статистику нельзя
-- ни подчистить, ни переписать через публичный ключ.

-- ============================================================================
-- Проверка после выполнения
-- ============================================================================

-- 1. Защита включена — должно вернуть rowsecurity = true
-- select tablename, rowsecurity from pg_tables
--  where schemaname = 'public' and tablename = 'events';

-- 2. Политики на месте — должно вернуть две строки
-- select policyname, cmd, roles from pg_policies
--  where schemaname = 'public' and tablename = 'events';

-- 3. Сколько событий уже пришло
-- select event, count(*) from public.events group by event order by 2 desc;

-- 4. Воронка по источникам
-- select source,
--        count(*) filter (where event = 'OPEN')       as открыли,
--        count(*) filter (where event = 'RESULT')     as результат,
--        count(*) filter (where event = 'TRY_TODAY')  as попробовали,
--        count(*) filter (where event = 'RETURN_D1')  as день_2,
--        count(*) filter (where event = 'RETURN_D7')  as неделя
--   from public.events group by source order by открыли desc;
