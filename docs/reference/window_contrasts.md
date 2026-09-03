# Compare every window against a learner's best one

A mixed model on the per-cell scores of one learner,
`score ~ window + (1 | variable) + (1 | fold)`, fitted by restricted
maximum likelihood. Every window is then compared against the reference
by Dunnett's many-to-one procedure, which corrects for the comparisons
made without correcting for pairs nobody asked about.

## Usage

``` r
window_contrasts(ladder, learner = NULL, reference = NULL, adjust = "mvt")
```

## Arguments

- ladder:

  A
  [`window_ladder()`](https://gillescolling.com/climgrain/reference/window_ladder.md)
  result.

- learner:

  Which learner's grid to fit. The only one in the ladder by default.

- reference:

  The window every other is compared against. The learner's best by
  default.

- adjust:

  Multiplicity adjustment passed to
  [`emmeans::contrast()`](https://rvlenth.github.io/emmeans/reference/contrast.html).

## Value

A data frame of one row per window: the estimated marginal mean
difference from the reference, its interval, and the adjusted p-value.
Needs `lme4`, `lmerTest` and `emmeans`.

## Details

The design is balanced across variables, folds and windows, so each
window is compared within a variable and within a fold and the variation
between variables cancels from the comparison. That is what lets a
difference of 0.015 hold up where absolute skill ranges across variables
by ten times as much.

Taking the best-observed window as the reference is a choice that
favours the reference, so read this beside the paired differences
[`paired_contrast()`](https://gillescolling.com/climgrain/reference/paired_contrast.md)
gives, which single out no window.

## Examples

``` r
# \donttest{
set.seed(1)
t <- seq(as.POSIXct("2021-09-01", tz = "UTC"), by = "hour", length.out = 24 * 200)
units <- sprintf("p%03d", 1:60)
warmth <- rnorm(60)
d <- data.frame(
  plot = rep(units, each = length(t)), t = rep(t, length(units)),
  temp = as.numeric(vapply(warmth, function(w) 1.5 * w + rnorm(length(t), sd = 20),
                           numeric(length(t)))))
y <- matrix(rbinom(60 * 6, 1, plogis(3 * as.numeric(outer(warmth, rep(c(1, -1), 3))))),
            ncol = 6, dimnames = list(units, paste0("sp", 1:6)))
x <- window_matrix(d, plot, t, temp, window = c("day", "week", "month"))
lad <- window_ladder(x, y, elasticnet_learner(), folds = fold_map(y, v = 5), verbose = FALSE)
if (requireNamespace("emmeans", quietly = TRUE)) window_contrasts(lad)
# }
```
