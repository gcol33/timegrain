# Average several learners before scoring

Fits every member on the units it is handed and averages their predicted
probabilities. The average is taken before the threshold is chosen, so
the ensemble is scored as one model rather than as a vote between
decisions.

## Usage

``` r
ensemble_learner(members, weights = NULL, name = "ensemble")
```

## Arguments

- members:

  A list of
  [`learner()`](https://gillescolling.com/climgrain/reference/learner.md)s,
  or names of registered ones. Members left unnamed take their learner's
  own name, made unique where several members share it.

- weights:

  Weights over the members, rescaled to sum to one. Equal by default.

- name:

  Name the ensemble is reported under.

## Value

A
[`learner()`](https://gillescolling.com/climgrain/reference/learner.md).

## Details

Members differing in architecture, in width and depth, or in the grain
they read are what an ensemble is for; members differing only in their
seed buy less. Choose the set on an inner validation split or on prior
grounds, never on the held-out folds, or the ensemble is fitted to the
cells it is then scored on.

## Examples

``` r
ensemble_learner(list(elasticnet_learner(alpha = 0.5), elasticnet_learner(alpha = 1)))
ensemble_learner(list(ridge = elasticnet_learner(alpha = 0),
                      lasso = elasticnet_learner(alpha = 1)))
```
