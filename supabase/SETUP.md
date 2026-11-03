# Supabase setup — Financial Investment Personal Dashboard

Schema file: `supabase/migrations/20261103120000_initial_schema.sql` (tested 3 Nov 2026 on Postgres 16 with a stand-in for Supabase auth: migration runs clean, the full sample portfolio — 6 accounts, 16 investments, 323 transactions — loads, ISA residual cash and 2026-27 payments computed in SQL match the app: £5,223.45 and £7,000).

## 1. Create the project (once)
1. supabase.com → New project. Name: `investment-dashboard`. Region: **London (eu-west-2)**. Choose a strong database password and keep it in your password manager.
2. Free plan is enough for 5 users. Note: free projects pause after about a week with no activity; any sign-in wakes them.

## 2. Create the tables
1. Project → **SQL Editor** → New query.
2. Paste the whole schema file → **Run**. It finishes with "Success. No rows returned".
3. Check **Table Editor**: 11 tables (profiles, accounts, folios, amc_checks, instruments, instrument_prices, declared_dividends, transactions, market_prices, fx_rates, symbol_directory) and a padlock (RLS on) on each.

## 3. Sign-in: invite-only for 5 people
1. **Authentication → Sign In / Providers → Email**: enabled. Turn **Allow new users to sign up** OFF.
2. **Authentication → URL Configuration**: Site URL = the GitHub Pages address of the app (e.g. `https://ssubcbe.github.io/investment-dashboard/`); add the same under Redirect URLs.
3. **Authentication → Users → Invite user**: send an invite to each of the 5 email addresses. Each person sets a password from the email; a profile row is created automatically.
4. Optional: Authentication → Multi-factor → enable TOTP.

## 4. Keys
- **Project URL** and **anon / publishable key** (Project Settings → API): go into the web app. Safe to publish — every table is protected by RLS and the anon role has no table access.
- **service_role / secret key**: never in the web app or GitHub. Only as a secret for the nightly price job (Edge Function).

## What the database enforces
- Each person sees and changes only their own rows (RLS on every personal table). Rows always reference the same person's account / investment / folio (composite keys).
- Shared market data (prices, NAVs, FX, ticker/AMFI names) is read-only for users; only the price job (service role) writes it.
- Same rules as the app: Cash entries only in a Stocks & Shares ISA; account and investment in the same country; transfers stay in one country; account types per country; AMFI codes are 5–6 digits; each transaction type has the fields it needs; an account with transactions can't be deleted.

## Next phases
1. **App ↔ database**: move the prototype to GitHub Pages, add sign-in, read/write these tables instead of browser storage; one-click import of the current Excel/backup file.
2. **Nightly prices**: Supabase Edge Function on a schedule — AMFI NAVs for Indian funds, exchange closes for ETFs/shares, FX rates; fills `market_prices`, `fx_rates`, `symbol_directory`.
