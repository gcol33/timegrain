"""timegrain: temporal grain selection for ecological prediction from sensor time series.

The representation answers to ``inst/spec/representation.md``, the same document the R package answers
to, and the test suite asserts the digests in ``inst/spec/fixtures/``. Where this implementation and
that document disagree, the document is right.
"""

from .artifacts import (read_cells, read_folds, read_response, write_cells,
                        write_folds, write_response)
from .digest import digest_array
from .ladder import (Ladder, implied_skill, paired_contrast, tss_inflation,
                     window_ladder)
from .learners import (Learner, cnn_learner, elasticnet_learner, fit_learner, flatten,
                       get_learner, mlp_learner, register_learner, rescnn_learner)
from .occlusion import bin_occlusion, ensemble_learner, feature_matrix
from .metrics import (METRICS, cohen_kappa, decision_threshold, kappa_score, model_agreement,
                      roc_auc, tss)
from .representation import (DAY_LEVEL_STATS, STATS, WINDOWS, WindowMatrix, bind_channels,
                             calendar_channels, window_matrix)
from .response import Cells, Folds, Response, align_folds, fold_map, scorable_cells

__version__ = "0.1.0"

__all__ = [
    "DAY_LEVEL_STATS", "METRICS", "STATS", "WINDOWS", "Cells", "Folds", "Ladder", "Learner", "Response",
    "WindowMatrix", "align_folds", "bin_occlusion", "bind_channels", "calendar_channels", "cnn_learner",
    "cohen_kappa", "ensemble_learner", "feature_matrix",
    "decision_threshold", "digest_array", "elasticnet_learner", "fit_learner", "flatten",
    "fold_map", "get_learner", "implied_skill", "kappa_score", "mlp_learner", "model_agreement", "paired_contrast",
    "read_cells", "read_folds", "read_response", "register_learner", "rescnn_learner", "roc_auc", "scorable_cells", "tss",
    "tss_inflation", "window_ladder", "window_matrix", "write_cells", "write_folds",
    "write_response",
]
