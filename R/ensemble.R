#' Average several learners before scoring
#'
#' Fits every member on the units it is handed and averages their predicted probabilities. The
#' average is taken before the threshold is chosen, so the ensemble is scored as one model rather
#' than as a vote between decisions.
#'
#' Members differing in architecture, in width and depth, or in the grain they read are what an
#' ensemble is for; members differing only in their seed buy less. Choose the set on an inner
#' validation split or on prior grounds, never on the held-out folds, or the ensemble is fitted to
#' the cells it is then scored on.
#'
#' @param members A list of [learner()]s, or names of registered ones. Members left unnamed take
#'   their learner's own name, made unique where several members share it.
#' @param weights Weights over the members, rescaled to sum to one. Equal by default.
#' @param name Name the ensemble is reported under.
#'
#' @return A [learner()].
#'
#' @examples
#' ensemble_learner(list(glmnet_learner(alpha = 0.5), glmnet_learner(alpha = 1)))
#' ensemble_learner(list(ridge = glmnet_learner(alpha = 0), lasso = glmnet_learner(alpha = 1)))
#'
#' @export
ensemble_learner <- function(members, weights = NULL, name = "ensemble") {
  if (inherits(members, "timegrain_learner") || is.character(members)) {
    members <- list(members)
  }
  members <- lapply(members, .as_learner)
  names(members) <- make.unique(.fill_names(members), sep = "_")
  if (length(members) < 2L) {
    stop("an ensemble needs at least two members.", call. = FALSE)
  }
  if (is.null(weights)) {
    weights <- rep(1, length(members))
  }
  if (length(weights) != length(members) || any(weights < 0) || sum(weights) <= 0) {
    stop("`weights` needs one non-negative number per member and cannot be all zero.",
         call. = FALSE)
  }
  weights <- weights / sum(weights)

  learner(
    name = name,
    needs = unique(unlist(lapply(members, function(m) m$needs))),
    params = list(),
    fit = function(x, y, ...) {
      lapply(members, function(m) {
        do.call(m$fit, c(list(x = x, y = y), m$params))
      })
    },
    predict = function(model, x) {
      total <- NULL
      for (k in seq_along(model)) {
        p <- as.matrix(members[[k]]$predict(model[[k]], x)) * weights[k]
        total <- if (is.null(total)) p else total + p
      }
      total
    }
  )
}
