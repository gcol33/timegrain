# Assign units to cross-validation folds

One fold map, built once and read by everything that scores. Every
learner in a ladder is then fitted and scored on identical splits, which
is what makes the comparison between them paired rather than a
comparison of two clouds of numbers.

## Usage

``` r
fold_map(y, v = 10L, seed = 1L, strata = 5L, by = NULL)
```

## Arguments

- y:

  The response: a matrix or data frame of units by variables, with unit
  identifiers in the row names or in a leading character or factor
  column.

- v:

  Number of folds.

- seed:

  Random seed, fixed so the map is reproducible.

- strata:

  Number of strata, or `1` for no stratification.

- by:

  A numeric vector of length `nrow(y)` to stratify on instead of
  richness.

## Value

An integer vector of fold numbers named by unit, of class
`climgrain_folds`. Any named integer vector of the same shape is
accepted wherever this is.

## Details

Units are held out singly. Where the input a model reads is measured at
the unit itself, as a logger in each plot is, a held-out unit brings its
own measured input with it and nothing of its neighbours' reaches the
model.

Folds are balanced within strata: units are grouped into `strata`
equal-count groups of the stratifying value, shuffled inside each group,
and dealt round-robin, so each fold carries the same mix. With a
multi-variable response the default stratifies on richness, the number
of variables present at a unit, because one fold map has to serve every
variable at once and cannot be stratified on any single one of them.

## Examples

``` r
y <- matrix(rbinom(300, 1, 0.3), nrow = 60,
            dimnames = list(sprintf("p%02d", 1:60), paste0("sp", 1:5)))
f <- fold_map(y, v = 5)
table(f)
```
