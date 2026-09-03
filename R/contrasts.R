#' Compare every window against a learner's best one
#'
#' A mixed model on the per-cell scores of one learner, `score ~ window + (1 | variable) +
#' (1 | fold)`, fitted by restricted maximum likelihood. Every window is then compared against the
#' reference by Dunnett's many-to-one procedure, which corrects for the comparisons made without
#' correcting for pairs nobody asked about.
#'
#' The design is balanced across variables, folds and windows, so each window is compared within a
#' variable and within a fold and the variation between variables cancels from the comparison. That
#' is what lets a difference of 0.015 hold up where absolute skill ranges across variables by ten
#' times as much.
#'
#' Taking the best-observed window as the reference is a choice that favours the reference, so read
#' this beside the paired differences [paired_contrast()] gives, which single out no window.
#'
#' @param ladder A [window_ladder()] result.
#' @param learner Which learner's grid to fit. The only one in the ladder by default.
#' @param reference The window every other is compared against. The learner's best by default.
#' @param adjust Multiplicity adjustment passed to `emmeans::contrast()`.
#'
#' @return A data frame of one row per window: the estimated marginal mean difference from the
#'   reference, its interval, and the adjusted p-value. Needs `lme4`, `lmerTest` and `emmeans`.
#'
#' @examples
#' \donttest{
#' set.seed(1)
#' t <- seq(as.POSIXct("2021-09-01", tz = "UTC"), by = "hour", length.out = 24 * 200)
#' units <- sprintf("p%03d", 1:60)
#' warmth <- rnorm(60)
#' d <- data.frame(
#'   plot = rep(units, each = length(t)), t = rep(t, length(units)),
#'   temp = as.numeric(vapply(warmth, function(w) 1.5 * w + rnorm(length(t), sd = 20),
#'                            numeric(length(t)))))
#' y <- matrix(rbinom(60 * 6, 1, plogis(3 * as.numeric(outer(warmth, rep(c(1, -1), 3))))),
#'             ncol = 6, dimnames = list(units, paste0("sp", 1:6)))
#' x <- window_matrix(d, plot, t, temp, window = c("day", "week", "month"))
#' lad <- window_ladder(x, y, elasticnet_learner(), folds = fold_map(y, v = 5), verbose = FALSE)
#' if (requireNamespace("emmeans", quietly = TRUE)) window_contrasts(lad)
#' }
#'
#' @export
window_contrasts <- function(ladder, learner = NULL, reference = NULL, adjust = "mvt") {
  for (p in c("lme4", "lmerTest", "emmeans")) {
    if (!requireNamespace(p, quietly = TRUE)) {
      stop("`window_contrasts()` needs ", p, ". Install it with install.packages(\"", p, "\").",
           call. = FALSE)
    }
  }
  if (!inherits(ladder, "climgrain_ladder")) {
    stop("expected a window_ladder() result, got ", class(ladder)[1L], ".", call. = FALSE)
  }
  arms <- unique(ladder$learner)
  if (is.null(learner)) {
    if (length(arms) != 1L) {
      stop("this ladder holds ", length(arms), " learners; name the one to fit: ",
           paste(arms, collapse = ", "), ".", call. = FALSE)
    }
    learner <- arms[1L]
  }
  d <- ladder[ladder$learner == learner & !is.na(ladder$score), , drop = FALSE]
  if (!nrow(d)) {
    stop("no scored cell for learner \"", learner, "\".", call. = FALSE)
  }
  windows <- unique(ladder$window[ladder$learner == learner])
  if (length(windows) < 2L) {
    stop("a window contrast needs at least two windows, this ladder has ", length(windows), ".",
         call. = FALSE)
  }
  if (is.null(reference)) {
    s <- summary(ladder)
    reference <- s$window[s$learner == learner & s$best]
  }
  if (!reference %in% windows) {
    stop("\"", reference, "\" is not a window of this ladder.", call. = FALSE)
  }

  d$window <- factor(d$window, levels = c(reference, setdiff(windows, reference)))
  d$variable <- factor(d$variable)
  d$fold <- factor(d$fold)
  fit <- lmerTest::lmer(score ~ window + (1 | variable) + (1 | fold), data = d, REML = TRUE)
  means <- emmeans::emmeans(fit, "window", lmer.df = "satterthwaite")
  # trt.vs.ctrl gives every window minus the reference, so a window scoring below its learner's
  # best carries a negative difference, which is the direction the comparison is read in.
  comparison <- emmeans::contrast(means, method = "trt.vs.ctrl", ref = 1L, adjust = adjust)
  out <- as.data.frame(stats::confint(comparison))
  out$p_value <- as.data.frame(comparison)$p.value
  names(out)[names(out) == "estimate"] <- "diff"
  names(out)[names(out) == "lower.CL"] <- "lower"
  names(out)[names(out) == "upper.CL"] <- "upper"
  out$window <- sub(paste0(" - ", reference, "$"), "", as.character(out$contrast))
  out$learner <- learner
  out$reference <- reference
  rownames(out) <- NULL
  out[c("learner", "window", "reference", "diff", "lower", "upper", "p_value")]
}
