# timegrain

Temporal-grain selection for ecological prediction from sensor time series. Flagship application:
species modelling from microclimate loggers.

A logger records every hour for years. Before any model is fitted, that record is reduced: to
monthly means, to growing-degree-days, to whatever the analyst decides. `timegrain` makes that
reduction an explicit, testable choice rather than a preprocessing step nobody revisits. It builds
the representation at any temporal grain, fits models at each grain, and shows where predictive
skill saturates.

## Why it exists

From the Schrankogel study (`~/Documents/code/schrankogel-cnn-2026`, paper at
`~/Documents/writing/papers/paper_schrankogel_cnn_2026`), on 894 alpine plots, 101 species,
three years of hourly soil temperature:

- The full hourly series is the best input for none of three architectures. Reading every hour
  cost the convolutional network 0.048 TSS against its own best grain.
- Skill peaks at the weekly average and falls from monthly on (-0.080 at yearly).
- A window's coldest and warmest **day** carry more than its mean, and increasingly so as the
  window widens (+0.006 weekly to +0.046 yearly). They need daily values, so daily storage is the
  floor.
- A fully connected network on the same series is level with a penalised logistic model on 188
  hand-built features (-0.002 TSS, p = 0.63). The gain comes from convolution reading the series at
  a coarse grain, not from the model being a network.

The package is what lets someone else run that test on their own loggers.

## Positioning

Ecology and species modelling give the package its identity and audience; they are not a boundary
in its name. `sdmgrain` was rejected: it claims spatial distribution modelling the method does not
do, and in SDM writing "grain" reads as raster resolution, which is the opposite of the novelty.
`thermogram` was rejected: it narrows on the input, where the code has no specialisation at all.

The real specialisation is presence-absence with rare species, and it lives above the
representation layer, not in the name.

## Layout

The R package sits at the repository root so every CRAN and pkgdown convention works unmodified.
`python/` is in `.Rbuildignore`. The contract ships with the package under
`inst/spec/`, so the test that asserts its digests runs on an installed copy rather
than only in the source tree.

`pyproject.toml` and `CMakeLists.txt` sit at the root too, and are in `.Rbuildignore`. That is not
tidiness: a Python source distribution cannot reach above its own project directory, so a
`python/pyproject.toml` would have to carry a vendored copy of `src/` and a CI job asserting the
copy still matched. The project directory is the repository, and there is one copy of the sources.

```
timegrain/
  src/                the shared core, compiled into both languages
    tg_core.h tg_calendar.cpp tg_core.cpp
    tg_r.cpp          the cpp11 wrapper; cpp11.cpp is generated
  R/                  R package source
  tests/testthat/     including helper-oracle.R, the pure-R implementation
  man/ vignettes/
  DESCRIPTION NAMESPACE
  CMakeLists.txt pyproject.toml
  inst/
    spec/             the contract both implementations obey
      representation.md
      fixtures/       small input + expected digests, read by both test suites
    reproduce/        the driver that runs the published grid from the Zenodo deposit
  python/             the Python twin
    tg_py.cpp         the nanobind wrapper
    timegrain/
    tests/            including oracle.py, the pure-NumPy implementation
```

Same name on CRAN and PyPI (both verified free 2026-09-02).

## The contract between the two languages

`window_matrix()` in R and `window_matrix()` in Python must return the **same numbers** for the
same input. This is not a nicety: the whole claim of the package is that the grain is what matters,
so two implementations that bin differently would make the tool the confound.

`inst/spec/representation.md` is the normative description. `inst/spec/fixtures/` holds a small input series
and the digests of every window-by-statistic combination. Both test suites read those fixtures and
assert against the same digests. A change to binning that is not reflected in the fixtures is a bug
in whichever language changed.

Models cannot be byte-identical across torch and libtorch and are not required to be.

## API

```r
x   <- window_matrix(readings, id = plot, time = t, value = temp,
                     window = "week", stats = c("cold_day", "mean", "warm_day"))
lad <- window_ladder(x, y, learners = list(mlp(), cnn(), glmnet_learner()))
plot(lad)
fit <- fit_learner(cnn(), x, y)
```

`window_matrix()` returns a numeric array `[id, bin, channel]` with dimnames and the binning
recorded in attributes. It knows nothing about species, or about what the response is.

### Statistic vocabulary

The distinction between an extreme reading and an extreme day is the subtle part, and mixing them
up silently changes the result, so the names keep them apart:

| name | meaning |
|---|---|
| `mean` | mean of the readings in the window |
| `min`, `max` | coldest and warmest single reading in the window |
| `cold_day`, `warm_day` | coldest and warmest day, each day first reduced to its own mean |
| `mean_daily_min`, `mean_daily_max` | the bin's average daily minimum and maximum, each day first reduced to its own extreme |

The four day-level statistics are defined only for windows of a day or coarser. The reported input
in the paper is `c("cold_day", "mean", "warm_day")` at the weekly window.

### Windows

`hour`, `halfday`, `day`, `week`, `month`, `season`, `year`. The four coarse windows follow the
calendar rather than a fixed count of hours, so a bin is a real month or a real week rather than a
drifting block of 730 or 168 hours. `year_start` sets the hydrological-year boundary (default
`"09-01"`, the convention in the source dataset).

A calendar the package does not carry is passed as a function of the reading instants returning
each reading's bin start. That is how the deposit's astronomical seasons, cut at the equinoxes and
solstices rather than on the first of a month, bin like any named window.

## Design rules

- **The response head and the metric are registered, not hard-coded.** Presence-absence with a
  joint multi-label head and TSS is the shipped default and the vignette, but adding an abundance
  or phenology response is one registration, never a fork of the fitting code. Same for learners:
  `mlp_learner()`, `cnn_learner()`, `rescnn_learner()` and any user-supplied fit/predict pair go
  through one interface.
- **The representation layer is one implementation, in C++, compiled into both languages.** The
  calendar binning, the statistics, the array assembly and every guard live in `src/`, take naive
  local seconds and know nothing of a zone, a locale or tzdata. Each language resolves the columns
  and the zone above it and wraps the result below it, and that is all either holds. A calendar bug
  fixed in one place is fixed in both, which is the whole reason it is there: the four it replaced
  each existed twice.
- **The pure-R and pure-NumPy implementations are kept as test oracles**, never reachable at
  runtime. The NumPy one was written from the spec rather than from the R source, so it is the
  evidence that the spec is complete; one shared binary would otherwise make the agreement between
  the languages trivially true.
- **No dependency for the representation.** `cpp11` is header-only and `LinkingTo`; nanobind is a
  build dependency of the wheel. Nothing is added at runtime on either side.
- **No primary-plus-fallback paths.** A learner that needs `torch` declares it and errors without
  it. Two code paths diverge.
- **The scorable-cell mask is computed from the response and the fold map alone**, with no model
  involved, so every learner in a ladder is scored on the same cells and every paired comparison
  runs on matched cells.

## What ships, and what it warns about

TSS read at the threshold that maximises it is inflated where presences are thin: the Schrankogel
simulation puts the inflation at +0.110 when the true skill is 0.60, generated in cells holding one
or two presences. Most SDM code carries that silently. `timegrain` reports the score and the
expected inflation for the user's own presence counts. That is a reason to switch that has nothing
to do with neural networks.

## Status

Version 0.2.0, 2026-09-03. Not on CRAN or PyPI yet.

The build order is done on both sides: the representation and the fixtures, the fold map and the
scorable-cell mask, the ladder and its plot, the learner registry, the torch learners, and above
them the paired contrast, the mixed-model window contrast, the occlusion profile and the inflation
of a self-selected threshold. The Python side carries the same except the mixed model, and
reproduces every one of the 166 fixture digests, sixteen of which pin a zone.

Since 0.2.0 both sides run on one C++ core (issue #10), and the implementations that used to be
compared are kept as oracles the suites check the core against.

`inst/reproduce/schrankogel.R` runs the published grid from the deposit and asserts its input at
every step. Verified against the deposit on 2026-09-02, matching the paper exactly:

| quantity | reported | reproduced |
|---|---|---|
| plots, species, rarest species | 894, 101, 26 | same |
| scorable cells | 1003 of 1010 | same |
| bins per window | 26304, 2192, 1096, 157, 36, 13, 3 | same |
| numbers per plot, weekly three-channel | 471 | same |
| numbers per plot, daily three-channel | 3288 | same |
| inflation at truth 0.60, 0.70, 0.90 | +0.110, +0.095, +0.051 | same |
| elastic net on the 188 aggregates | 0.687 | 0.686 |

The elastic net sits 0.001 low because the two runs seed the inner cross-validation's random fold
draw differently; nothing else in the table carries randomness. The stepwise arm and the network
grid have not been rerun here: forward selection over 188 columns is many hours single-threaded,
and the encoders want the graphics processor they had in the study.

## Related

- Study code: `gcol33/schrankogel-cnn-2026` (private)
- Paper: `~/Documents/writing/papers/paper_schrankogel_cnn_2026`, target Methods in Ecology and
  Evolution as a Methods article with this package as the companion software
- Collaboration notes: `~/Documents/TaskGoblin/colabs/schrankogel-cnn/`
