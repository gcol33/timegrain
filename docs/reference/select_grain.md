# Choose the grain inside the training data, and score the whole procedure

[`window_ladder()`](https://gillescolling.com/timegrain/reference/window_ladder.md)
fits every candidate against one fold map and reports the grid, so
reading the best window off it and quoting that window's score quotes a
number the held-out units helped choose. This does the choosing inside
the training data instead. Within each outer fold the training units are
split again, every candidate is fitted on part of them and scored on the
rest, the best is refitted on the whole outer training set, and the
outer test fold is predicted once. The estimate that comes back is
therefore of the procedure including its choice of grain, which is what
an ecologist applying it to a new site would run.

## Usage

``` r
select_grain(
  x,
  y,
  learners,
  folds = NULL,
  inner = 5L,
  response = "presence_absence",
  metric = NULL,
  compare = NULL,
  seed = 1L,
  verbose = TRUE
)

# S3 method for class 'timegrain_selection'
summary(object, ...)
```

## Arguments

- x:

  A
  [`window_matrix()`](https://gillescolling.com/timegrain/reference/window_matrix.md)
  result, a
  [`timegrain_set()`](https://gillescolling.com/timegrain/reference/timegrain_set.md),
  or a named list of representations. Its names are the grains being
  chosen between.

- y:

  The response for the same units.

- learners:

  A learner, a list of them, or names of registered ones, as
  [`window_ladder()`](https://gillescolling.com/timegrain/reference/window_ladder.md)
  takes. Named alongside the windows they form the candidate set.

- folds:

  The outer fold map, from
  [`fold_map()`](https://gillescolling.com/timegrain/reference/fold_map.md)
  or any named integer vector. Built with the defaults of
  [`fold_map()`](https://gillescolling.com/timegrain/reference/fold_map.md)
  when not given.

- inner:

  Number of inner folds the selection is made on, or a function of the
  outer training response returning a fold map for those units.

- response:

  Name of the registered response head.

- metric:

  Name of the registered metric the selection is made on, or `NULL` for
  the response's own. The estimate is reported under every registered
  metric whichever this is.

- compare:

  A
  [`window_ladder()`](https://gillescolling.com/timegrain/reference/window_ladder.md)
  result on the same units, response and outer fold map, whose arms the
  selected procedure is contrasted against cell by cell. `NULL` for no
  contrast.

- seed:

  Seed for the inner splits. Each outer fold splits under `seed` plus
  its own number, so no two outer folds inherit the same inner
  partition.

- verbose:

  Report each outer fold and what it selected as it runs.

- object:

  A selection.

- ...:

  Ignored.

## Value

A `timegrain_selection`: a list carrying `selected`, one row per outer
fold with the candidate it chose and the inner score it chose on;
`estimate`, the nested score under every registered metric with its
standard error across variables; `contrast`, one
[`paired_contrast()`](https://gillescolling.com/timegrain/reference/paired_contrast.md)
row against each arm of `compare`, or `NULL`; `candidates`, the set that
was searched; and `scores`, the per-cell rows of the selected procedure
under the selection metric, in the layout
[`window_ladder()`](https://gillescolling.com/timegrain/reference/window_ladder.md)
returns. The held-out prediction of every unit is in the `predictions`
attribute and the scorable-cell mask in `cells`.

## Details

A candidate is a `(window, learner)` pair: the windows are the elements
of the representation set, which is where a grain and the statistic its
windows are summarised by are both named, and the learners are the ones
passed. Both are registry entries or objects built by
[`learner()`](https://gillescolling.com/timegrain/reference/learner.md),
so a new grain, a new window summary or a new candidate model widens the
search with no change here.

What the estimate is of: the expected held-out score of the whole
pipeline, selection included, on units drawn as these were. What it is
not: the score of the winning grain. That is higher, by the amount
selection buys itself, and the difference between the two is the
quantity this function exists to keep out of a reported number. It also
does not say the selected grain is the one a mechanism acts at; it says
that grain predicted best on the units the selector saw.

The cost is the ladder's, multiplied by the number of inner folds:
`v_outer * (v_inner * candidates + 1)` fits. With a neural learner that
is where an overnight run goes.

## See also

[`window_ladder()`](https://gillescolling.com/timegrain/reference/window_ladder.md)
for the grid this selects from, and
[`paired_contrast()`](https://gillescolling.com/timegrain/reference/paired_contrast.md)
for the comparison the `contrast` element holds.

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
sel <- select_grain(x, y, elasticnet_learner(), folds = fold_map(y, v = 3), inner = 3,
                    verbose = FALSE)
sel
sel$estimate
```
