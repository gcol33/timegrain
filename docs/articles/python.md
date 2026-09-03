# Python

The binning, the statistics and the array assembly are `src/`, compiled
into both languages and answering to [the representation
contract](https://gillescolling.com/climgrain/articles/contract.md).
[`window_matrix()`](https://gillescolling.com/climgrain/reference/window_matrix.md)
here and
[`window_matrix()`](https://gillescolling.com/climgrain/reference/window_matrix.md)
in R return the same numbers from the same input, and the fixtures under
`inst/spec/fixtures/` hold them to it.

``` bash
pip install git+https://github.com/gcol33/climgrain
```

``` python
import climgrain as tg

x = tg.window_matrix(readings, id="plot", time="t", value="temp",
                     window="week", stats=("cold_day", "mean", "warm_day"))
lad = tg.window_ladder(x, y, learners=[tg.mlp_learner(), tg.cnn_learner()])
```

The contract’s last section says what each language carries, so a
difference between the two is a recorded decision.

## The pages

- [The
  representation](https://gillescolling.com/climgrain/articles/python-representation.md):

  Readings in long form to the array a model is fitted on, at one grain
  or at every grain of a ladder.

- [The split and the
  cells](https://gillescolling.com/climgrain/articles/python-split.md):

  One fold map read by everything that scores, and the cells a score is
  defined on, computed with no model involved.

- [Fitting](https://gillescolling.com/climgrain/articles/python-fitting.md):

  Fitting one learner at one grain, fitting every grain of a ladder, and
  reading the grain a ladder saturates at.

- [Learners](https://gillescolling.com/climgrain/articles/python-learners.md):

  The arms that ship, and the interface a learner of your own goes
  through.

- [Scoring and
  comparison](https://gillescolling.com/climgrain/articles/python-scoring.md):

  The metrics, the paired contrast between two learners on matched
  cells, and the inflation of a score read at its own best threshold.

- [Extending](https://gillescolling.com/climgrain/articles/python-extending.md):

  The response head and the metric are registrations, never a fork of
  the fitting code.

- [What crosses the
  boundary](https://gillescolling.com/climgrain/articles/python-artifacts.md):

  The three artifacts a split is carried in, and the digest that says
  two arrays are the same array.
