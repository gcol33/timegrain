# timegrain

*the grain a sensor record is read at*

**Calendar-aware reduction of sensor time series, at every temporal grain, with the same numbers in R and Python.**

A logger records every hour for years. Before any model sees it, that record gets reduced: to
monthly means, to growing-degree-days, to whatever the analyst settled on once and never revisited.
`timegrain` makes the reduction an argument. Build the representation at any grain, fit at each
grain, and read off where predictive skill saturates.

On 894 alpine plots and three years of hourly soil temperature, the full hourly record was the
best input for none of three architectures, skill peaked at the weekly average, and a week's
coldest and warmest **day** carried more than its mean, by more the coarser the window.

```r
x <- window_matrix(readings, plot, datetime, temperature,
                   window = "week", stats = c("cold_day", "mean", "warm_day"))
x
#> <timegrain matrix> 894 units x 157 bins x 3 channels
```

## Calendar bins, not blocks of hours

A month is 28, 30 or 31 days, and a week starts on a Monday. Bins that count hours instead drift
away from both, so a "monthly" mean built from 730-hour blocks slides through the seasons over
three years. `timegrain` bins on the calendar and asserts the bins tile the record exactly.

```r
attr(window_matrix(d, plot, t, temp, window = "month"), "bin_n")[1, 1:3]
#> 2021-09-01T00:00:00Z 2021-10-01T00:00:00Z 2021-11-01T00:00:00Z
#>                  720                  744                  720
```

## An extreme day is not an extreme reading

`min` and `max` take the coldest and warmest single reading in a bin. `cold_day` and `warm_day`
reduce each day to its own mean first, then take the extreme over days. One hour at -50 changes
the first and not the second, and on soil temperature it is the second that predicts.

## What is in the box

- **`window_matrix()`**: readings in long form to a `[unit, bin, channel]` array, at one of
  `hour`, `halfday`, `day`, `week`, `month`, `season`, `year`.

Being built, in this order: the fold map and the scorable-cell mask, the ladder and its plot, the
learner registry, then the `torch` learners (`mlp()`, `cnn()`, `rescnn()`).

## The two languages agree

`spec/representation.md` is normative, and `spec/fixtures/` holds a synthetic series with the
digest of every window-by-statistic combination. Both test suites assert the same digests, so R
and Python cannot drift apart on the one thing the package is about.

## Installation

```r
pak::pak("gcol33/timegrain")
```

## License

MIT.
