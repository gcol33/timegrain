# Fit at every grain and see where skill saturates

Cross-validates every learner at every window of a representation set,
on one fold map and one mask of scorable cells, and returns the score of
each `(window, learner, variable, fold)` cell. It is the measurement the
package exists for: how much of a record a model needs, read off the
point where making the record finer stops paying.

## Usage

``` r
window_ladder(
  x,
  y,
  learners,
  folds = NULL,
  response = "presence_absence",
  metric = NULL,
  keep_fits = FALSE,
  verbose = TRUE
)

# S3 method for class 'climgrain_ladder'
summary(object, ...)
```

## Arguments

- x:

  A
  [`window_matrix()`](https://gillescolling.com/climgrain/reference/window_matrix.md)
  result, a
  [`climgrain_set()`](https://gillescolling.com/climgrain/reference/climgrain_set.md),
  or a named list of representations.

- y:

  The response for the same units.

- learners:

  A learner, a list of them, or names of registered ones. An unnamed
  list is labelled by each learner's own name.

- folds:

  A fold map from
  [`fold_map()`](https://gillescolling.com/climgrain/reference/fold_map.md),
  or any named integer vector. Built with the defaults of
  [`fold_map()`](https://gillescolling.com/climgrain/reference/fold_map.md)
  when not given.

- response:

  Name of the registered response head.

- metric:

  Name of the registered metric, or `NULL` for the response's own.

- keep_fits:

  Keep every per-fold fitted model, which is what lets
  [`bin_occlusion()`](https://gillescolling.com/climgrain/reference/bin_occlusion.md)
  read a fitted model without refitting it.

- verbose:

  Report each arm and each fold as it runs.

- object:

  A ladder.

- ...:

  Ignored, so that [`summary()`](https://rdrr.io/r/base/summary.html)
  takes the arguments its generic declares.

## Value

A data frame of one row per scored cell, of class `climgrain_ladder`,
carrying the window, the learner, the variable, the fold and the score.
The held-out prediction of every unit is kept in the `predictions`
attribute, and the scorable-cell mask in `cells`.

## Details

Every arm sees identical splits and is restricted to identical cells, so
the arms' means share a denominator and any two of them can be compared
cell by cell with
[`paired_contrast()`](https://gillescolling.com/climgrain/reference/paired_contrast.md).

## Examples

``` r
set.seed(1)
t <- seq(as.POSIXct("2021-09-01", tz = "UTC"), by = "hour", length.out = 24 * 200)
units <- sprintf("p%02d", 1:60)
warmth <- rnorm(60)
d <- data.frame(
  plot = rep(units, each = length(t)), t = rep(t, length(units)),
  temp = as.numeric(vapply(warmth, function(w) w + sin(seq_along(t) / 300) + rnorm(length(t)),
                           numeric(length(t)))))
y <- matrix(rbinom(120, 1, plogis(c(warmth, -warmth))), nrow = 60,
            dimnames = list(units, c("sp1", "sp2")))
x <- window_matrix(d, plot, t, temp, window = c("week", "month"))
lad <- window_ladder(x, y, elasticnet_learner(), folds = fold_map(y, v = 3), verbose = FALSE)
summary(lad)
```
