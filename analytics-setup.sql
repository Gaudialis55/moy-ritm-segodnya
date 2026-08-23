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

-- Читают только те, кто явно внесён в список администраторов.
-- Роли authenticated недостаточно: если позже включить анонимный вход для
-- личных данных, эту роль получат все пользовательницы приложения.
create table if not exists public.admins (
  user_id  uuid primary key references auth.users (id) on delete cascade,
  email    text,
  added_at timestamptz not null default now()
);

alter table public.admins enable row level security;

drop policy if exists "admins_read_self" on public.admins;
create policy "admins_read_self" on public.admins
  for select to authenticated using (user_id = auth.uid());

drop policy if exists "events_select_auth" on public.events;
drop policy if exists "events_select_admins" on public.events;
create policy "events_select_admins" on public.events
  for select to authenticated
  using (exists (select 1 from public.admins a where a.user_id = auth.uid()));

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

-- ============================================================================
-- Как добавить ещё одного администратора
-- ============================================================================
--
-- 1. Authentication -> Users -> Add user -> Create new user:
--    указать почту и пароль, включить "Auto confirm user".
--    Пароль задаёт сам человек или владелец проекта.
--
-- 2. Выполнить здесь, подставив ту же почту:
--
-- insert into public.admins (user_id, email)
-- select id, email from auth.users where email = 'новый-админ@почта'
-- on conflict (user_id) do nothing;
--
-- Проверить список:
-- select email, added_at from public.admins order by added_at;
--
-- Отобрать доступ:
-- delete from public.admins where email = 'бывший-админ@почта';
-- (сама учётная запись останется, но статистику она больше не увидит)
--
-- ВАЖНО: в Authentication -> Sign In / Providers переключатель
-- "Allow new users to sign up" должен оставаться выключенным. Иначе любой,
-- кто возьмёт публичный ключ из кода сайта, заведёт себе учётную запись.
-- Список admins защитит статистику и в этом случае, но лишние аккаунты
-- в проекте не нужны.
