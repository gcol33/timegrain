# timegrain (Python)

The Python side of `timegrain`. It answers to `../spec/representation.md`, the same document the R
package answers to, and its test suite asserts the digests in `../spec/fixtures/digests.csv`.

Nothing is implemented yet. The build order mirrors the R side, and each piece lands here once its
fixtures exist on the R side:

1. `window_matrix()`, asserting the fixture digests.
2. The fold map and the scorable-cell mask.
3. The ladder.
4. The learner registry and the torch learners.

Two rules govern this directory:

- **The representation is not reimplemented from the R source, it is implemented from the spec.**
  Reading the R code and transcribing it reproduces its bugs and hides its assumptions. The spec is
  what both sides are checked against.
- **A digest mismatch is a bug, never a fixture to regenerate.** Regenerating fixtures happens on
  the R side, deliberately, in its own commit, and only when the spec changed with it.

```
pip install -e ".[test]"
pytest
```
