# timegrain

[![R-CMD-check](https://github.com/gcol33/timegrain/actions/workflows/R-CMD-check.yaml/badge.svg)](https://github.com/gcol33/timegrain/actions/workflows/R-CMD-check.yaml)
[![pytest](https://github.com/gcol33/timegrain/actions/workflows/pytest.yaml/badge.svg)](https://github.com/gcol33/timegrain/actions/workflows/pytest.yaml)
[![contract](https://github.com/gcol33/timegrain/actions/workflows/contract.yaml/badge.svg)](https://github.com/gcol33/timegrain/actions/workflows/contract.yaml)

A logger records every hour for years. Before any model sees it, that record gets reduced: to
monthly means, to growing-degree-days, to whatever the analyst settled on once and never revisited.
`timegrain` makes the reduction an argument. Build the representation at any grain, fit at each
grain, and read off where predictive skill saturates.

On 894 alpine plots and three years of hourly soil temperature, the full hourly record was the
best input for none of three architectures, skill peaked at the weekly average, and a week's
coldest and warmest **day** carried more than its mean, by more the coarser the window.

```r
x   <- window_matrix(readings, plot, datetime, temperature,
                     window = c("day", "week", "month"),
                     stats = c("cold_day", "mean", "warm_day"))
lad <- window_ladder(x, y, list(cnn_learner(), elasticnet_learner()), folds = fold_map(y))
plot(lad)
paired_contrast(lad, "week|cnn", "week|elasticnet")
```

## Calendar bins, not blocks of hours

A month is 28, 30 or 31 days, and a week starts on a Monday. Bins that count hours instead drift
away from both, so a "monthly" mean built from 730-hour blocks slides through the seasons over
three years. `timegrain` bins on the calendar and asserts every unit holds readings in every bin.

```r
attr(window_matrix(d, plot, t, temp, window = "month"), "bin_n")[1, 1:3]
#> 2021-09-01T00:00:00Z 2021-10-01T00:00:00Z 2021-11-01T00:00:00Z
#>                  720                  744                  720
```

A calendar of your own is a function: pass one that returns each reading's bin start, and seasons
cut at the equinoxes bin like any named window. They are a different calendar from the named
`season`, not a different reading of it: three years from 1 September are twelve bins of three
calendar months and thirteen cut at the equinoxes, because the record begins inside one of those.

A record that begins away from a bin boundary gives a bin the calendar does not fill. `bin_partial`
marks those bins and `partial = "drop"` removes them, so the choice between a short bin and a lost
end of the record is one the caller makes.

## An extreme day is not an extreme reading

`min` and `max` take the coldest and warmest single reading in a bin. `cold_day` and `warm_day`
reduce each day to its own mean first, then take the extreme over days. `mean_daily_min` and
`mean_daily_max` take the mean of the daily extremes, the exposure a typical day of the bin
brought. One hour at -50 sets `min` to -50 outright and reaches the day-level statistics only
through its twenty-fourth of that day's mean, and on soil temperature it is the day-level pair
that predicts.

## What is in the box

- **`window_matrix()`**: readings in long form to a `[unit, bin, channel]` array, at one of
  `hour`, `halfday`, `day`, `week`, `month`, `season`, `year`, or at all of them at once.
- **`fold_map()`, `scorable_cells()`**: one split read by everything that scores, and the mask of
  cells a score is defined on, computed from the response and the fold map with no model involved.
- **`window_ladder()`, `plot()`, `paired_contrast()`**: fit every learner at every grain on one
  split and one mask, draw the curve, and compare two arms inside each cell both scored.
- **Learners**: `elasticnet_learner()`, `stepwise_learner()`, and the `torch` encoders
  `mlp_learner()`, `cnn_learner()`, `rescnn_learner()`, all joint multi-label.
  `ensemble_learner()` averages members before the threshold is chosen. `learner()` takes a fit
  and a predict pair of your own, which then goes through the same folds, cells and scoring.
- **`window_contrasts()`**: a mixed model on the per-cell scores, comparing every window against a
  learner's best by Dunnett's procedure, so a difference of 0.015 can be read where absolute skill
  varies across species by ten times as much.
- **`bin_occlusion()`**: hold each bin of the record back and rescore, so a fitted model says which
  part of the year its skill rests on.
- **`tss_inflation()`**, **`implied_skill()`**: how much the self-selected threshold inflates a
  level at your own presence counts, and what population skill a level you read is consistent
  with.

## The score you report is an upper bound

TSS is read at the threshold that maximises it, chosen on the same held-out units the score is read
on. That inflates the level where presences are thin: on the Schrankogel design, by +0.110 when the
truth is 0.60. `tss_inflation()` measures it for your design, and `paired_contrast()` is where it
cancels, because both arms carry the same bias on the same cell.

## The two languages agree

`inst/spec/representation.md` is normative, and `inst/spec/fixtures/` holds a synthetic series with the
digest of every window-by-statistic combination. Both test suites assert the same digests, so R and
Python cannot drift apart on the one thing the package is about.

## Reproducing the study

`inst/reproduce/schrankogel.R` runs the published grid from the Zenodo deposit it was built on, and
asserts the plot count, the species count, the cell count and the bin count of every window before
fitting anything. `vignette("reproducing-schrankogel")` says which setting corresponds to which
part of that grid.

## Installation

```r
pak::pak("gcol33/timegrain")
```

## License

MIT.
