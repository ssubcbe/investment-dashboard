-- ════════════════════════════════════════════════════════════════════════════
--  Financial Investment Personal Dashboard — initial database schema
--  Supabase (Postgres 15+). Run once in a new project: SQL Editor → paste → Run,
--  or `supabase db push` with this file in supabase/migrations/.
--
--  Design
--  • Every personal row carries user_id = auth.uid(). Row Level Security lets each
--    signed-in person read and change only their own rows (5 invited users).
--  • Child rows reference their parent by (id, user_id), so a row can never point
--    at another person's account, investment or folio.
--  • Market data (closing prices, NAVs, FX rates, ticker/AMFI names) is shared:
--    every signed-in user can read it; only the nightly price job (service role,
--    which bypasses RLS) writes it.
--  • Calculations (average cost, P/L, XIRR, weekly history, ISA allowance,
--    residual cash) stay in the app, exactly as in the prototype.
-- ════════════════════════════════════════════════════════════════════════════

begin;

-- ─────────────────────────── Types ───────────────────────────
create type public.region           as enum ('UK', 'IN');
create type public.account_type     as enum ('ISA', 'LISA', 'PPEN', 'CPEN', 'PB', 'GEN');
create type public.instrument_type  as enum ('ETF', 'Mutual fund', 'Stock', 'Premium bond');
create type public.price_ccy        as enum ('GBP', 'GBX', 'USD', 'EUR', 'INR');
create type public.tx_type          as enum ('BUY', 'SELL', 'TRANSFER', 'INCOME', 'CASH');
create type public.income_kind      as enum ('DIV', 'INTEREST', 'BONUS', 'PRIZE', 'OTHER');
create type public.cash_dir         as enum ('IN', 'OUT');
create type public.yes_no           as enum ('Y', 'N');
create type public.nri_account      as enum ('NRE', 'NRO');
create type public.symbol_kind      as enum ('TICKER', 'ISIN', 'AMFI');

-- ─────────────────────────── Helpers ───────────────────────────
create or replace function public.touch_updated_at() returns trigger
language plpgsql set search_path = '' as $$
begin new.updated_at := now(); return new; end $$;

-- ─────────────────────────── Profile & settings ───────────────────────────
-- One row per person. Created automatically on first sign-in (trigger below).
create table public.profiles (
  user_id      uuid primary key references auth.users (id) on delete cascade,
  display_name text,
  -- App settings that used to live in S.settings
  fx_rates     jsonb not null default '{"USD": 0.75, "EUR": 0.86}'::jsonb,   -- £ per 1 unit, manual fallback
  allowances   jsonb not null default '{"default": {"isa": 20000, "lisa": 4000}}'::jsonb, -- per tax year "2026/27": {isa, lisa}
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (user_id, display_name)
  values (new.id, coalesce(new.raw_user_meta_data ->> 'display_name', split_part(new.email, '@', 1)))
  on conflict (user_id) do nothing;
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ─────────────────────────── Accounts ───────────────────────────
-- UK: Stocks & Shares ISA, Lifetime ISA, Personal Pension, Corporate Pension, Premium Bonds.
-- India: General Investment. One row per provider (e.g. ISA · Vanguard, ISA · AJ Bell).
create table public.accounts (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null default auth.uid() references auth.users (id) on delete cascade,
  region      public.region not null,
  type        public.account_type not null,
  name        text not null check (length(trim(name)) > 0),
  provider    text not null default '',
  sort_order  int  not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (id, user_id),
  constraint account_region_matches_type check (
    (region = 'UK' and type in ('ISA', 'LISA', 'PPEN', 'CPEN', 'PB')) or
    (region = 'IN' and type = 'GEN'))
);
create index accounts_user_idx on public.accounts (user_id);

-- ─────────────────────────── India: folios & AMC checks ───────────────────────────
create table public.folios (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null default auth.uid() references auth.users (id) on delete cascade,
  amc         text not null check (length(trim(amc)) > 0),
  number      text not null check (length(trim(number)) > 0),
  holder      text not null default '',
  notes       text not null default '',
  verified    public.yes_no,              -- "platform folio verified with AMC"
  verified_on date,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (id, user_id),
  unique (user_id, amc, number)
);
create index folios_user_idx on public.folios (user_id);

-- KYC and nominee status, one row per fund house (AMC) per person
create table public.amc_checks (
  user_id      uuid not null default auth.uid() references auth.users (id) on delete cascade,
  amc          text not null check (length(trim(amc)) > 0),
  kyc          public.yes_no,
  kyc_on       date,
  nominee      public.yes_no,
  nominee_on   date,
  updated_at   timestamptz not null default now(),
  primary key (user_id, amc)
);

-- ─────────────────────────── Investments ───────────────────────────
-- A person's own record of an ETF / fund / share / Premium Bonds.
-- ticker: UK exchange ticker (VWRP.L, AAPL) or fund ISIN; India stock RELIANCE.NS / INFY.BO;
-- India mutual fund: AMFI scheme code (digits only).
create table public.instruments (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null default auth.uid() references auth.users (id) on delete cascade,
  region       public.region not null,
  type         public.instrument_type not null,
  name         text not null check (length(trim(name)) > 0),
  ticker       text not null default '',
  ccy          public.price_ccy not null,
  fixed_price  numeric(12, 4),                   -- 1 for Premium Bonds, else null
  exchange     text check (exchange in ('NSE', 'BSE')),   -- India stocks
  platform     text not null default '',         -- India: Kuvera, Zerodha …
  nri          public.nri_account,               -- India: bank account it was funded from
  folio_id     uuid,                             -- India mutual funds
  amc          text not null default '',
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (id, user_id),
  foreign key (folio_id, user_id) references public.folios (id, user_id) on delete set null (folio_id),
  constraint instrument_region_rules check (
    (region = 'UK' and type in ('ETF', 'Mutual fund', 'Stock', 'Premium bond') and ccy in ('GBP', 'GBX', 'USD', 'EUR')
       and exchange is null and nri is null and folio_id is null) or
    (region = 'IN' and type in ('Mutual fund', 'Stock') and ccy = 'INR')),
  constraint amfi_code_digits check (not (region = 'IN' and type = 'Mutual fund') or ticker = '' or ticker ~ '^[0-9]{5,6}$')
);
create index instruments_user_idx on public.instruments (user_id);
create index instruments_folio_idx on public.instruments (folio_id);

-- Prices the person entered by hand (or imported from Excel)
create table public.instrument_prices (
  instrument_id uuid not null,
  user_id       uuid not null default auth.uid() references auth.users (id) on delete cascade,
  price_date    date not null,
  close         numeric(18, 6) not null check (close > 0),
  primary key (instrument_id, price_date),
  foreign key (instrument_id, user_id) references public.instruments (id, user_id) on delete cascade
);
create index instrument_prices_user_idx on public.instrument_prices (user_id);

-- Declared (announced) dividends, used for the next projected payout
create table public.declared_dividends (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null default auth.uid() references auth.users (id) on delete cascade,
  instrument_id uuid not null,
  ex_date       date,
  pay_date      date not null,
  per_unit      numeric(18, 6) not null check (per_unit > 0),
  ccy           public.price_ccy not null,
  created_at    timestamptz not null default now(),
  foreign key (instrument_id, user_id) references public.instruments (id, user_id) on delete cascade
);
create index declared_dividends_user_idx on public.declared_dividends (user_id);

-- ─────────────────────────── Transactions ───────────────────────────
-- BUY / SELL: units, price (in the investment's currency), fees and fx (account ccy per 1 price ccy; GBX = 0.01)
-- TRANSFER:   units moved to to_account_id (null = left the dashboard)
-- INCOME:     amount (account currency) and income_kind
-- CASH:       Stocks & Shares ISA only — amount paid in (dir IN) or withdrawn (dir OUT);
--             new_money = false for a transfer in from another ISA
create table public.transactions (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null default auth.uid() references auth.users (id) on delete cascade,
  account_id     uuid not null,
  instrument_id  uuid,
  type           public.tx_type not null,
  trade_date     date not null,
  seq            bigint generated by default as identity,   -- keeps same-day order
  units          numeric(20, 6),
  price          numeric(18, 6),
  fees           numeric(14, 2) not null default 0 check (fees >= 0),
  fx             numeric(18, 8) not null default 1 check (fx > 0),
  amount         numeric(14, 2),
  income_kind    public.income_kind,
  to_account_id  uuid,
  new_money      boolean,
  cash_dir       public.cash_dir,
  note           text not null default '',
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  foreign key (account_id, user_id)    references public.accounts (id, user_id) on delete restrict,
  foreign key (instrument_id, user_id) references public.instruments (id, user_id) on delete restrict,
  foreign key (to_account_id, user_id) references public.accounts (id, user_id) on delete restrict,
  -- coalesce(…, false): a missing required value (NULL) must fail the check, not pass it
  constraint tx_shape check (coalesce(
    case type
      when 'BUY'      then instrument_id is not null and units > 0 and price > 0 and amount is null and cash_dir is null
      when 'SELL'     then instrument_id is not null and units > 0 and price > 0 and amount is null and cash_dir is null and new_money is null
      when 'TRANSFER' then instrument_id is not null and units > 0 and price is null and amount is null and cash_dir is null and new_money is null
      when 'INCOME'   then instrument_id is not null and amount > 0 and income_kind is not null and units is null and price is null and cash_dir is null and new_money is null
      when 'CASH'     then instrument_id is null and amount > 0 and cash_dir is not null and units is null and price is null and to_account_id is null
                           and (cash_dir = 'IN' or new_money is null)
    end, false)),
  constraint tx_not_in_future check (trade_date <= (now() at time zone 'utc')::date + 1)
);
create index transactions_user_date_idx on public.transactions (user_id, trade_date, seq);
create index transactions_account_idx   on public.transactions (account_id);
create index transactions_instrument_idx on public.transactions (instrument_id);

-- Rules the table constraints can't express on their own
create or replace function public.check_transaction() returns trigger
language plpgsql set search_path = '' as $$
declare acc public.accounts; ins public.instruments; dest public.accounts;
begin
  select * into acc from public.accounts where id = new.account_id;
  if new.instrument_id is not null then
    select * into ins from public.instruments where id = new.instrument_id;
    if ins.region <> acc.region then
      raise exception 'The account and the investment are in different countries.';
    end if;
  end if;
  if new.type = 'CASH' and acc.type <> 'ISA' then
    raise exception 'Cash entries are for Stocks & Shares ISA accounts only.';
  end if;
  if new.new_money is not null and acc.type not in ('ISA', 'LISA') then
    new.new_money := null;   -- only meaningful in an ISA wrapper
  end if;
  if new.to_account_id is not null then
    select * into dest from public.accounts where id = new.to_account_id;
    if dest.region <> acc.region then raise exception 'Transfers must stay within the same country.'; end if;
    if dest.id = acc.id then raise exception 'Choose a different account to transfer to.'; end if;
  end if;
  return new;
end $$;

create trigger transactions_check before insert or update on public.transactions
  for each row execute function public.check_transaction();

-- ─────────────────────────── Shared market data ───────────────────────────
-- Written by the nightly price job (service role); read by every signed-in user.
create table public.market_prices (
  symbol_kind  public.symbol_kind not null,
  symbol       text not null,                   -- VWRP.L / GB00B41YBW71 / 122639 / RELIANCE.NS
  price_date   date not null,
  close        numeric(18, 6) not null check (close > 0),
  ccy          public.price_ccy not null,
  source       text not null default '',        -- e.g. 'amfi', 'yahoo'
  fetched_at   timestamptz not null default now(),
  primary key (symbol_kind, symbol, price_date)
);
create index market_prices_latest_idx on public.market_prices (symbol_kind, symbol, price_date desc);

create table public.fx_rates (
  ccy        public.price_ccy not null,           -- USD, EUR, INR …
  rate_date  date not null,
  gbp_per_unit numeric(18, 8) not null check (gbp_per_unit > 0),
  source     text not null default '',
  primary key (ccy, rate_date)
);

-- Names for the ticker / AMFI code look-up in "+ Add a new investment"
create table public.symbol_directory (
  symbol_kind public.symbol_kind not null,
  symbol      text not null,
  name        text not null,
  region      public.region not null,
  type        public.instrument_type,
  ccy         public.price_ccy,
  amc         text not null default '',
  updated_at  timestamptz not null default now(),
  primary key (symbol_kind, symbol)
);

-- ─────────────────────────── updated_at triggers ───────────────────────────
create trigger profiles_touch     before update on public.profiles     for each row execute function public.touch_updated_at();
create trigger accounts_touch     before update on public.accounts     for each row execute function public.touch_updated_at();
create trigger folios_touch       before update on public.folios       for each row execute function public.touch_updated_at();
create trigger amc_checks_touch   before update on public.amc_checks   for each row execute function public.touch_updated_at();
create trigger instruments_touch  before update on public.instruments  for each row execute function public.touch_updated_at();
create trigger transactions_touch before update on public.transactions for each row execute function public.touch_updated_at();

-- ─────────────────────────── Row Level Security ───────────────────────────
-- Personal tables: owner only (select / insert / update / delete).
do $$
declare t text;
begin
  foreach t in array array['profiles', 'accounts', 'folios', 'amc_checks', 'instruments',
                           'instrument_prices', 'declared_dividends', 'transactions'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('alter table public.%I force row level security', t);
    execute format($p$create policy "%1$s: owner can read"   on public.%1$I for select to authenticated using (user_id = (select auth.uid()))$p$, t);
    execute format($p$create policy "%1$s: owner can add"    on public.%1$I for insert to authenticated with check (user_id = (select auth.uid()))$p$, t);
    execute format($p$create policy "%1$s: owner can change" on public.%1$I for update to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()))$p$, t);
    execute format($p$create policy "%1$s: owner can delete" on public.%1$I for delete to authenticated using (user_id = (select auth.uid()))$p$, t);
  end loop;
end $$;

-- Shared market data: read-only for signed-in users; no write policies, so only the service role can write.
do $$
declare t text;
begin
  foreach t in array array['market_prices', 'fx_rates', 'symbol_directory'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format($p$create policy "%1$s: signed-in users can read" on public.%1$I for select to authenticated using (true)$p$, t);
  end loop;
end $$;

-- No anonymous access at all
revoke all on all tables in schema public from anon;
grant select, insert, update, delete on public.profiles, public.accounts, public.folios, public.amc_checks,
  public.instruments, public.instrument_prices, public.declared_dividends, public.transactions to authenticated;
grant select on public.market_prices, public.fx_rates, public.symbol_directory to authenticated;
grant usage, select on all sequences in schema public to authenticated;

-- ─────────────────────────── Convenience view ───────────────────────────
-- Latest market close per symbol (what the app needs for "current value").
create view public.latest_market_prices with (security_invoker = true) as
  select distinct on (symbol_kind, symbol) symbol_kind, symbol, price_date, close, ccy, source
  from public.market_prices
  order by symbol_kind, symbol, price_date desc;
grant select on public.latest_market_prices to authenticated;

commit;
