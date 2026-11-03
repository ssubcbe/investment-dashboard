# Financial Investment Personal Dashboard

UK and Indian investments in one dashboard: holdings, dividends, transactions, weekly history, ISA allowances and residual cash, India NRE/NRO and AMC Console.

## Two modes
- **Signed-in (Supabase)** — when `SUPABASE_URL` and `SUPABASE_KEY` are filled in near the top of the script in `index.html` (search for `const SUPABASE_URL`). Invite-only sign-in; each person's data is saved to Supabase and is private to them (Row Level Security).
- **Prototype** — if those two lines are left empty: data stays in the browser (localStorage) with a sample portfolio.

`SUPABASE_KEY` must be the **anon / publishable** key (safe in a public page). Never put the service_role / secret key here.

## Files
- `index.html` — the whole app (HTML, CSS, JS in one file). Loads Chart.js and SheetJS from cdnjs, supabase-js 2.117.3 from jsDelivr (signed-in mode only), fonts from Google Fonts.
- `lookup/stocks.json`, `lookup/amfi.json` — ticker / AMFI code → name lists for "+ Add a new investment".
- `supabase/` — database schema (`migrations/…initial_schema.sql`) and `SETUP.md`.
- `.nojekyll` — serve files as they are.

## Publish on GitHub Pages
Settings → Pages → Deploy from a branch → `main` / `(root)` → Save.
