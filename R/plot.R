#' Draw a ladder
#'
#' One line per learner across the windows, at the across-variable mean of the per-variable score,
#' with an interval from its standard error across variables. An open circle marks each learner's
#' best window, which is where the curve says the record stops paying for being read more finely.
#'
#' @param x A [window_ladder()] result.
#' @param col One colour per learner, recycled.
#' @param interval Draw the interval across variables.
#' @param ... Passed to [graphics::plot()].
#'
#' @return The summary table the plot is drawn from, invisibly.
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
#' x <- window_matrix(d, plot, t, temp, window = c("day", "week", "month"))
#' lad <- window_ladder(x, y, elasticnet_learner(), folds = fold_map(y, v = 3), verbose = FALSE)
#' plot(lad)
#'
#' @export
plot.climgrain_ladder <- function(x, col = NULL, interval = TRUE, ...) {
  per_variable <- .per_variable(x)
  windows <- unique(x$window)
  arms <- unique(x$learner)
  if (is.null(col)) {
    col <- grDevices::hcl.colors(max(length(arms), 2L), "Dark 3")[seq_along(arms)]
  }
  col <- rep_len(col, length(arms))

  stat <- lapply(arms, function(a) {
    m <- vapply(windows, function(w) {
      .mean_se(per_variable$score[per_variable$learner == a & per_variable$window == w])
    }, numeric(2L))
    data.frame(learner = a, window = windows, score = m[1L, ], se = m[2L, ],
               stringsAsFactors = FALSE)
  })
  stat <- do.call(rbind, stat)

  span <- if (interval && any(is.finite(stat$se))) {
    range(c(stat$score - 1.96 * stat$se, stat$score + 1.96 * stat$se), na.rm = TRUE)
  } else {
    range(stat$score, na.rm = TRUE)
  }
  args <- list(x = seq_along(windows), y = rep(NA_real_, length(windows)), ylim = span,
               xaxt = "n", xlab = "window", ylab = attr(x, "metric"))
  do.call(graphics::plot, utils::modifyList(args, list(...)))
  graphics::axis(1L, at = seq_along(windows), labels = windows)
  graphics::grid(nx = NA, ny = NULL, col = "grey90", lty = 1L)

  for (k in seq_along(arms)) {
    s <- stat[stat$learner == arms[k], , drop = FALSE]
    s <- s[match(windows, s$window), , drop = FALSE]
    at <- seq_along(windows)
    if (interval && any(is.finite(s$se) & s$se > 0)) {
      ok <- is.finite(s$se) & s$se > 0
      graphics::arrows(at[ok], (s$score - 1.96 * s$se)[ok], at[ok],
                       (s$score + 1.96 * s$se)[ok],
                       length = 0.03, angle = 90, code = 3L, col = col[k])
    }
    graphics::lines(at, s$score, col = col[k], lwd = 2)
    graphics::points(at, s$score, col = col[k], pch = 19L)
    best <- which.max(s$score)
    graphics::points(at[best], s$score[best], col = col[k], pch = 1L, cex = 2.2, lwd = 2)
  }
  if (length(arms) > 1L) {
    graphics::legend("bottomleft", legend = arms, col = col, lwd = 2, bty = "n")
  }
  invisible(stat)
}
