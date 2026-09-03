#' What part of the record a fitted model reads
#'
#' Holds one bin of the record back at a time, rescores the held-out units, and records the fall in
#' score as that bin's weight. Nothing is refitted: the models kept by
#' `window_ladder(keep_fits = TRUE)` are the ones read, so the profile describes the models that
#' produced the reported scores rather than a fresh set of them.
#'
#' A model has to be shown something in place of a held-back bin, and what it is shown decides what
#' the weight means. Permuting the bin's values across units keeps the observed readings exactly
#' and cuts only the link between a reading and its unit. Replacing every unit by the fitting-fold
#' mean removes all between-unit variation while keeping the shape of the year. Replacing the bin
#' by each unit's own mean over the record keeps how warm a unit is and removes only that bin's
#' departure from it.
#'
#' Read with `over = "channel"` the same machinery asks what each statistic of a window carries,
#' holding one channel back across the whole record instead of one bin across all channels.
#'
#' @param ladder A [window_ladder()] result fitted with `keep_fits = TRUE`.
#' @param x The representation set the ladder was fitted on.
#' @param y The response it was fitted to.
#' @param arm The arm to read, as `"window|learner"` or `"learner"`.
#' @param over `"bin"` to hold each bin back in turn, `"channel"` for each channel.
#' @param substitute What a held-back part is replaced by: `"permute"`, `"fold_mean"` or
#'   `"unit_mean"`.
#' @param metric Name of the registered metric the rescoring is read by. The area under the ROC
#'   curve responds to every reordering of the units, where a maximum over thresholds frequently
#'   does not move at all, which is why it is the default here and not for the ladder.
#' @param permutations Draws averaged over, for `substitute = "permute"`.
#' @param seed Random seed.
#'
#' @return A data frame of one row per held-back part and variable, carrying the mean weight over
#'   folds and the score with and without the part.
#'
#' @examples
#' set.seed(1)
#' t <- seq(as.POSIXct("2021-09-01", tz = "UTC"), by = "hour", length.out = 24 * 120)
#' units <- sprintf("p%02d", 1:40)
#' warmth <- rnorm(40)
#' d <- data.frame(
#'   plot = rep(units, each = length(t)), t = rep(t, length(units)),
#'   temp = as.numeric(vapply(warmth, function(w) w + sin(seq_along(t) / 300) + rnorm(length(t)),
#'                            numeric(length(t)))))
#' y <- matrix(rbinom(80, 1, plogis(c(warmth, -warmth))), nrow = 40,
#'             dimnames = list(units, c("sp1", "sp2")))
#' x <- window_matrix(d, plot, t, temp, window = "month")
#' lad <- window_ladder(x, y, elasticnet_learner(), folds = fold_map(y, v = 3),
#'                      keep_fits = TRUE, verbose = FALSE)
#' head(bin_occlusion(lad, x, y, "month|elasticnet", permutations = 3))
#'
#' @export
bin_occlusion <- function(ladder, x, y, arm, over = c("bin", "channel"),
                          substitute = c("permute", "fold_mean", "unit_mean"),
                          metric = "roc_auc", permutations = 20L, seed = 1L) {
  over <- match.arg(over)
  substitute <- match.arg(substitute)
  fits <- attr(ladder, "fits")
  if (is.null(fits)) {
    stop("this ladder kept no fits. Refit with window_ladder(..., keep_fits = TRUE).",
         call. = FALSE)
  }
  rows <- .arm_rows(ladder, arm)
  label <- attr(rows, "label")
  window <- strsplit(label, "|", fixed = TRUE)[[1L]][1L]
  set <- .as_set(x)
  m <- set[[window]]
  if (is.null(m)) {
    stop("the representation carries no \"", window, "\" window.", call. = FALSE)
  }
  units <- dimnames(m)[[1L]]
  y <- .align_response(.responses_reg$get(attr(ladder, "response"))$prepare(y), units)
  f <- .as_folds(attr(ladder, "folds"), units)
  cells <- attr(ladder, "cells")
  score <- .metrics_reg$get(metric)

  parts <- if (over == "bin") seq_len(dim(m)[2L]) else seq_len(dim(m)[3L])
  labels <- if (over == "bin") dimnames(m)[[2L]] else dimnames(m)[[3L]]

  old <- .seed_state()
  on.exit(.restore_seed(old), add = TRUE)
  set.seed(seed)

  out <- list()
  for (k in sort(unique(f))) {
    fit <- fits[[paste(label, k, sep = "|")]]
    if (is.null(fit)) {
      next
    }
    test <- which(f == k)
    train <- which(f != k)
    base <- stats::predict(fit, .subset_units(m, test))
    ok <- .scorable_for(cells, colnames(y), k)
    full <- .score_columns(y[test, , drop = FALSE], base, ok, score)

    for (i in seq_along(parts)) {
      draws <- if (substitute == "permute") permutations else 1L
      acc <- matrix(0, nrow = draws, ncol = ncol(y))
      for (r in seq_len(draws)) {
        occluded <- .occlude(m, test, train, parts[i], over, substitute)
        acc[r, ] <- .score_columns(y[test, , drop = FALSE],
                                   stats::predict(fit, occluded), ok, score)
      }
      out[[length(out) + 1L]] <- data.frame(
        part = labels[i], variable = colnames(y), fold = k,
        score_full = full, score_held_back = colMeans(acc),
        weight = full - colMeans(acc), stringsAsFactors = FALSE)
    }
  }
  out <- do.call(rbind, out)
  out <- out[!is.na(out$weight), , drop = FALSE]
  agg <- stats::aggregate(out[c("score_full", "score_held_back", "weight")],
                          out[c("part", "variable")], mean)
  agg$part <- factor(agg$part, levels = labels)
  agg <- agg[order(agg$part, agg$variable, method = "radix"), ]
  agg$part <- as.character(agg$part)
  rownames(agg) <- NULL
  structure(agg, class = c("climgrain_occlusion", "data.frame"), arm = label, over = over,
            substitute = substitute, metric = metric)
}

.occlude <- function(m, test, train, i, over, substitute) {
  sub <- .subset_units(m, test)
  n <- dim(sub)[1L]
  b <- dim(sub)[2L]
  if (over == "channel") {
    sub[, , i] <- switch(
      substitute,
      permute = .plane(sub, i)[sample.int(n), , drop = FALSE],
      fold_mean = matrix(colMeans(.plane(m, i)[train, , drop = FALSE]),
                         nrow = n, ncol = b, byrow = TRUE),
      unit_mean = matrix(rowMeans(.plane(sub, i)), nrow = n, ncol = b)
    )
    return(sub)
  }
  for (ch in seq_len(dim(sub)[3L])) {
    sub[, i, ch] <- switch(
      substitute,
      permute = sub[sample.int(n), i, ch],
      fold_mean = mean(m[train, i, ch]),
      unit_mean = rowMeans(.plane(sub, ch))
    )
  }
  sub
}

# One channel of a representation as a [unit, bin] matrix, whatever the number of bins. Dropping to
# a vector at a single bin is what makes the row and column means below silently wrong.
.plane <- function(x, channel) {
  matrix(as.numeric(x[, , channel]), nrow = dim(x)[1L], ncol = dim(x)[2L])
}

.scorable_for <- function(cells, variables, fold) {
  cells$scorable[match(paste(variables, fold), paste(cells$variable, cells$fold))]
}

.score_columns <- function(y, p, ok, score) {
  vapply(seq_len(ncol(y)), function(j) {
    if (isTRUE(ok[j])) score(y[, j], p[, j]) else NA_real_
  }, numeric(1L))
}

#' @export
print.climgrain_occlusion <- function(x, ...) {
  cat("<climgrain occlusion>", attr(x, "arm"), "read by", attr(x, "metric"), "\n")
  cat("held back:", attr(x, "over"), "; substitute:", attr(x, "substitute"), "\n")
  w <- stats::aggregate(list(weight = x$weight), x["part"], mean)
  w <- w[order(-w$weight), ]
  cat("heaviest:", paste(utils::head(w$part, 5L), collapse = ", "), "\n")
  print(utils::head(as.data.frame(x), 6L))
  invisible(x)
}
