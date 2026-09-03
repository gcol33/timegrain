#' A ladder of representations, one per window
#'
#' Naming several windows in [window_matrix()] returns one of these: a named list of
#' representations of the same units, differing only in how coarsely the record was read. It is
#' what [window_ladder()] fits across.
#'
#' @param x A named list of [window_matrix()] results, or a single one.
#'
#' @return A `climgrain_set`: the list, with the names as window labels.
#'
#' @examples
#' t <- seq(as.POSIXct("2021-09-01", tz = "UTC"), by = "hour", length.out = 24 * 60)
#' d <- data.frame(plot = rep(c("a", "b"), each = length(t)), t = rep(t, 2),
#'                 temp = rnorm(2 * length(t)))
#' s <- window_matrix(d, plot, t, temp, window = c("day", "week", "month"))
#' s
#' names(s)
#'
#' @export
climgrain_set <- function(x) {
  if (inherits(x, "climgrain_matrix")) {
    x <- stats::setNames(list(x), attr(x, "window"))
  }
  if (!is.list(x) || !length(x)) {
    stop("a climgrain set is a non-empty list of window_matrix() results.", call. = FALSE)
  }
  if (is.null(names(x)) || anyDuplicated(names(x)) || any(!nzchar(names(x)))) {
    stop("every element of a climgrain set needs its own name.", call. = FALSE)
  }
  ok <- vapply(x, inherits, logical(1L), "climgrain_matrix")
  if (!all(ok)) {
    stop("element", if (sum(!ok) > 1L) "s" else "", " ",
         paste(names(x)[!ok], collapse = ", "), " ",
         if (sum(!ok) > 1L) "are" else "is", " not a window_matrix() result.", call. = FALSE)
  }
  units <- lapply(x, function(m) dimnames(m)[[1L]])
  same <- vapply(units, identical, logical(1L), units[[1L]])
  if (!all(same)) {
    stop("every window in a set must cover the same units; ",
         paste(names(x)[!same], collapse = ", "), " does not.", call. = FALSE)
  }
  structure(x, class = "climgrain_set")
}

#' @export
print.climgrain_set <- function(x, ...) {
  cat("<climgrain set>", .plural(length(x), "window"), "over",
      .plural(dim(x[[1L]])[1L], "unit"), "\n")
  for (nm in names(x)) {
    m <- x[[nm]]
    cat(sprintf("  %-10s %5d bins x %d channels (%s)\n", nm, dim(m)[2L], dim(m)[3L],
                paste(attr(m, "stats"), collapse = ", ")))
  }
  invisible(x)
}

#' @export
`[.climgrain_set` <- function(x, i) {
  climgrain_set(NextMethod())
}

# Every entry point that fits across windows takes a matrix, a set, or a bare named list, and
# works on a set. One coercion, so no caller repeats the three cases.
.as_set <- function(x) {
  if (inherits(x, "climgrain_set")) {
    return(x)
  }
  climgrain_set(x)
}
