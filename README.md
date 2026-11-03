# Financial Investment Personal Dashboard

UK and Indian investments in one dashboard: holdings, dividends, transactions, weekly history, ISA allowances and residual cash, India NRE/NRO and AMC Console.

**Status:** prototype. Data is kept in the browser that opens the page (localStorage), per person and per device. Use *Prices & data → Export to Excel* for backups. The Supabase version (sign-in, shared across devices) is the next phase — see `supabase/`.

## Files
- `index.html` — the whole app (HTML, CSS, JS in one file). Chart.js and SheetJS load from cdnjs; fonts from Google Fonts.
- `lookup/stocks.json`, `lookup/amfi.json` — ticker / AMFI code → name lists for "+ Add a new investment".
- `.nojekyll` — tells GitHub Pages to serve the files as they are.

## Publish on GitHub Pages
Settings → Pages → Build and deployment → Source: *Deploy from a branch* → Branch: `main`, folder `/ (root)` → Save. The site appears at `https://<user>.github.io/<repo>/` after a minute or two.
