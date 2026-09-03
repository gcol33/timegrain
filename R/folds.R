#' Assign units to cross-validation folds
#'
#' One fold map, built once and read by everything that scores. Every learner in a ladder is then
#' fitted and scored on identical splits, which is what makes the comparison between them paired
#' rather than a comparison of two clouds of numbers.
#'
#' Units are held out singly. Where the input a model reads is measured at the unit itself, as a
#' logger in each plot is, a held-out unit brings its own measured input with it and nothing of its
#' neighbours' reaches the model.
#'
#' Folds are balanced within strata: units are grouped into `strata` equal-count groups of the
#' stratifying value, shuffled inside each group, and dealt round-robin, so each fold carries the
#' same mix. With a multi-variable response the default stratifies on richness, the number of
#' variables present at a unit, because one fold map has to serve every variable at once and cannot
#' be stratified on any single one of them.
#'
#' @param y The response: a matrix or data frame of units by variables, with unit identifiers in
#'   the row names or in a leading character or factor column.
#' @param v Number of folds.
#' @param seed Random seed, fixed so the map is reproducible.
#' @param strata Number of strata, or `1` for no stratification.
#' @param by A numeric vector of length `nrow(y)` to stratify on instead of richness.
#'
#' @return An integer vector of fold numbers named by unit, of class `timegrain_folds`. Any named
#'   integer vector of the same shape is accepted wherever this is.
#'
#' @examples
#' y <- matrix(rbinom(300, 1, 0.3), nrow = 60,
#'             dimnames = list(sprintf("p%02d", 1:60), paste0("sp", 1:5)))
#' f <- fold_map(y, v = 5)
#' table(f)
#'
#' @export
fold_map <- function(y, v = 10L, seed = 1L, strata = 5L, by = NULL) {
  y <- .as_response(y)
  n <- nrow(y)
  if (v < 2L || v > n) {
    stop("`v` must be between 2 and the ", n, " units, got ", v, ".", call. = FALSE)
  }
  value <- if (is.null(by)) rowSums(y) else as.numeric(by)
  if (length(value) != n) {
    stop("`by` must have one value per unit, got ", length(value), " for ", n, ".", call. = FALSE)
  }
  stratum <- if (strata <= 1L) rep(1L, n) else .quantile_strata(value, strata)

  old <- .seed_state()
  on.exit(.restore_seed(old), add = TRUE)
  set.seed(seed)

  fold <- integer(n)
  for (s in unique(stratum)) {
    idx <- which(stratum == s)
    # Permute by position, never by value: sample() on a length-one vector samples 1:x instead of
    # returning x, so a stratum holding a single unit would scatter one fold over every position
    # below that unit's index and leave the map degenerate with nothing raised.
    fold[idx[sample.int(length(idx))]] <- rep_len(sample.int(v), length(idx))
  }
  structure(stats::setNames(fold, rownames(y)), v = as.integer(v), seed = seed,
            strata = as.integer(strata), class = "timegrain_folds")
}

#' @export
print.timegrain_folds <- function(x, ...) {
  cat("<timegrain folds>", .plural(length(x), "unit"), "in",
      .plural(attr(x, "v"), "fold"), "\n")
  print(table(fold = unclass(x)))
  invisible(x)
}

# Equal-count strata, with a value that fills more than one stratum's worth of the sample folded
# into a single stratum rather than split across boundaries it cannot be told apart on.
.quantile_strata <- function(value, k) {
  breaks <- unique(stats::quantile(value, probs = seq(0, 1, length.out = k + 1L), type = 7))
  if (length(breaks) < 3L) {
    return(rep(1L, length(value)))
  }
  as.integer(cut(value, breaks, include.lowest = TRUE, labels = FALSE))
}

# Seeding is a side effect on the session, so every entry point that seeds restores what was there.
.seed_state <- function() {
  if (exists(".Random.seed", envir = globalenv(), inherits = FALSE)) {
    get(".Random.seed", envir = globalenv(), inherits = FALSE)
  } else {
    NULL
  }
}

.restore_seed <- function(state) {
  if (is.null(state)) {
    suppressWarnings(rm(".Random.seed", envir = globalenv()))
  } else {
    assign(".Random.seed", state, envir = globalenv())
  }
  invisible(TRUE)
}

# A fold map reaches the fitting path as an integer vector in the row order of the representation,
# whether it arrived named, bare, or as a two-column table.
.as_folds <- function(folds, units) {
  if (is.data.frame(folds)) {
    if (ncol(folds) != 2L) {
      stop("a fold table needs two columns, a unit identifier and a fold.", call. = FALSE)
    }
    folds <- stats::setNames(as.integer(folds[[2L]]), as.character(folds[[1L]]))
  }
  if (!is.null(names(folds))) {
    missing <- setdiff(units, names(folds))
    if (length(missing)) {
      stop(length(missing), " unit", if (length(missing) > 1L) "s have" else " has",
           " no fold, first: ", missing[1L], ".", call. = FALSE)
    }
    folds <- folds[units]
  } else if (length(folds) != length(units)) {
    stop("an unnamed fold map must have one entry per unit, got ", length(folds),
         " for ", length(units), ".", call. = FALSE)
  }
  out <- as.integer(unname(folds))
  if (anyNA(out)) {
    stop("the fold map holds missing values.", call. = FALSE)
  }
  out
}
