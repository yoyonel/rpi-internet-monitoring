# ES Module Split — Performance Regression & Fix

## Context

PR #31 (`refactor/extract-lib-js`) extracted pure computation functions from
the monolithic `app.js` into a separate `lib.js` ES module. The HTML template
was updated from `<script defer>` to `<script type="module">` and `app.js` now
imports from `./lib.js`.

After deployment on the Surge preview, the Lighthouse audit reported a
**Desktop performance drop from 98 → 75** (a 23-point regression).

| Category    | PR #24 (before) | PR #31 (no fix) |
| ----------- | --------------: | --------------: |
| Performance |          98 (D) |          75 (D) |
| Performance |          76 (M) |          88 (M) |

Mobile scores were noisy (76 → 88) due to Surge CDN variability, but the
Desktop drop was consistent and significant.

## Root Cause

### ES Module Waterfall

With `<script defer>`, the browser fetches and executes `app.js` in a single
network round-trip. With `<script type="module">`:

1. Browser fetches `app.js`
2. Parses it, discovers `import { ... } from './lib.js'`
3. **Only then** fetches `lib.js` (second round-trip)
4. Parses and executes both

This creates a **sequential waterfall**: the second fetch cannot start until
the first file is fully downloaded and parsed. On localhost (latency ≈ 0 ms)
this is invisible. On Surge CDN (latency ~50–100 ms per request), it adds
100–200 ms to the critical path, heavily penalizing Time to Interactive and
Total Blocking Time.

### Missing file in preview-pr.yml

A secondary issue: the `preview-pr.yml` workflow did not copy `lib.js` to the
Surge deploy directory. The initial CI run failed entirely (E2E timeout) because
`app.js` could not import `lib.js` at all.

## Fix

### 1. `modulepreload` hint (index.template.html)

```html
<link rel="modulepreload" href="lib.js" />
```

Added alongside the existing `<link rel="preload">` directives. This tells the
browser to fetch, parse, and compile `lib.js` **immediately** — in parallel
with `app.js` — without waiting for the import statement to be discovered.

The browser's module preload eliminates the waterfall:

- **Before**: `app.js` → parse → discover import → `lib.js` → parse → execute
- **After**: `app.js` ∥ `lib.js` (parallel fetch) → parse both → execute

### 2. Copy lib.js in preview-pr.yml

```yaml
cp gh-pages/style.css gh-pages/app.js gh-pages/lib.js _surge_deploy/
```

Added `gh-pages/lib.js` to the Surge deploy copy step. This is the 5th
location in the build pipeline that must include `lib.js` (the other 4 —
`publish-gh-pages.sh`, `publish-template.sh`, `preview-dev.sh`, and
`deploy-gh-pages.yml` — were already updated in the initial PR commits).

## Results

| Category | PR #24 (before) | PR #31 (no fix) | PR #31 (with fix) |
| -------- | --------------: | --------------: | ----------------: |
| Desktop  |              98 |              75 |            **97** |
| Mobile   |              76 |              88 |            **84** |

Desktop recovered from 75 → 97 (within 1 point of baseline — normal Lighthouse
variance on Surge). Mobile scores remain noisy across runs.

Local Lighthouse audits confirmed no regression:

| Preset  | Before fix | After fix |
| ------- | ---------: | --------: |
| Desktop |        100 |       100 |
| Mobile  |         81 |        79 |

(Local scores are higher because localhost has zero network latency.)

## Lessons Learned

1. **ES module splits require `modulepreload`** — any time a module is split
   into sub-modules, add `<link rel="modulepreload">` for each dependency to
   avoid waterfall penalties on production CDNs.

2. **Build pipeline has 5 copy points** — when adding/renaming files in
   `gh-pages/`, all must be updated:
   - `scripts/publish-gh-pages.sh`
   - `scripts/publish-template.sh`
   - `scripts/preview-dev.sh`
   - `.github/workflows/deploy-gh-pages.yml`
   - `.github/workflows/preview-pr.yml`

3. **Local Lighthouse ≠ CDN Lighthouse** — always verify performance on the
   actual deployment target. Localhost hides network-dependent regressions.
