# ByWater Backgrounds

Automatically renders branded video-call backgrounds (Zoom, Google Meet, et al.)
for every ByWater employee, for every template, and keeps them in sync with the
team page.

```
templates/        *.svg templates (only the text changes per person)
                  files starting with _ are scaffolds and are never rendered
assets/           bywater_logo.png (shared logo); _flat is the mono recolor source; _white/_black via make logos
lib/ByWater/MeetingBackgrounds.pm   (templating, fingerprints, slug + YAML read helpers)
scripts/          fetch.pl  (stage 1: scrape + write data/people.yaml)
                  render.pl (stage 2: data/people.yaml -> images)
data/             people.yaml — the scraped team data (input to stage 2)
t/                helpers.t, parse.t (run with `make test`)
test/fixtures/    offline HTML for tests + PR preview
staff/            OUTPUT, committed by CI: staff/<Name-Slug>/<template>.png
Makefile          deps / test / parse / fetch / render / all / force / preview / clean
.github/workflows/backgrounds.yml   build + nightly sync
.github/workflows/preview.yml       sample render on pull requests
```

## How it works

Two stages, so scraping and rendering are decoupled (the renderer never touches
the network, and you can hand-edit `data/people.yaml` to re-render without scraping):

**Stage 1 — `scripts/fetch.pl`** (the only networked stage): fetches the team page
(`https://bywatersolutions.com/about-us`), parses each person's **name** (`p.name`)
and **title** (`p.title`), and writes them to **`data/people.yaml`** (sorted by slug).

**Stage 2 — `scripts/render.pl`** (offline): reads `data/people.yaml` and then:

1. **Prunes** `staff/<slug>/` directories for anyone no longer in the YAML.
2. For each **person × template**, renders `staff/<slug>/<template>.png` — but
   **only when something changed**. It fingerprints the filled SVG (template +
   name + title + logo); a background is re-rendered when that fingerprint
   changes (a re-titled person, an edited template, a swapped logo), when the PNG
   is missing, or when `FORCE=1` is set. Unchanged people are skipped.
3. Renders each template at **its own size**: 16:9 templates at **1920×1080** (the
   default Zoom/Teams/Meet size) and the `-original` templates at **1440×1080**
   (4:3, for Zoom's opt-in Original Ratio). Each PNG is kept **under 5 MB** so it
   uploads everywhere (Zoom rejects backgrounds over 5 MB); oversized files are
   optimized with `pngquant` and the run fails if one still won't fit.
4. Writes `staff/manifest.json` listing everyone currently rendered, with the
   per-template fingerprints used to decide what to skip next run.

Rendering shells out to **`rsvg-convert`** (librsvg). See "Why Perl + rsvg" below.

## When it runs (GitHub Actions)

| Trigger | What it covers |
|---|---|
| Push to `templates/**`, `assets/**`, `scripts/**` | A **new or edited template** (or logo/script change) → re-renders everyone affected (fingerprint changed). |
| Nightly cron (`07:00 UTC`) | Someone **added/removed/re-titled** on the website → renders new people, refreshes changed titles, prunes departed ones. |
| Manual (`workflow_dispatch`, optional `force`) | On-demand run; `force: true` re-renders everything regardless of fingerprints. |

The job then commits anything new under `staff/` back to the repo (using the
built-in `GITHUB_TOKEN`, `permissions: contents: write`). The site's WAF blocks
the runner, so the fetch step sends an `x-dev-ops-external-service` header from
the `BWS_DEVOPS_EXTERNAL_SERVICE` secret to get through.

## Gallery (GitHub Pages)

`.github/workflows/pages.yml` publishes a browse-and-download gallery to GitHub
Pages. `scripts/build_gallery.pl` reads `staff/manifest.json` and writes a static
site into `_site/`:

- `index.html` — a light **landing page that's just a filterable list of names**
  (name + title), no images, so it loads instantly.
- `people/<slug>.html` — one page per person with their backgrounds and a download
  link for each. Each name on the landing page links here.

The workflow drops the `staff/` PNGs into `_site/` alongside those pages and deploys.

It runs after each successful render (via `workflow_run`) so the gallery stays in
sync, and on demand via **Run workflow**. To avoid re-uploading the whole site on
no-op nights, it **skips the deploy when nothing changed** — a no-op render makes
no commit, so `HEAD` still matches the last Pages deployment (manual runs always
deploy). First-time setup is done: Pages is enabled with Source **GitHub Actions**.
The gallery is **public** (public repo on the Free plan, where Pages can't be
access-restricted); the underlying names/titles are already public on the team page.

Live at: `https://bywatersolutions.github.io/virtual-meeting-backgrounds-generator/`

## Creating a new template

A template is just one of your finished SVGs with the changing text swapped for
placeholders. **Copy `templates/_starter.svg`** (a documented scaffold) to a
non-underscore name and restyle it — `templates/zoom.svg`, `templates/google-meet.svg`,
etc. Keep these placeholders:

| Placeholder | Replaced with |
|---|---|
| `{{NAME}}` | Person's name, e.g. `Kyle Hall` |
| `{{TITLE}}` | Title as written on the site, e.g. `Lord of the Code` |
| `{{NAME_UPPER}}` | Name uppercased |
| `{{TITLE_UPPER}}` | Title uppercased (used by `waves.svg`) |
| `{{LOGO}}` | `data:` URI of the full-color `assets/bywater_logo.png` — put it in an `href`/`xlink:href` |
| `{{LOGO_WHITE}}` | `data:` URI of the white monochrome logo (for dark backgrounds) |
| `{{LOGO_BLACK}}` | `data:` URI of the black monochrome logo (for light backgrounds) |

Values are XML-escaped automatically, so `&` etc. are safe. Unknown placeholders
are left untouched. The filename (minus `.svg`) becomes the PNG name, so
`templates/dark.svg` → `staff/<person>/dark.png`.

- **Scaffolds**: any template whose name starts with `_` (like `_starter.svg`) is
  never rendered — it's there to copy from.
- **Sizing**: each template renders at the `width`/`height` on its `<svg>` root.
  Design to **1920×1080 (16:9)** — the default Zoom/Teams/Meet size. Keep the
  camera-safe area (your face is usually center / center-right) clear — these
  designs put text top-left and the logo top-right for that reason.
- **Original Ratio (4:3)**: for people who enable Zoom's opt-in Original Ratio,
  ship a 4:3 (**1440×1080**) variant named `<name>-original.svg` (right-align the
  logo to the narrower canvas). Both ratios then render for everyone, e.g.
  `waves.svg` + `waves-original.svg` → `waves.png` + `waves-original.png`.
- **File size**: output PNGs are kept **under 5 MB** (Zoom's limit). Plain vector
  designs are tiny; if you embed a large raster image and the PNG exceeds 5 MB the
  run fails, so simplify it (or raise `MAX_BYTES`).
- **Logo color**: pick the logo treatment that suits your design — `{{LOGO}}` (full
  color), `{{LOGO_WHITE}}` (white, for dark areas), or `{{LOGO_BLACK}}` (black, for
  light areas). The white/black variants are single-color recolors of the **flat**
  logo (`assets/bywater_logo_flat.png`, whose chevrons are transparent so they stay
  clean cut-outs), generated by `make logos` (`scripts/make-mono-logos.pl`, via
  `rsvg-convert`). Rerun `make logos` and commit the results whenever the flat logo
  changes.

Commit the new template on `main` and the workflow renders it for the whole team.

## Running locally

```bash
make deps        # install librsvg2-bin, pngquant, fonts, Mojolicious, YAML::PP
make logos       # regenerate the white/black logo assets from the master logo
make test        # run the test suite (no network needed)
make parse       # scrape the offline fixture and print the people (no rsvg needed)
make fetch       # stage 1: scrape the live site -> data/people.yaml
make render      # stage 2: render anything changed -> staff/
make all         # fetch then render
make force       # re-render everything
make preview     # render the sample person for all templates into ./preview
```

Equivalent raw invocations:

```bash
perl -Ilib scripts/fetch.pl                          # stage 1 -> data/people.yaml
perl -Ilib scripts/render.pl                         # stage 2: render what changed
FORCE=1 perl -Ilib scripts/render.pl                 # re-render all
DRY_RUN=1 ABOUT_URL=test/fixtures/about-us.html perl -Ilib scripts/fetch.pl
OUTPUT_DIR=/tmp/bw perl -Ilib scripts/render.pl      # render into a different dir
```

Stage 1 honors `ABOUT_URL` (http(s), `file://`, or a local path) and `PEOPLE_FILE`
(default `data/people.yaml`). Stage 2 honors `PEOPLE_FILE`, `OUTPUT_DIR` (default
`staff/`), `WIDTH`/`HEIGHT` (optional override; default is the template's own
size), and `MAX_BYTES` (default
`5000000`).

## Tests

`make test` (i.e. `prove -Ilib t/`) runs two suites, no network required:

- **`t/helpers.t`** — slugging, whitespace squishing, XML-escaping,
  `{{placeholder}}` substitution (including that unknown tokens are left intact),
  the change-detection fingerprint (stable, sensitive to title changes,
  unicode-safe), the `needs_render` skip logic, and that `_`-prefixed scaffolds
  are excluded from template discovery.
- **`t/parse.t`** — drives `scripts/fetch.pl` against `test/fixtures/about-us.html`
  end-to-end (scrape → `people.yaml` → `read_people`) and asserts the right
  people/titles come out: title via the following `p.title` sibling, HTML entities
  decoded, whitespace squished, accented slug, decoy `p.title` tags ignored. (Skips
  automatically if `Mojo::DOM` or `YAML::PP` isn't installed.)

The shared helpers live in `lib/ByWater/MeetingBackgrounds.pm` so they can be tested
directly; `Digest::SHA` and `YAML::PP` are loaded lazily, so the pure string helpers
and `perl -c` work even without them installed. The site-specific scraping
(`parse_people`) and YAML writing (`write_people`) live in `scripts/fetch.pl`.

## PR previews

`.github/workflows/preview.yml` runs on pull requests that touch
`templates/`, `assets/`, `scripts/`, or `lib/`. It runs the tests, then renders a
single **synthetic sample person** (`test/fixtures/preview-person.html`) for
every template into `preview/` and uploads it as the **`background-preview`**
artifact, plus drops a PR comment linking to it. Nothing under `staff/` is
touched, so you can review how a template change looks before merging.

## Why Perl + `rsvg-convert`

Per request the logic is in Perl. Perl handles the fetch (`Mojo::UserAgent`),
the CSS-selector parsing (`Mojo::DOM` → `p.name` / `p.title`), templating and
file bookkeeping cleanly. The one thing Perl has no good native library for is
rasterizing SVG, so the script shells out to `rsvg-convert` (librsvg) — a small,
fast, widely-packaged tool. If you'd rather not depend on it, swap the single
`rasterize()` call for Inkscape (`inkscape --export-type=png`) or `resvg`.

## Notes / tweaks

- **Slugs**: names become directory-safe slugs (`Brendan A. Gallagher` →
  `Brendan-A-Gallagher`). Change `slugify()` if you prefer another scheme.
- **Editing a template later**: just commit the change. Each render's fingerprint
  (stored in `staff/manifest.json`) includes the template's content, so editing a
  template re-renders everyone who uses it on the next run — no `force` needed.
  Use `force: true` only to rebuild everything regardless.
- **Fonts**: CI installs `fonts-liberation` so `Helvetica/Arial` in the SVGs
  render with correct metrics. Add other font packages if a template needs them.
