# Define a learner

A learner is a pair of functions: one that fits a model to a
representation and a response, and one that predicts from it. Everything
the package fits goes through this pair, so a learner of your own sits
beside the ones that ship and needs no change to the ladder, the folds
or the scoring.

## Usage

``` r
learner(name, fit, predict, needs = character(), params = list())
```

## Arguments

- name:

  Name the learner is reported under.

- fit:

  A function of `(x, y, ...)`, where `x` is a `[unit, bin, channel]`
  array and `y` the response matrix for the same units, returning a
  fitted object.

- predict:

  A function of `(model, x)` returning a `[unit, variable]` matrix of
  predictions for the units of `x`, in that order.

- needs:

  Packages the learner requires. A learner that cannot run says so at
  once rather than falling back to something else.

- params:

  Settings carried with the learner and passed to `fit`.

## Value

A `timegrain_learner`.

## Examples

``` r
# The bin means of a unit, fed to one logistic regression per variable.
flat_glm <- learner(
  "flat_glm",
  fit = function(x, y, ...) {
    f <- as.data.frame(apply(x, c(1, 3), mean))
    lapply(seq_len(ncol(y)), function(j)
      stats::glm(y[, j] ~ ., data = f, family = stats::binomial()))
  },
  predict = function(model, x) {
    f <- as.data.frame(apply(x, c(1, 3), mean))
    vapply(model, function(m) stats::predict(m, f, type = "response"), numeric(nrow(f)))
  }
)
flat_glm
```
