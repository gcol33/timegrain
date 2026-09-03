# climgrain (Python)

The Python side of `climgrain`. It answers to `../inst/spec/representation.md`, the same document the R
package answers to, and its test suite asserts the digests in `../inst/spec/fixtures/digests.csv`.

```python
import climgrain as tg

x = tg.window_matrix(readings, "logger_ID", "datetime", "temperature",
                     window=["day", "week", "month"],
                     stats=["cold_day", "mean", "warm_day"])

folds = tg.read_folds(fold_csv, x["week"].units)
lad = tg.window_ladder(x, y, [tg.cnn_learner(), tg.elasticnet_learner()], folds=folds)
print(lad)
tg.paired_contrast(lad, "week|cnn", "week|elasticnet")
```

## What is here

- `window_matrix`, `calendar_channels`, `bind_channels`: the representation, at one grain or at
  every grain of a ladder.
- `Response`, `fold_map`, `read_folds`, `scorable_cells`: the response, the split, and which cells
  admit a score.
- `tss`, `roc_auc`, `kappa_score`, `model_agreement`, `decision_threshold`: the metrics.
- `window_ladder`, `paired_contrast`, `tss_inflation`: fitting at every grain, comparing two arms
  cell by cell, and how much a self-selected threshold inflates a level.
- `bin_occlusion`: hold each bin or each channel back and rescore, without refitting.
- `feature_matrix`: bring an already-reduced feature table in as an arm of the same ladder.
- `mlp_learner`, `cnn_learner`, `rescnn_learner` (torch), `elasticnet_learner` (scikit-learn),
  `ensemble_learner`, and `Learner` for one of your own.

The mixed-model window contrast the R side offers as `window_contrasts()` has no counterpart here.

The binning and the reduction are not written here. They are `../src/cg_core.cpp`, the same
implementation the R package compiles, reached through the `_core` extension that `../CMakeLists.txt`
builds with nanobind. What is written here is the boundary: resolving the columns, resolving the
zone, and putting the result into a `WindowMatrix`.

At runtime the package needs numpy alone. A learner that needs a package declares it and stops
without it.

## The time zone

`window_matrix` takes a `tz` argument. Left at `None` the instants are taken as already expressed
in the calendar to bin by, which is what a zone-free `datetime64` says. Given a zone name they are
read as UTC and binned by that zone's clock, which is what the R side does for a series carrying a
`tzone`. The same instants and the same zone give the same answer in both languages, and
`digests.csv` carries zone rows that pin it.

## The fold map crosses the language boundary; the fold builder does not

`fold_map` draws on numpy's random stream and the R side draws on R's, so the same seed gives
different maps. Where both languages must see identical splits, build the map once and read it in
the other with `read_folds`. The map is an artifact, like the response and the representation.

## Two rules govern this directory

- **`tests/oracle.py` is implemented from the spec, not transcribed from the R source.** It is the
  NumPy representation as it was written before the two languages shared a core, kept because
  reading the R code and copying it would reproduce its bugs and hide its assumptions. Nothing
  imports it outside the suite; it exists so the shared core is checked against an implementation
  that shares none of its code.
- **A digest mismatch is a bug, never a fixture to regenerate.** Regenerating fixtures happens on
  the R side, deliberately, in its own commit, and only when the spec changed with it.

The project directory is the repository root, because a source distribution cannot reach above
itself and the shared sources are not vendored into a second copy. Build and test from there:

```
pip install -e ".[test,torch,sklearn]"
pytest
```
