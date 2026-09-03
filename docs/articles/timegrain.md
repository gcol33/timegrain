# Choosing the grain a sensor record is read at

A logger records every hour for years. Before any model sees it, the
record is reduced: to monthly means, to growing-degree-days, to whatever
the analyst settled on once. `timegrain` makes that reduction an
argument, fits at each setting of it, and shows where predictive skill
saturates.

This vignette runs the whole path on a small simulated record, from
readings to a curve that says how much of the record the models needed.

## A record to read

Sixty plots, four months of hourly readings. Each plot has a level of
its own, and that level is buried in hour-to-hour noise an order of
magnitude larger.

``` r

hours <- seq(as.POSIXct("2021-09-01", tz = "UTC"), by = "hour", length.out = 24 * 120)
plots <- sprintf("p%03d", 1:60)
warmth <- rnorm(60)

readings <- data.frame(
  plot = rep(plots, each = length(hours)),
  t = rep(hours, times = 60),
  temp = as.numeric(vapply(warmth, function(w) {
    1.5 * w + 6 * sin(seq_along(hours) / (24 * 40)) + rnorm(length(hours), sd = 12)
  }, numeric(length(hours))))
)

sign <- rep(c(1, -1), length.out = 6)
y <- matrix(rbinom(60 * 6, 1, plogis(3 * as.numeric(outer(warmth, sign)))), ncol = 6,
            dimnames = list(plots, paste0("sp", 1:6)))
```

## The representation

[`window_matrix()`](https://gillescolling.com/timegrain/reference/window_matrix.md)
bins the readings by the calendar and summarises every bin.

``` r

x <- window_matrix(readings, plot, t, temp, window = "week",
                   stats = c("cold_day", "mean", "warm_day"))
x
#> <timegrain matrix> 60 units x 18 bins x 3 channels 
#> window: week   stats: cold_day, mean, warm_day 
#> from  : 2021-08-30 to 2021-12-27
```

The result is a `[plot, bin, channel]` array, and it carries the binning
that produced it.

``` r

attr(x, "bin_n")[1, 1:4]
#> 2021-08-30T00:00:00Z 2021-09-06T00:00:00Z 2021-09-13T00:00:00Z 
#>                  120                  168                  168 
#> 2021-09-20T00:00:00Z 
#>                  168
dimnames(x)[[3]]
#> [1] "cold_day" "mean"     "warm_day"
```

Bins follow the calendar. A month is 28, 30 or 31 days, and a week
starts on a Monday, so a bin is a real month or a real week and not a
drifting block of 730 or 168 hours.

``` r

attr(window_matrix(readings, plot, t, temp, window = "month"), "bin_n")[1, ]
#> 2021-09-01T00:00:00Z 2021-10-01T00:00:00Z 2021-11-01T00:00:00Z 
#>                  720                  744                  720 
#> 2021-12-01T00:00:00Z 
#>                  696
```

### An extreme day is not an extreme reading

`min` and `max` take the coldest and warmest single reading of a bin.
`cold_day` and `warm_day` reduce each day to its own mean first and then
take the extreme over days. `mean_daily_min` and `mean_daily_max` take
the mean of the daily extremes, which is the exposure a typical day of
the bin brought. One hour at -50 sets `min` to -50 outright; it reaches
the day-level statistics only through its twenty-fourth of that day’s
mean.

``` r

week <- window_matrix(readings, plot, t, temp, window = "week",
                      stats = c("min", "mean_daily_min", "cold_day", "mean",
                                "warm_day", "mean_daily_max", "max"))
round(week[1, 1, ], 2)
#>            min mean_daily_min       cold_day           mean       warm_day 
#>         -23.41         -17.61          -6.76          -0.17           4.98 
#> mean_daily_max            max 
#>          24.02          27.89
```

## The split, and the cells a score is defined on

One fold map, built once, is read by everything that scores, so every
model is fitted and scored on identical splits.

``` r

folds <- fold_map(y, v = 5, seed = 1)
folds
#> <timegrain folds> 60 units in 5 folds 
#> fold
#>  1  2  3  4  5 
#> 13 11 11 13 12
```

A per-species score needs both classes among the held-out plots, and a
per-species model needs both classes among the plots it was fitted on.
The mask says which cells those are, from the response and the fold map
alone.

``` r

scorable_cells(y, folds)
#> <timegrain cells> 30 cells over 6 variables 
#> scorable: 30 (100.0%); variables with at least one scorable fold: 6 of 6
```

Because it involves no model, every arm below is restricted to the same
cells: their means share one denominator and every paired difference
runs on matched cells.

## The ladder

[`window_matrix()`](https://gillescolling.com/timegrain/reference/window_matrix.md)
given several windows returns one representation per window, which is
what
[`window_ladder()`](https://gillescolling.com/timegrain/reference/window_ladder.md)
fits across.

``` r

set <- window_matrix(readings, plot, t, temp, window = c("day", "week", "month"))
lad <- window_ladder(set, y, elasticnet_learner(), folds = folds, verbose = FALSE)
summary(lad)
#>      learner window     score n_variable  best
#> 1 elasticnet    day 0.6669180          6 FALSE
#> 2 elasticnet   week 0.7082804          6 FALSE
#> 3 elasticnet  month 0.7322619          6  TRUE
```

``` r

plot(lad)
```

![Mean true skill statistic against aggregation window, with an interval
across species.](timegrain_files/figure-html/plot-1.svg)

Skill rises as the record is smoothed, and it is still rising at the
coarsest window here: the signal was planted at a scale wider than a
month and the daily reading is still buried in the hourly noise. The
paired contrast is what a claim about that rests on. The difference is
taken inside each cell both arms scored, averaged within a species, and
summarised across the species, which are the independent replicates. Six
species is few enough that the interval spans zero even where the means
are ordered.

``` r

paired_contrast(lad, "month|elasticnet", "day|elasticnet")
#>                  a              b       diff       lower    upper n_variable
#> 1 month|elasticnet day|elasticnet 0.06534392 -0.03475019 0.165438          6
#>   n_cell n_favour p_value
#> 1     30        3 0.84375
```

Where the whole curve is the question rather than one pair of it,
[`window_contrasts()`](https://gillescolling.com/timegrain/reference/window_contrasts.md)
fits a mixed model on the per-cell scores and compares every window
against the best one, correcting for the comparisons made and no others.

``` r

window_contrasts(lad)
#>      learner window reference        diff      lower      upper   p_value
#> 1 elasticnet    day     month -0.06534392 -0.1540747 0.02338684 0.1767694
#> 2 elasticnet   week     month -0.02398148 -0.1127122 0.06474927 0.7677093
```

## Reading a level honestly

The true skill statistic is read at the threshold that maximises it,
chosen on the same plots the score is then read on. That inflates the
level, and by more the fewer presences a cell holds.
[`tss_inflation()`](https://gillescolling.com/timegrain/reference/tss_inflation.md)
measures the inflation for the presence counts of the design in hand.

``` r

tss_inflation(y, folds, skill = c(0.6, 0.9), replicates = 100)
#>   skill  reported inflation     lower     upper replicates
#> 1   0.6 0.7628503 0.1628503 0.7046779 0.8197646        100
#> 2   0.9 0.9677586 0.0677586 0.9425053 0.9863095        100
```

The inflation is common to every arm scored the same way, so it cancels
in the paired differences above. It does not cancel in a level, so a
level is an upper bound on the skill a population has.

## Other learners

The learners that ship are the two aggregate-feature arms,
[`elasticnet_learner()`](https://gillescolling.com/timegrain/reference/elasticnet_learner.md)
and
[`stepwise_learner()`](https://gillescolling.com/timegrain/reference/stepwise_learner.md),
and three sequence encoders that need `torch`:
[`mlp_learner()`](https://gillescolling.com/timegrain/reference/torch_learners.md),
[`cnn_learner()`](https://gillescolling.com/timegrain/reference/torch_learners.md)
and
[`rescnn_learner()`](https://gillescolling.com/timegrain/reference/torch_learners.md).
All three encoders are joint multi-label models, so every species is
predicted together from a shared embedding, which is what makes the
rarer ones learnable at these sample sizes.

An encoder that ends in global pooling discards when a thermal event
happened, so the position of a bin in the year has to be given to it as
input.

``` r

week_mean <- window_matrix(readings, plot, t, temp, window = "week")
dimnames(bind_channels(week_mean, calendar_channels(week_mean)))[[3]]
#> [1] "mean"     "year_sin" "year_cos"
```

[`ensemble_learner()`](https://gillescolling.com/timegrain/reference/ensemble_learner.md)
averages members’ predicted probabilities before the threshold is
chosen, so the set is scored as one model rather than as a vote between
decisions. Members differing in architecture, in width, or in the grain
they read are what it is for.

``` r

both <- ensemble_learner(list(ridge = elasticnet_learner(alpha = 0), lasso = elasticnet_learner(alpha = 1)))
summary(window_ladder(set["week"], y, both, folds = folds, verbose = FALSE))
#>    learner window     score n_variable best
#> 1 ensemble   week 0.7180159          6 TRUE
```

A learner of your own is a fit and a predict pair, and nothing else. It
goes through the same folds, the same cells and the same scoring as the
ones that ship.

``` r

flat <- function(x) matrix(as.numeric(x), nrow = dim(x)[1])

nearest_neighbour <- learner(
  "1nn",
  fit = function(x, y, ...) list(x = flat(x), y = y),
  predict = function(model, x) {
    d <- as.matrix(dist(rbind(flat(x), model$x)))[seq_len(dim(x)[1]), -seq_len(dim(x)[1])]
    model$y[apply(d, 1, which.min), , drop = FALSE]
  }
)

summary(window_ladder(set, y, list(elasticnet = elasticnet_learner(), nn = nearest_neighbour),
                      folds = folds, verbose = FALSE))
#>      learner window     score n_variable  best
#> 1 elasticnet    day 0.6669180          6 FALSE
#> 2 elasticnet   week 0.7082804          6 FALSE
#> 3 elasticnet  month 0.7322619          6  TRUE
#> 4         nn    day 0.3923413          6 FALSE
#> 5         nn   week 0.4237831          6 FALSE
#> 6         nn  month 0.5154497          6  TRUE
```

## What was read

With the fits kept,
[`bin_occlusion()`](https://gillescolling.com/timegrain/reference/bin_occlusion.md)
holds each bin of the record back in turn, rescores the held-out plots,
and records the fall in score as that bin’s weight. Nothing is refitted.

``` r

kept <- window_ladder(set["month"], y, elasticnet_learner(), folds = folds,
                      keep_fits = TRUE, verbose = FALSE)
weight <- bin_occlusion(kept, set, y, "month|elasticnet", permutations = 5)
head(aggregate(weight ~ part, weight, mean), 4)
#>                   part     weight
#> 1 2021-09-01T00:00:00Z 0.04748942
#> 2 2021-10-01T00:00:00Z 0.06421958
#> 3 2021-11-01T00:00:00Z 0.09092394
#> 4 2021-12-01T00:00:00Z 0.05887765
```

Holding a channel back instead asks what each statistic of a window
carries, which is the question behind keeping a bin’s extremes at all.
