# Supabase: структура базы, SQL, RLS и подключение

Приложение уже написано так, что переезд в облако не требует переписывания логики.
Все данные проходят через единый модуль `Store` в `index.html`. Сейчас работает
реализация `LocalStore` (localStorage), рядом лежит готовая `SupabaseStore` с теми же
методами и теми же именами полей, что и колонки таблиц ниже.

---

## 1. Структура базы

Три таблицы. Персональных данных нет: ни имени, ни почты, ни телефона, ни даты рождения.
Пользовательница опознаётся анонимным идентификатором, который выдаёт сам Supabase
при анонимном входе.

### `profiles` — настройки цикла, одна строка на человека

| Колонка | Тип | Смысл |
|---|---|---|
| `anon_id` | uuid, PK | анонимный id из Supabase Auth |
| `cycle_length` | smallint | обычная длина цикла, 21–40 |
| `period_length` | smallint | обычная продолжительность менструации, 2–10 |
| `is_regular` | boolean | `true` / `false` / `null` («не знаю») |
| `last_period_start` | date | первый день последней менструации |
| `created_at` | timestamptz | когда профиль создан |
| `updated_at` | timestamptz | когда данные цикла последний раз менялись |
| `visit_count` | integer | сколько раз приложение открывали |
| `last_visit_date` | date | дата последнего открытия |

### `daily_entries` — один день, утро и вечер в одной строке

| Колонка | Тип | Смысл |
|---|---|---|
| `id` | uuid, PK | |
| `anon_id` | uuid | владелец записи |
| `entry_date` | date | дата наблюдения |
| `cycle_day` | smallint | день цикла |
| `phase` | text | `menstrual` / `follicular` / `ovulatory` / `luteal` / `luteal_late` |
| `answers` | jsonb | ответы на пять вопросов: `{"q1":"a", …, "q5":"d"}` |
| `mode` | text | режим тела: `create` / `express` / `gather` / `integrate` |
| `mode_secondary` | text | второй режим, если состояние переходное |
| `is_transition` | boolean | показан ли переходный режим |
| `alignment` | text | `aligned` / `partial` / `divergent` — совпало ли состояние с фазой |
| `created_at` | timestamptz | |
| `evening_resource` | text | что дало ресурс |
| `evening_excess` | text | что оказалось лишним |
| `evening_body` | text | что просит тело |
| `evening_at` | timestamptz | когда заполнен вечерний check-in |

Ограничение `unique (anon_id, entry_date)` — один день, одна строка. Если день проходят
заново, запись обновляется, а не дублируется.

### `visits` — факт визита, в том числе повторного

| Колонка | Тип | Смысл |
|---|---|---|
| `id` | uuid, PK | |
| `anon_id` | uuid | |
| `visited_at` | timestamptz | момент открытия |
| `visit_type` | text | `morning` / `evening` — до или после 18:00 |
| `is_return_visit` | boolean | был ли профиль на момент открытия |

---

## 2. SQL для создания таблиц

Выполняется целиком в **SQL Editor** проекта Supabase.

```sql
-- ============ profiles ============
create table public.profiles (
  anon_id           uuid primary key references auth.users (id) on delete cascade,
  cycle_length      smallint    not null check (cycle_length between 21 and 40),
  period_length     smallint    not null check (period_length between 2 and 10),
  is_regular        boolean,
  last_period_start date        not null,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  visit_count       integer     not null default 0,
  last_visit_date   date,
  constraint period_shorter_than_cycle check (period_length < cycle_length)
);

-- ============ daily_entries ============
create table public.daily_entries (
  id               uuid primary key default gen_random_uuid(),
  anon_id          uuid not null references auth.users (id) on delete cascade,
  entry_date       date not null,
  cycle_day        smallint check (cycle_day between 1 and 40),
  phase            text  check (phase in ('menstrual','follicular','ovulatory','luteal','luteal_late')),
  answers          jsonb,
  mode             text  check (mode in ('create','express','gather','integrate')),
  mode_secondary   text  check (mode_secondary in ('create','express','gather','integrate')),
  is_transition    boolean,
  alignment        text  check (alignment in ('aligned','partial','divergent')),
  created_at       timestamptz not null default now(),
  evening_resource text,
  evening_excess   text,
  evening_body     text,
  evening_at       timestamptz,
  unique (anon_id, entry_date)
);

create index daily_entries_anon_date_idx
  on public.daily_entries (anon_id, entry_date desc);

-- ============ visits ============
create table public.visits (
  id              uuid primary key default gen_random_uuid(),
  anon_id         uuid not null references auth.users (id) on delete cascade,
  visited_at      timestamptz not null default now(),
  visit_type      text not null check (visit_type in ('morning','evening')),
  is_return_visit boolean not null default false
);

create index visits_anon_visited_idx
  on public.visits (anon_id, visited_at desc);

-- ============ автоматический updated_at ============
create or replace function public.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger profiles_touch_updated_at
  before update on public.profiles
  for each row execute function public.touch_updated_at();
```

---

## 3. RLS policies

Каждая женщина видит и меняет только свои строки. Права на удаление не выдаются никому:
записи наблюдений не должны исчезать по ошибке клиента.

```sql
alter table public.profiles      enable row level security;
alter table public.daily_entries enable row level security;
alter table public.visits        enable row level security;

-- ---------- profiles ----------
create policy "profiles_select_own" on public.profiles
  for select using (auth.uid() = anon_id);

create policy "profiles_insert_own" on public.profiles
  for insert with check (auth.uid() = anon_id);

create policy "profiles_update_own" on public.profiles
  for update using (auth.uid() = anon_id)
          with check (auth.uid() = anon_id);

-- ---------- daily_entries ----------
create policy "entries_select_own" on public.daily_entries
  for select using (auth.uid() = anon_id);

create policy "entries_insert_own" on public.daily_entries
  for insert with check (auth.uid() = anon_id);

create policy "entries_update_own" on public.daily_entries
  for update using (auth.uid() = anon_id)
          with check (auth.uid() = anon_id);

-- ---------- visits ----------
create policy "visits_select_own" on public.visits
  for select using (auth.uid() = anon_id);

create policy "visits_insert_own" on public.visits
  for insert with check (auth.uid() = anon_id);
```

Проверка, что защита включена (все три таблицы должны показать `rowsecurity = true`):

```sql
select tablename, rowsecurity
from pg_tables
where schemaname = 'public'
  and tablename in ('profiles','daily_entries','visits');
```

---

## 4. Инструкция подключения

1. Создать проект на [supabase.com](https://supabase.com) (бесплатного тарифа хватает).
2. Открыть **SQL Editor** и выполнить сначала блок из раздела 2, затем блок из раздела 3.
3. Включить анонимные входы: **Authentication → Sign In / Providers → Anonymous sign-ins → включить**.
   Именно они выдают `auth.uid()`, на котором держатся все политики.
4. Скопировать из **Project Settings → Data API**: `Project URL` и ключ `anon public`.
5. В `index.html` раскомментировать строку подключения библиотеки — она лежит прямо
   перед основным скриптом:

   ```html
   <script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/dist/umd/supabase.js"></script>
   ```

6. В том же файле, в начале скрипта, заполнить блок `CONFIG`:

   ```js
   var CONFIG = {
     BACKEND: "supabase",
     SUPABASE_URL: "https://ваш-проект.supabase.co",
     SUPABASE_ANON_KEY: "eyJhbGciOi...",
     EVENING_HOUR: 18
   };
   ```

7. Открыть приложение, пройти день и убедиться в **Table Editor**, что появились строки
   в `profiles`, `daily_entries` и `visits`.

Больше править ничего не нужно: остальной код обращается только к `Store`.

### Что происходит с уже накопленными локальными данными

Они остаются в браузере и в облако сами не переедут — при переключении история начнётся
заново. Если нужно перенести, выгрузи их из консоли браузера до переключения:

```js
copy(localStorage.getItem("ritm.entries"))
```

и вставь в таблицу через Table Editor, подставив `anon_id` нового анонимного пользователя.

### Про ключ `anon public`

Он публичный по замыслу: попадает в исходный код страницы, и это нормально. Данные
защищает не он, а RLS — без валидной сессии политики не пропустят ни одной строки.
Ключ `service_role` в клиентский код класть нельзя никогда.
