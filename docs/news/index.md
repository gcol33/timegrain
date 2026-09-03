# Changelog

## timegrain 0.2.0

The binning and the reduction are now one implementation,
`src/tg_core.cpp` and `src/tg_calendar.cpp`, compiled into the R package
by R itself and into the Python extension by CMake. The two languages
agree by construction rather than by two implementations being checked
against each other after the fact. What each side keeps above it is the
boundary: resolving the columns, resolving the zone, and wrapping the
result.

Four bugs that existed twice, once per language, are closed by that
([\#1](https://github.com/gcol33/timegrain/issues/1),
[\#2](https://github.com/gcol33/timegrain/issues/2),
[\#4](https://github.com/gcol33/timegrain/issues/4),
[\#5](https://github.com/gcol33/timegrain/issues/5)), and a fifth on the
Python side with them
([\#3](https://github.com/gcol33/timegrain/issues/3)).

### The calendar

- Bin starts are computed by proleptic Gregorian arithmetic on local
  time rather than by writing a local midnight and parsing it back. A
  zone that moves its clock at midnight, such as `America/Sao_Paulo`
  before 2019, no longer produces `NA` bin starts and a failure from
  inside the reduction, and a `year_start` landing on such a night is an
  argument rather than an error
  ([\#1](https://github.com/gcol33/timegrain/issues/1)).
- A bin start is a local time, so reporting it as an instant now has a
  stated rule: one the clock skipped resolves to the instant the clock
  jumped to, one the clock repeated to the first of the two.
- [`window_matrix()`](https://gillescolling.com/timegrain/reference/window_matrix.md)
  in Python takes a `tz` argument. The same instants and the same zone
  now give the same answer in both languages, and the fixtures pin it
  rather than leaving it assumed
  ([\#5](https://github.com/gcol33/timegrain/issues/5)).
- Instants are read at whole seconds in both languages, so two readings
  a fraction of a second apart are the same reading twice.

### Guards

- Consecutive bin starts must be one bin apart on the window’s own
  calendar. A bin no unit reaches is never built, so a month missing
  from the whole record used to pass as four adjacent monthly bins with
  one gone, in both languages
  ([\#4](https://github.com/gcol33/timegrain/issues/4)). Not asserted
  for `hour`, whose bin is the reading itself, nor for a supplied
  calendar, which declares its own bin lengths.
- A day-level statistic requires every calendar day to lie inside one
  bin, decided from the bins rather than from the window’s name. A
  supplied calendar cutting inside a day used to give a mostly-`NA`
  array in R and a numpy `IndexError` in Python
  ([\#2](https://github.com/gcol33/timegrain/issues/2)).
- Python no longer rejects a unit called `nan` and no longer misses a
  genuinely missing id
  ([\#3](https://github.com/gcol33/timegrain/issues/3)).

### Evidence

- The pure-R and pure-NumPy implementations are kept as test oracles,
  `tests/testthat/helper-oracle.R` and `python/tests/oracle.py`. Neither
  package reaches them at runtime; both suites check them against the
  core on the fixtures and on random series. The NumPy one was written
  from `inst/spec/representation.md` rather than from the R source,
  which is what makes it evidence that the document is complete.
- A third fixture series and a `tz` column in `digests.csv`: every
  window of the aligned series read as a `Europe/Vienna` clock, and a
  short series across the night `America/Sao_Paulo` moved its clock at
  midnight.

### The two languages

The names, the defaults and the extension points had drifted, so a
script moved from one side to the other met them one at a time
([\#8](https://github.com/gcol33/timegrain/issues/8)). One name per
concept now, and where the two still differ the difference is a row in
`inst/spec/representation.md` rather than something to be discovered at
a call site.

- `glmnet_learner()` is
  [`elasticnet_learner()`](https://gillescolling.com/timegrain/reference/elasticnet_learner.md),
  and its `nfolds` is `n_inner`. The name says which model is fitted
  rather than which package fits it, which is also what the Python side
  already called it. It is registered as `"elasticnet"`.
- Python carries the response and metric registries, so on both sides
  the response head and the metric are registry entries and the fitting
  path holds no list of names.
  [`learners()`](https://gillescolling.com/timegrain/reference/register_learner.md),
  [`metrics()`](https://gillescolling.com/timegrain/reference/register_metric.md)
  and
  [`responses()`](https://gillescolling.com/timegrain/reference/register_response.md)
  list what a session has, in C collation.
- [`stepwise_learner()`](https://gillescolling.com/timegrain/reference/stepwise_learner.md)
  and
  [`select_grain()`](https://gillescolling.com/timegrain/reference/select_grain.md)
  are on the Python side. The selector’s orthogonal polynomial basis and
  its logistic fits agree with R’s
  [`poly()`](https://rdrr.io/r/stats/poly.html) and
  [`glm()`](https://rdrr.io/r/stats/glm.html) to twelve decimals on the
  same design; the selection procedure is the same nested one, reporting
  its estimate under every registered metric.
- Python’s
  [`window_matrix()`](https://gillescolling.com/timegrain/reference/window_matrix.md)
  returns one representation when one window is named, whether as a
  string or as a sequence of one, and a
  [`timegrain_set()`](https://gillescolling.com/timegrain/reference/timegrain_set.md)
  for two or more. Its fold map carries the units it was drawn for, so
  aligning one is by name there as it already was in R.
- The torch encoders take `swa` and `swa_start` on both sides, and both
  refuse a setting the learner does not have rather than ignoring it. A
  misspelled argument used to be dropped in silence.
- [`select_grain()`](https://gillescolling.com/timegrain/reference/select_grain.md)
  searches its candidates in the order they were declared. It read them
  off a join on the names before, which is the collation the rest of the
  package stopped depending on in this version, so an exact tie on the
  inner score could fall to a different candidate on a different
  machine.

### Build

- `LinkingTo: cpp11`, and flat `.cpp` under `src/`, so R compiles the
  core with no `Makevars`.
- `pyproject.toml` and `CMakeLists.txt` sit at the repository root
  rather than under `python/`, because a Python source distribution
  cannot reach above its own project directory and the shared sources
  must not be vendored into a second copy. The Python build is
  scikit-build-core and nanobind; the wheel carries `python/timegrain`
  as `timegrain`.
- The wheel depends on `tzdata` on Windows, which ships no IANA database
  of its own, so a zoned record bins there as it does everywhere else.
  The `sklearn` extra asks for a version that the declared floor of
  Python 3.10 can install.
- `R-CMD-check`, `pytest` and `contract` run on push and on pull
  requests, the last of them running both fixture suites against one
  `inst/spec/fixtures/` in a single job.

### Documentation

- One site for both languages at <https://gillescolling.com/timegrain/>:
  the R reference from the Rd files, the Python reference written from
  the Python sources by `tools/python_reference.py`, and
  `inst/spec/representation.md` rendered as a page of its own, so the
  document the two answer to is read where the calls are. The `pytest`
  workflow rewrites the Python pages and fails if what is on disk
  differs, so a docstring cannot change without the page changing with
  it.
- Every public class, method and property of the Python package carries
  a docstring.

## timegrain 0.1.0

First release. The package builds the representation, fits at every
grain, and reports where predictive skill saturates.

### Representation

- [`window_matrix()`](https://gillescolling.com/timegrain/reference/window_matrix.md):
  reduces a long table of sensor readings to a `[unit, bin, channel]`
  array at one of seven temporal grains, from the unreduced record to a
  single value per hydrological year. Naming several windows returns one
  representation per window; passing a function bins by a calendar the
  package does not carry, such as seasons cut at the equinoxes.
- Bins follow the calendar, so a month is 28, 30 or 31 days and a week
  starts on a Monday, and every `(unit, bin)` cell is asserted to hold
  readings.
- A bin the record does not cover for its whole calendar span is
  reported on `bin_partial` and kept or removed by the `partial`
  argument, so a record that begins away from a bin boundary says so
  rather than carrying a short bin that looks like any other.
- Seven statistics: `mean`, `min`, `max`, the day-level `cold_day` and
  `warm_day`, which reduce each day to its own mean before taking the
  extreme over days, and `mean_daily_min` and `mean_daily_max`, which
  take the mean of the daily extremes.
- [`calendar_channels()`](https://gillescolling.com/timegrain/reference/calendar_channels.md)
  and
  [`bind_channels()`](https://gillescolling.com/timegrain/reference/bind_channels.md)
  supply the position of each bin in the year to an encoder that would
  otherwise pool it away.
- [`feature_matrix()`](https://gillescolling.com/timegrain/reference/feature_matrix.md)
  brings an already-reduced feature table in as an arm of the same
  ladder.
- Gaps, duplicated `(unit, time)` pairs and missing values are errors
  rather than silent padding.

### Fitting and scoring

- [`fold_map()`](https://gillescolling.com/timegrain/reference/fold_map.md)
  and
  [`scorable_cells()`](https://gillescolling.com/timegrain/reference/scorable_cells.md):
  one split read by everything that scores, and the mask of cells a
  score is defined on, computed from the response and the fold map with
  no model involved, so every arm shares one denominator and every
  paired difference runs on matched cells.
- [`window_ladder()`](https://gillescolling.com/timegrain/reference/window_ladder.md)
  fits every learner at every grain,
  [`plot()`](https://rdrr.io/r/graphics/plot.default.html) draws the
  curve, and
  [`paired_contrast()`](https://gillescolling.com/timegrain/reference/paired_contrast.md)
  compares two arms inside each cell both scored.
- [`bin_occlusion()`](https://gillescolling.com/timegrain/reference/bin_occlusion.md)
  holds each bin of the record back and rescores, without refitting, so
  a fitted model says which part of the year its skill rests on.
- [`window_contrasts()`](https://gillescolling.com/timegrain/reference/window_contrasts.md)
  fits `score ~ window + (1 | variable) + (1 | fold)` and compares every
  window against a learner’s best by Dunnett’s procedure. Needs `lme4`,
  `lmerTest` and `emmeans`.
- [`tss()`](https://gillescolling.com/timegrain/reference/tss.md),
  [`roc_auc()`](https://gillescolling.com/timegrain/reference/roc_auc.md),
  [`kappa_score()`](https://gillescolling.com/timegrain/reference/kappa_score.md),
  [`model_agreement()`](https://gillescolling.com/timegrain/reference/kappa_score.md)
  and
  [`decision_threshold()`](https://gillescolling.com/timegrain/reference/kappa_score.md).
- [`tss_inflation()`](https://gillescolling.com/timegrain/reference/tss_inflation.md)
  measures how much a self-selected threshold inflates a reported level
  at the user’s own presence counts, and
  [`implied_skill()`](https://gillescolling.com/timegrain/reference/implied_skill.md)
  inverts that map to say what population skill a level actually read is
  consistent with.

### Learners

- [`elasticnet_learner()`](https://gillescolling.com/timegrain/reference/elasticnet_learner.md)
  and
  [`stepwise_learner()`](https://gillescolling.com/timegrain/reference/stepwise_learner.md)
  on the flattened representation, both redoing their selection inside
  whichever units they are handed.
- [`mlp_learner()`](https://gillescolling.com/timegrain/reference/torch_learners.md),
  [`cnn_learner()`](https://gillescolling.com/timegrain/reference/torch_learners.md)
  and
  [`rescnn_learner()`](https://gillescolling.com/timegrain/reference/torch_learners.md),
  joint multi-label encoders on `torch`, sharing one training recipe.
- [`ensemble_learner()`](https://gillescolling.com/timegrain/reference/ensemble_learner.md)
  averages several members’ predicted probabilities before the threshold
  is chosen, and the torch learners take `swa = TRUE` to average the
  weights of their tail epochs.
- [`learner()`](https://gillescolling.com/timegrain/reference/learner.md)
  takes a fit and a predict pair of your own;
  [`register_learner()`](https://gillescolling.com/timegrain/reference/register_learner.md),
  [`register_response()`](https://gillescolling.com/timegrain/reference/register_response.md)
  and
  [`register_metric()`](https://gillescolling.com/timegrain/reference/register_metric.md)
  extend the three registries the fitting path reads.

### Reproducing the study

- `inst/reproduce/schrankogel.R` runs the published grid from the Zenodo
  deposit it was built on, asserting the plot count, the species count,
  the cell count and the bin count of every window before fitting
  anything. See
  [`vignette("reproducing-schrankogel")`](https://gillescolling.com/timegrain/articles/reproducing-schrankogel.md).

### The cross-language contract

- `inst/spec/representation.md` is normative for both the R and the
  Python implementation.
- `inst/spec/fixtures/` carries a synthetic series and the digest of
  every window-by-statistic combination; both test suites assert against
  the same digests.
- The Python side implements the representation, the folds, the mask,
  the metrics, the ladder and the same three encoders.
