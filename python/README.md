# timegrain (Python)

The Python side of `timegrain`. It answers to `../inst/spec/representation.md`, the same document the R
package answers to, and its test suite asserts the digests in `../inst/spec/fixtures/digests.csv`.

```python
import timegrain as tg

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

The core needs numpy alone. A learner that needs a package declares it and stops without it.

## The fold map crosses the language boundary; the fold builder does not

`fold_map` draws on numpy's random stream and the R side draws on R's, so the same seed gives
different maps. Where both languages must see identical splits, build the map once and read it in
the other with `read_folds`. The map is an artifact, like the response and the representation.

## Two rules govern this directory

- **The representation is implemented from the spec, not transcribed from the R source.** Reading
  the R code and copying it reproduces its bugs and hides its assumptions. The spec is what both
  sides are checked against.
- **A digest mismatch is a bug, never a fixture to regenerate.** Regenerating fixtures happens on
  the R side, deliberately, in its own commit, and only when the spec changed with it.

```
pip install -e ".[test,torch,sklearn]"
pytest
```
