#' Define a learner
#'
#' A learner is a pair of functions: one that fits a model to a representation and a response, and
#' one that predicts from it. Everything the package fits goes through this pair, so a learner of
#' your own sits beside the ones that ship and needs no change to the ladder, the folds or the
#' scoring.
#'
#' @param name Name the learner is reported under.
#' @param fit A function of `(x, y, ...)`, where `x` is a `[unit, bin, channel]` array and `y` the
#'   response matrix for the same units, returning a fitted object.
#' @param predict A function of `(model, x)` returning a `[unit, variable]` matrix of predictions
#'   for the units of `x`, in that order.
#' @param needs Packages the learner requires. A learner that cannot run says so at once rather
#'   than falling back to something else.
#' @param params Settings carried with the learner and passed to `fit`.
#'
#' @return A `climgrain_learner`.
#'
#' @examples
#' # The bin means of a unit, fed to one logistic regression per variable.
#' flat_glm <- learner(
#'   "flat_glm",
#'   fit = function(x, y, ...) {
#'     f <- as.data.frame(apply(x, c(1, 3), mean))
#'     lapply(seq_len(ncol(y)), function(j)
#'       stats::glm(y[, j] ~ ., data = f, family = stats::binomial()))
#'   },
#'   predict = function(model, x) {
#'     f <- as.data.frame(apply(x, c(1, 3), mean))
#'     vapply(model, function(m) stats::predict(m, f, type = "response"), numeric(nrow(f)))
#'   }
#' )
#' flat_glm
#'
#' @export
learner <- function(name, fit, predict, needs = character(), params = list()) {
  if (!is.function(fit) || !is.function(predict)) {
    stop("a learner needs a `fit` and a `predict` function.", call. = FALSE)
  }
  structure(list(name = name, fit = fit, predict = predict, needs = needs, params = params),
            class = "climgrain_learner")
}

#' @export
print.climgrain_learner <- function(x, ...) {
  cat("<climgrain learner>", x$name, "\n")
  if (length(x$params)) {
    cat("settings:", paste(names(x$params), vapply(x$params, .describe, character(1L)),
                           sep = " = ", collapse = ", "), "\n")
  }
  if (length(x$needs)) {
    cat("needs   :", paste(x$needs, collapse = ", "), "\n")
  }
  invisible(x)
}

.describe <- function(v) {
  if (is.null(v)) "NULL" else paste(format(v), collapse = "/")
}

#' Register a learner
#'
#' Makes a learner available by name to [window_ladder()] and to [learners()]. The learners that
#' ship are registered the same way, so there is no list of names inside the fitting code.
#'
#' @param name Name the learner is asked for by.
#' @param constructor A function returning a [learner()].
#' @param overwrite Replace an existing registration.
#'
#' @return The constructor, invisibly.
#'
#' @examples
#' learners()
#'
#' @export
register_learner <- function(name, constructor, overwrite = FALSE) {
  if (!is.function(constructor)) {
    stop("a learner registration takes a function returning a learner().", call. = FALSE)
  }
  .learners_reg$set(name, constructor, overwrite)
}

#' @rdname register_learner
#' @export
learners <- function() .learners_reg$names()

#' Fit one learner at one grain
#'
#' @param learner A [learner()], or the name of a registered one.
#' @param x A [window_matrix()] result.
#' @param y The response for the same units.
#' @param response Name of the registered response head. `"presence_absence"` ships.
#' @param ... Passed to the learner's `fit`.
#'
#' @return A `climgrain_fit`, which [stats::predict()] takes a new representation.
#'
#' @examples
#' set.seed(1)
#' t <- seq(as.POSIXct("2021-09-01", tz = "UTC"), by = "hour", length.out = 24 * 120)
#' units <- sprintf("p%02d", 1:40)
#' d <- data.frame(plot = rep(units, each = length(t)), t = rep(t, length(units)),
#'                 temp = as.numeric(replicate(length(units), rnorm(length(t)))))
#' x <- window_matrix(d, plot, t, temp, window = "month")
#' y <- matrix(rbinom(80, 1, 0.4), nrow = 40, dimnames = list(units, c("sp1", "sp2")))
#' fit <- fit_learner(elasticnet_learner(), x, y)
#' dim(stats::predict(fit, x))
#'
#' @export
fit_learner <- function(learner, x, y, response = "presence_absence", ...) {
  learner <- .as_learner(learner)
  .require_packages(learner)
  .check_matrix(x)
  spec <- .responses_reg$get(response)
  y <- spec$prepare(y)
  y <- .align_response(y, dimnames(x)[[1L]])
  # A setting given here overrides the one the learner carries, rather than reaching `fit` twice.
  given <- list(...)
  carried <- learner$params[setdiff(names(learner$params), names(given))]
  model <- do.call(learner$fit, c(list(x = x, y = y), carried, given))
  structure(list(learner = learner, model = model, response = response,
                 variables = colnames(y), window = attr(x, "window"),
                 stats = attr(x, "stats")),
            class = "climgrain_fit")
}

#' @param object A `climgrain_fit`.
#' @param newdata A representation of the same channels for the units to predict.
#' @rdname fit_learner
#' @export
predict.climgrain_fit <- function(object, newdata, ...) {
  p <- object$learner$predict(object$model, newdata)
  p <- as.matrix(p)
  if (nrow(p) != dim(newdata)[1L]) {
    stop("the learner returned ", nrow(p), " rows for ", dim(newdata)[1L], " units.",
         call. = FALSE)
  }
  dimnames(p) <- list(dimnames(newdata)[[1L]], object$variables)
  p
}

#' @export
print.climgrain_fit <- function(x, ...) {
  cat("<climgrain fit>", x$learner$name, "at the", x$window, "window\n")
  cat("channels:", paste(x$stats, collapse = ", "), "\n")
  cat("response:", x$response, "on", .plural(length(x$variables), "variable"), "\n")
  invisible(x)
}

.as_learner <- function(learner) {
  if (inherits(learner, "climgrain_learner")) {
    return(learner)
  }
  if (is.character(learner) && length(learner) == 1L) {
    return(.learners_reg$get(learner)())
  }
  stop("expected a learner() or the name of a registered one, got ", class(learner)[1L], ".",
       call. = FALSE)
}

# A learner that needs a package says so and stops. Two code paths, one with the package and one
# without, drift apart and the difference surfaces as a result nobody can place.
.require_packages <- function(learner) {
  missing <- learner$needs[!vapply(learner$needs, requireNamespace, logical(1L), quietly = TRUE)]
  if (length(missing)) {
    stop("the ", learner$name, " learner needs ", paste(missing, collapse = " and "),
         ". Install it with install.packages(\"", missing[1L], "\").", call. = FALSE)
  }
  invisible(TRUE)
}

.align_response <- function(y, units) {
  if (identical(rownames(y), units)) {
    return(y)
  }
  missing <- setdiff(units, rownames(y))
  if (length(missing)) {
    stop(length(missing), " unit", if (length(missing) > 1L) "s are" else " is",
         " in the representation but not the response, first: ", missing[1L], ".", call. = FALSE)
  }
  y[units, , drop = FALSE]
}

# Flatten [unit, bin, channel] to [unit, bin * channel] in the array's own order, so the column
# names say which bin and which channel every predictor came from.
.flatten <- function(x) {
  d <- dim(x)
  out <- matrix(as.numeric(x), nrow = d[1L], ncol = d[2L] * d[3L])
  dimnames(out) <- list(dimnames(x)[[1L]],
                        paste(rep(dimnames(x)[[3L]], each = d[2L]),
                              rep(dimnames(x)[[2L]], times = d[3L]), sep = "@"))
  out
}

# Scaling belongs to the fold it is computed on. A per-column scaler is what a linear model wants;
# a single scalar over every channel and bin is what a sequence encoder wants, because it puts the
# readings on a workable scale while preserving the differences between units that carry the
# signal. Both are computed on the fitting units alone.
.scaler <- function(m, per_column = TRUE) {
  if (per_column) {
    centre <- colMeans(m)
    scale <- apply(m, 2L, stats::sd)
  } else {
    centre <- rep(mean(m), ncol(m))
    scale <- rep(stats::sd(as.numeric(m)), ncol(m))
  }
  scale[!is.finite(scale) | scale < 1e-8] <- 1
  list(centre = centre, scale = scale)
}

.apply_scaler <- function(s, m) {
  sweep(sweep(m, 2L, s$centre, "-"), 2L, s$scale, "/")
}
