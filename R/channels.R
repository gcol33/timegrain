#' Where in the year each bin sits
#'
#' An encoder that ends in global pooling discards when a thermal event happened, so the position
#' of a bin in the year has to be given to it as input if it is to be used at all. These two
#' channels carry that position as the sine and cosine of the bin's fractional place in the year,
#' which is continuous across the turn of the year where the fraction itself is not.
#'
#' They are the time index of each bin, not a summary of the readings, so adding them introduces no
#' hand-built thermal feature: whatever a model does with them it could have done with a calendar.
#'
#' @param x A [window_matrix()] result.
#'
#' @return An array of the same units and bins with two channels, `year_sin` and `year_cos`,
#'   identical across units. Combine it with the readings using [bind_channels()].
#'
#' @examples
#' t <- seq(as.POSIXct("2021-09-01", tz = "UTC"), by = "hour", length.out = 24 * 400)
#' d <- data.frame(plot = "a", t = t, temp = sin(seq_along(t) / 500))
#' x <- window_matrix(d, plot, t, temp, window = "month")
#' round(calendar_channels(x)[1, 1:4, ], 3)
#'
#' @export
calendar_channels <- function(x) {
  .check_matrix(x)
  mid <- .bin_midpoint(x)
  year <- as.integer(format(mid, "%Y", tz = "UTC"))
  start <- as.POSIXct(paste0(year, "-01-01"), tz = "UTC")
  len <- as.numeric(as.POSIXct(paste0(year + 1L, "-01-01"), tz = "UTC")) - as.numeric(start)
  frac <- (as.numeric(mid) - as.numeric(start)) / len

  out <- array(NA_real_, dim = c(dim(x)[1L], dim(x)[2L], 2L),
               dimnames = list(dimnames(x)[[1L]], dimnames(x)[[2L]], c("year_sin", "year_cos")))
  out[, , 1L] <- rep(sinpi(2 * frac), each = dim(x)[1L])
  out[, , 2L] <- rep(cospi(2 * frac), each = dim(x)[1L])
  .carry_attrs(out, x, stats = c("year_sin", "year_cos"))
}

#' Put channels side by side
#'
#' Joins representations of the same units and bins into one array, in the order given. It is how
#' a temperature reading, an external product such as snow cover, and the calendar position of each
#' bin reach a model as one input.
#'
#' @param ... Two or more arrays of shape `[unit, bin, channel]`, agreeing on their units and bins.
#'
#' @return One array carrying every channel, with the attributes of the first argument.
#'
#' @examples
#' t <- seq(as.POSIXct("2021-09-01", tz = "UTC"), by = "hour", length.out = 24 * 60)
#' d <- data.frame(plot = rep(c("a", "b"), each = length(t)), t = rep(t, 2),
#'                 temp = rnorm(2 * length(t)))
#' x <- window_matrix(d, plot, t, temp, window = "week")
#' dimnames(bind_channels(x, calendar_channels(x)))[[3]]
#'
#' @export
bind_channels <- function(...) {
  parts <- list(...)
  if (length(parts) < 2L) {
    stop("`bind_channels()` needs at least two arrays.", call. = FALSE)
  }
  first <- parts[[1L]]
  for (k in seq_along(parts)[-1L]) {
    if (!identical(dimnames(parts[[k]])[1:2], dimnames(first)[1:2])) {
      stop("argument ", k, " covers different units or bins from the first.", call. = FALSE)
    }
  }
  names <- unlist(lapply(parts, function(p) dimnames(p)[[3L]]))
  if (anyDuplicated(names)) {
    stop("two arrays carry a channel of the same name: ",
         paste(unique(names[duplicated(names)]), collapse = ", "), ".", call. = FALSE)
  }
  out <- array(unlist(lapply(parts, as.numeric), use.names = FALSE),
               dim = c(dim(first)[1:2], length(names)),
               dimnames = c(dimnames(first)[1:2], list(names)))
  .carry_attrs(out, first, stats = names)
}

.check_matrix <- function(x) {
  if (!inherits(x, "climgrain_matrix")) {
    stop("expected a window_matrix() result, got ", class(x)[1L], ".", call. = FALSE)
  }
  invisible(TRUE)
}

# A bin's calendar position is read at the middle of the record it holds, so a bin the record only
# partly covers lands at the phase it was actually measured over rather than at the phase of a
# whole one.
.bin_midpoint <- function(x) {
  s <- attr(x, "bin_start")
  e <- attr(x, "bin_end")
  .POSIXct((as.numeric(s) + as.numeric(e)) / 2, tz = attr(s, "tzone"))
}

.carry_attrs <- function(out, from, stats) {
  attr(out, "window") <- attr(from, "window")
  attr(out, "stats") <- stats
  attr(out, "year_start") <- attr(from, "year_start")
  attr(out, "bin_start") <- attr(from, "bin_start")
  attr(out, "bin_end") <- attr(from, "bin_end")
  attr(out, "bin_n") <- attr(from, "bin_n")
  attr(out, "bin_partial") <- attr(from, "bin_partial")
  class(out) <- c("climgrain_matrix", "array")
  out
}
