#' Fit at every grain and see where skill saturates
#'
#' Cross-validates every learner at every window of a representation set, on one fold map and one
#' mask of scorable cells, and returns the score of each `(window, learner, variable, fold)` cell.
#' It is the measurement the package exists for: how much of a record a model needs, read off the
#' point where making the record finer stops paying.
#'
#' Every arm sees identical splits and is restricted to identical cells, so the arms' means share a
#' denominator and any two of them can be compared cell by cell with [paired_contrast()].
#'
#' @param x A [window_matrix()] result, a [climgrain_set()], or a named list of representations.
#' @param y The response for the same units.
#' @param learners A learner, a list of them, or names of registered ones. An unnamed list is
#'   labelled by each learner's own name.
#' @param folds A fold map from [fold_map()], or any named integer vector. Built with the defaults
#'   of [fold_map()] when not given.
#' @param response Name of the registered response head.
#' @param metric Name of the registered metric, or `NULL` for the response's own.
#' @param keep_fits Keep every per-fold fitted model, which is what lets [bin_occlusion()] read a
#'   fitted model without refitting it.
#' @param verbose Report each arm and each fold as it runs.
#' @param ... Ignored, so that `summary()` takes the arguments its generic declares.
#'
#' @return A data frame of one row per scored cell, of class `climgrain_ladder`, carrying the
#'   window, the learner, the variable, the fold and the score. The held-out prediction of every
#'   unit is kept in the `predictions` attribute, and the scorable-cell mask in `cells`.
#'
#' @examples
#' set.seed(1)
#' t <- seq(as.POSIXct("2021-09-01", tz = "UTC"), by = "hour", length.out = 24 * 200)
#' units <- sprintf("p%02d", 1:60)
#' warmth <- rnorm(60)
#' d <- data.frame(
#'   plot = rep(units, each = length(t)), t = rep(t, length(units)),
#'   temp = as.numeric(vapply(warmth, function(w) w + sin(seq_along(t) / 300) + rnorm(length(t)),
#'                            numeric(length(t)))))
#' y <- matrix(rbinom(120, 1, plogis(c(warmth, -warmth))), nrow = 60,
#'             dimnames = list(units, c("sp1", "sp2")))
#' x <- window_matrix(d, plot, t, temp, window = c("week", "month"))
#' lad <- window_ladder(x, y, elasticnet_learner(), folds = fold_map(y, v = 3), verbose = FALSE)
#' summary(lad)
#'
#' @export
window_ladder <- function(x, y, learners, folds = NULL, response = "presence_absence",
                          metric = NULL, keep_fits = FALSE, verbose = TRUE) {
  set <- .as_set(x)
  units <- dimnames(set[[1L]])[[1L]]
  spec <- .responses_reg$get(response)
  y <- .align_response(spec$prepare(y), units)
  if (is.null(folds)) {
    folds <- fold_map(y)
  }
  f <- .as_folds(folds, units)
  cells <- spec$cells(y, stats::setNames(f, units))
  score <- .metrics_reg$get(metric %||% spec$metric)
  learners <- .learner_list(learners)

  levels <- sort(unique(f))
  rows <- list()
  preds <- list()
  fits <- list()
  for (w in names(set)) {
    for (ln in names(learners)) {
      arm <- paste(w, ln, sep = "|")
      if (verbose) {
        message("fitting ", ln, " at the ", w, " window")
      }
      p <- matrix(NA_real_, nrow = length(units), ncol = ncol(y),
                  dimnames = list(units, colnames(y)))
      for (k in levels) {
        started <- Sys.time()
        train <- which(f != k)
        test <- which(f == k)
        fit <- fit_learner(learners[[ln]], .subset_units(set[[w]], train),
                           y[train, , drop = FALSE], response = response)
        held_out <- stats::predict(fit, .subset_units(set[[w]], test))
        if (verbose) {
          # A grid over the real record runs for hours, and an arm that reports only when it is
          # finished is indistinguishable from one that has hung.
          message(sprintf("  fold %s of %d, %.0f s", k, length(levels),
                          as.numeric(difftime(Sys.time(), started, units = "secs"))))
        }
        # Keyed on both axes rather than positional: a learner returning its variables in another
        # order would otherwise scramble which prediction belongs to which one, silently.
        p[rownames(held_out), colnames(held_out)] <- held_out
        if (keep_fits) {
          fits[[paste(arm, k, sep = "|")]] <- fit
        }
      }
      preds[[arm]] <- p
      rows[[arm]] <- .score_arm(w, ln, y, p, f, levels, cells, score)
    }
  }
  out <- do.call(rbind, rows)
  rownames(out) <- NULL
  structure(out, class = c("climgrain_ladder", "data.frame"),
            predictions = preds, cells = cells, folds = stats::setNames(f, units),
            fits = if (keep_fits) fits else NULL,
            metric = metric %||% spec$metric, response = response)
}

.score_arm <- function(window, learner, y, p, f, levels, cells, score) {
  grid <- expand.grid(variable = colnames(y), fold = levels,
                      KEEP.OUT.ATTRS = FALSE, stringsAsFactors = FALSE)
  key <- paste(grid$variable, grid$fold)
  ok <- cells$scorable[match(key, paste(cells$variable, cells$fold))]
  ok[is.na(ok)] <- FALSE
  value <- rep(NA_real_, nrow(grid))
  for (i in which(ok)) {
    rows <- f == grid$fold[i]
    value[i] <- score(y[rows, grid$variable[i]], p[rows, grid$variable[i]])
  }
  data.frame(window = window, learner = learner, variable = grid$variable, fold = grid$fold,
             score = value, scorable = ok, stringsAsFactors = FALSE)
}

.subset_units <- function(x, idx) {
  out <- x[idx, , , drop = FALSE]
  attr(out, "window") <- attr(x, "window")
  attr(out, "stats") <- attr(x, "stats")
  attr(out, "year_start") <- attr(x, "year_start")
  attr(out, "bin_start") <- attr(x, "bin_start")
  attr(out, "bin_end") <- attr(x, "bin_end")
  attr(out, "bin_n") <- attr(x, "bin_n")[idx, , drop = FALSE]
  attr(out, "bin_partial") <- attr(x, "bin_partial")
  class(out) <- c("climgrain_matrix", "array")
  out
}

.learner_list <- function(learners) {
  if (inherits(learners, "climgrain_learner") || is.character(learners)) {
    learners <- list(learners)
  }
  learners <- lapply(learners, .as_learner)
  names(learners) <- .fill_names(learners)
  if (anyDuplicated(names(learners))) {
    stop("two learners are reported under the same name: ",
         paste(unique(names(learners)[duplicated(names(learners))]), collapse = ", "),
         ". Name the list to tell them apart.", call. = FALSE)
  }
  learners
}

# A learner names itself where the caller did not. In a ladder those names are reported columns, so
# a clash there is an error; inside an ensemble they are only labels, so a clash is made unique.
.fill_names <- function(learners) {
  given <- names(learners)
  auto <- vapply(learners, function(l) l$name, character(1L))
  if (is.null(given)) auto else ifelse(nzchar(given), given, auto)
}

#' @export
print.climgrain_ladder <- function(x, ...) {
  cat("<climgrain ladder>", .plural(length(unique(x$window)), "window"), "x",
      .plural(length(unique(x$learner)), "learner"), "\n")
  cat("metric:", attr(x, "metric"), "on", .plural(sum(x$scorable), "scorable cell"), "\n")
  print(summary(x))
  invisible(x)
}

#' @param object A ladder.
#' @rdname window_ladder
#' @export
summary.climgrain_ladder <- function(object, ...) {
  per_variable <- .per_variable(object)
  if (!nrow(per_variable)) {
    return(data.frame(learner = character(), window = character(), score = numeric(),
                      n_variable = integer(), best = logical(), stringsAsFactors = FALSE))
  }
  key <- per_variable[c("learner", "window")]
  out <- merge(stats::aggregate(list(score = per_variable$score), key, mean),
               stats::aggregate(list(n_variable = per_variable$score), key, length),
               by = c("learner", "window"))
  windows <- unique(object$window)
  out <- out[order(out$learner, match(out$window, windows), method = "radix"), ]
  # One window per learner is the best, even where two tie: it is the reference a contrast is read
  # against, and a reference has to be a single window.
  out$best <- stats::ave(out$score, out$learner,
                         FUN = function(v) seq_along(v) == which.max(v)) == 1
  rownames(out) <- NULL
  out
}

# A variable is the independent replicate, so a cell mean is taken within a variable over its folds
# before anything is averaged across variables. Averaging cells directly would weight a variable by
# how many folds it happened to be scorable in.
.per_variable <- function(ladder) {
  keep <- ladder[!is.na(ladder$score), , drop = FALSE]
  if (!nrow(keep)) {
    return(keep[c("window", "learner", "variable", "score")])
  }
  stats::aggregate(list(score = keep$score), keep[c("window", "learner", "variable")],
                   mean)
}

# A level and the spread of the variables it was averaged over, in one place, so a ladder and a
# selection report the same quantity computed the same way.
.mean_se <- function(v) {
  ok <- !is.na(v)
  c(mean(v[ok]), stats::sd(v[ok]) / sqrt(sum(ok)))
}

`%||%` <- function(a, b) if (is.null(a)) b else a
