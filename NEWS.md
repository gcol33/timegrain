# timegrain 0.2.0

The binning and the reduction are now one implementation, `src/tg_core.cpp` and
`src/tg_calendar.cpp`, compiled into the R package by R itself and into the Python extension by
CMake. The two languages agree by construction rather than by two implementations being checked
against each other after the fact. What each side keeps above it is the boundary: resolving the
columns, resolving the zone, and wrapping the result.

Four bugs that existed twice, once per language, are closed by that (#1, #2, #4, #5), and a fifth
on the Python side with them (#3).

## The calendar

* Bin starts are computed by proleptic Gregorian arithmetic on local time rather than by writing a
  local midnight and parsing it back. A zone that moves its clock at midnight, such as
  `America/Sao_Paulo` before 2019, no longer produces `NA` bin starts and a failure from inside the
  reduction, and a `year_start` landing on such a night is an argument rather than an error (#1).
* A bin start is a local time, so reporting it as an instant now has a stated rule: one the clock
  skipped resolves to the instant the clock jumped to, one the clock repeated to the first of the
  two.
* `window_matrix()` in Python takes a `tz` argument. The same instants and the same zone now give
  the same answer in both languages, and the fixtures pin it rather than leaving it assumed (#5).
* Instants are read at whole seconds in both languages, so two readings a fraction of a second
  apart are the same reading twice.

## Guards

* Consecutive bin starts must be one bin apart on the window's own calendar. A bin no unit reaches
  is never built, so a month missing from the whole record used to pass as four adjacent monthly
  bins with one gone, in both languages (#4). Not asserted for `hour`, whose bin is the reading
  itself, nor for a supplied calendar, which declares its own bin lengths.
* A day-level statistic requires every calendar day to lie inside one bin, decided from the bins
  rather than from the window's name. A supplied calendar cutting inside a day used to give a
  mostly-`NA` array in R and a numpy `IndexError` in Python (#2).
* Python no longer rejects a unit called `nan` and no longer misses a genuinely missing id (#3).

## Evidence

* The pure-R and pure-NumPy implementations are kept as test oracles,
  `tests/testthat/helper-oracle.R` and `python/tests/oracle.py`. Neither package reaches them at
  runtime; both suites check them against the core on the fixtures and on random series. The NumPy
  one was written from `inst/spec/representation.md` rather than from the R source, which is what
  makes it evidence that the document is complete.
* A third fixture series and a `tz` column in `digests.csv`: every window of the aligned series
  read as a `Europe/Vienna` clock, and a short series across the night `America/Sao_Paulo` moved
  its clock at midnight.

## Build

* `LinkingTo: cpp11`, and flat `.cpp` under `src/`, so R compiles the core with no `Makevars`.
* `pyproject.toml` and `CMakeLists.txt` sit at the repository root rather than under `python/`,
  because a Python source distribution cannot reach above its own project directory and the shared
  sources must not be vendored into a second copy. The Python build is scikit-build-core and
  nanobind; the wheel carries `python/timegrain` as `timegrain`.

# timegrain 0.1.0

First release. The package builds the representation, fits at every grain, and reports where
predictive skill saturates.

## Representation

* `window_matrix()`: reduces a long table of sensor readings to a `[unit, bin, channel]` array at
  one of seven temporal grains, from the unreduced record to a single value per hydrological year.
  Naming several windows returns one representation per window; passing a function bins by a
  calendar the package does not carry, such as seasons cut at the equinoxes.
* Bins follow the calendar, so a month is 28, 30 or 31 days and a week starts on a Monday, and
  every `(unit, bin)` cell is asserted to hold readings.
* A bin the record does not cover for its whole calendar span is reported on `bin_partial` and
  kept or removed by the `partial` argument, so a record that begins away from a bin boundary
  says so rather than carrying a short bin that looks like any other.
* Seven statistics: `mean`, `min`, `max`, the day-level `cold_day` and `warm_day`, which reduce
  each day to its own mean before taking the extreme over days, and `mean_daily_min` and
  `mean_daily_max`, which take the mean of the daily extremes.
* `calendar_channels()` and `bind_channels()` supply the position of each bin in the year to an
  encoder that would otherwise pool it away.
* `feature_matrix()` brings an already-reduced feature table in as an arm of the same ladder.
* Gaps, duplicated `(unit, time)` pairs and missing values are errors rather than silent padding.

## Fitting and scoring

* `fold_map()` and `scorable_cells()`: one split read by everything that scores, and the mask of
  cells a score is defined on, computed from the response and the fold map with no model involved,
  so every arm shares one denominator and every paired difference runs on matched cells.
* `window_ladder()` fits every learner at every grain, `plot()` draws the curve, and
  `paired_contrast()` compares two arms inside each cell both scored.
* `bin_occlusion()` holds each bin of the record back and rescores, without refitting, so a fitted
  model says which part of the year its skill rests on.
* `window_contrasts()` fits `score ~ window + (1 | variable) + (1 | fold)` and compares every
  window against a learner's best by Dunnett's procedure. Needs `lme4`, `lmerTest` and `emmeans`.
* `tss()`, `roc_auc()`, `kappa_score()`, `model_agreement()` and `decision_threshold()`.
* `tss_inflation()` measures how much a self-selected threshold inflates a reported level at the
  user's own presence counts, and `implied_skill()` inverts that map to say what population skill
  a level actually read is consistent with.

## Learners

* `glmnet_learner()` and `stepwise_learner()` on the flattened representation, both redoing their
  selection inside whichever units they are handed.
* `mlp_learner()`, `cnn_learner()` and `rescnn_learner()`, joint multi-label encoders on `torch`,
  sharing one training recipe.
* `ensemble_learner()` averages several members' predicted probabilities before the threshold is
  chosen, and the torch learners take `swa = TRUE` to average the weights of their tail epochs.
* `learner()` takes a fit and a predict pair of your own; `register_learner()`,
  `register_response()` and `register_metric()` extend the three registries the fitting path reads.

## Reproducing the study

* `inst/reproduce/schrankogel.R` runs the published grid from the Zenodo deposit it was built on,
  asserting the plot count, the species count, the cell count and the bin count of every window
  before fitting anything. See `vignette("reproducing-schrankogel")`.

## The cross-language contract

* `inst/spec/representation.md` is normative for both the R and the Python implementation.
* `inst/spec/fixtures/` carries a synthetic series and the digest of every window-by-statistic
  combination; both test suites assert against the same digests.
* The Python side implements the representation, the folds, the mask, the metrics, the ladder and
  the same three encoders.
