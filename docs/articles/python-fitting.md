# Python: fitting

Fitting one learner at one grain, fitting every grain of a ladder, and
reading the grain a ladder saturates at.

## `window_ladder()`

``` python
window_ladder(
    x,
    y,
    learners,
    folds=None,
    response: str = 'presence_absence',
    metric=None,
    keep_fits: bool = False,
    verbose: bool = True,
)
```

Cross-validate every learner at every window, on one fold map and one
mask of cells.

Every arm sees identical splits and is restricted to identical cells, so
the arms’ means share a denominator and any two of them can be compared
with `paired_contrast`.

`folds` left at `None` builds one with the defaults of `fold_map`. Where
both languages must see the same splits, build it once and read it in
the other with `read_folds`.

## `fit_learner()`

``` python
fit_learner(learner, x: WindowMatrix, y, response: str = 'presence_absence', **kwargs)
```

Fit one learner at one grain, under one registered response head.

## `select_grain()`

``` python
select_grain(
    x,
    y,
    learners,
    folds=None,
    inner=5,
    response: str = 'presence_absence',
    metric=None,
    compare: Ladder | None = None,
    seed: int = 1,
    verbose: bool = True,
)
```

Choose the grain inside each outer fold’s training units, then score the
whole procedure.

Within each outer fold the training units are split again, every
candidate is fitted on part of them and scored on the rest, the best is
refitted on the whole outer training set, and the outer test fold is
predicted once. The estimate that comes back is therefore of the
procedure including its choice of grain, which is what an ecologist
applying it to a new site would run.

What the estimate is of: the expected held-out score of the whole
pipeline, selection included, on units drawn as these were. What it is
not: the score of the winning grain. That is higher, by the amount
selection buys itself, and the difference between the two is the
quantity this function exists to keep out of a reported number.

The cost is the ladder’s, multiplied by the number of inner folds:
`v_outer * (v_inner * candidates + 1)` fits.

## `Ladder`

``` python
Ladder(
    window,
    learner,
    variable,
    fold,
    score,
    scorable,
    predictions,
    cells,
    folds,
    metric,
    fits,
)
```

One score per `(window, learner, variable, fold)` cell, and what
produced it.

Attributes:

- `window` - np.ndarray
- `learner` - np.ndarray
- `variable` - np.ndarray
- `fold` - np.ndarray
- `score` - np.ndarray
- `scorable` - np.ndarray
- `predictions` - dict
- `cells` - object
- `folds` - Folds
- `metric` - str
- `fits` - dict

### `arm()`

``` python
arm(self, name: str)
```

A mask over the rows of one window-and-learner arm, named
`window/learner`.

### `summary()`

``` python
summary(self)
```

The across-variable mean of the per-variable score, one row per arm.

## `Fit`

``` python
Fit(learner, model, variables, response)
```

A fitted learner and the variables it was fitted on.

Attributes:

- `learner` - Learner
- `model` - object
- `variables` - tuple\[str, …\]
- `response` - str

### `predict()`

``` python
predict(self, x: WindowMatrix)
```

Predictions for a representation, as a `[unit, variable]` matrix.

## `Selection`

``` python
Selection(selected, estimate, contrast, candidates, scores, inner, metric, response)
```

What a nested selection chose, what it scores, and what it was searched
over.

Attributes:

- `selected` - list\[dict\]
- `estimate` - list\[dict\]
- `contrast` - list\[dict\] \| None
- `candidates` - list\[dict\]
- `scores` - Ladder
- `inner` - list\[dict\]
- `metric` - str
- `response` - str
