"""timegrain: temporal grain selection for ecological prediction from sensor time series.

The representation answers to ``inst/spec/representation.md``, the same document the R package answers
to, and the test suite asserts the digests in ``inst/spec/fixtures/``. Where this implementation and
that document disagree, the document is right.

That document's last section says what each language carries, so a difference between the two is a
decision recorded there rather than something to be discovered at the call site.
"""

from .artifacts import (read_cells, read_folds, read_response, write_cells,
                        write_folds, write_response)
from .digest import digest_array
from .ladder import (Ladder, implied_skill, paired_contrast, tss_inflation,
                     window_ladder)
from .learners import (Fit, Learner, cnn_learner, elasticnet_learner, fit_learner, flatten,
                       mlp_learner, rescnn_learner, stepwise_learner)
from .metrics import (cohen_kappa, decision_threshold, kappa_score, model_agreement,
                      roc_auc, tss)
from .occlusion import bin_occlusion, ensemble_learner, feature_matrix
from .registry import (get_learner, learners, metrics, register_learner, register_metric,
                       register_response, responses)
from .representation import (DAY_LEVEL_STATS, STATS, WINDOWS, TimegrainSet, WindowMatrix,
                             bind_channels, calendar_channels, timegrain_set, window_matrix)
from .response import (PRESENCE_ABSENCE, Cells, Folds, Response, align_folds, as_response,
                       fold_map, scorable_cells)
from .selection import Selection, select_grain

__version__ = "0.2.0"

# The learners, response heads and metrics that ship are registered here, through the same public
# calls a user registers their own with. There is no second, privileged path into the registries.
# The R package does the same at load, in `zzz.R`.
register_metric("tss", tss)
register_metric("roc_auc", roc_auc)
register_metric("kappa", lambda y, p: kappa_score(y, p, "prevalence"))
register_metric("kappa_youden", lambda y, p: kappa_score(y, p, "youden"))

register_response("presence_absence", PRESENCE_ABSENCE)

register_learner("elasticnet", elasticnet_learner)
register_learner("stepwise", stepwise_learner)
register_learner("mlp", mlp_learner)
register_learner("cnn", cnn_learner)
register_learner("rescnn", rescnn_learner)
register_learner("ensemble", lambda: ensemble_learner([cnn_learner(), rescnn_learner()]))

__all__ = [
    "Cells", "DAY_LEVEL_STATS", "Fit", "Folds", "Ladder", "Learner", "PRESENCE_ABSENCE",
    "Response", "STATS", "Selection", "TimegrainSet", "WINDOWS", "WindowMatrix", "align_folds",
    "as_response", "bin_occlusion", "bind_channels", "calendar_channels", "cnn_learner",
    "cohen_kappa", "decision_threshold", "digest_array", "elasticnet_learner", "ensemble_learner",
    "feature_matrix", "fit_learner", "flatten", "fold_map", "get_learner", "implied_skill",
    "kappa_score", "learners", "metrics", "mlp_learner", "model_agreement", "paired_contrast",
    "read_cells", "read_folds", "read_response", "register_learner", "register_metric",
    "register_response", "rescnn_learner", "responses", "roc_auc", "scorable_cells",
    "select_grain", "stepwise_learner", "timegrain_set", "tss", "tss_inflation", "window_ladder",
    "window_matrix", "write_cells", "write_folds", "write_response",
]
