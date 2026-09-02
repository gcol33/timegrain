#' Reduce sensor series to a temporal grain
#'
#' Bins each unit's readings by the calendar and summarises every bin by one or more statistics,
#' returning the array a model is fitted on. The reduction is the choice the package exists to
#' make explicit: `window` sets how coarse the record becomes, `stats` sets what survives the
#' reduction, and the two are not interchangeable.
#'
#' @param data A data frame of readings in long form, one row per reading.
#' @param id Column identifying the unit carrying the sensor. A bare column name or a string.
#' @param time Column of reading instants, `POSIXct`. A bare column name or a string.
#' @param value Column of readings, numeric. A bare column name or a string.
#' @param window One of `"hour"`, `"halfday"`, `"day"`, `"week"`, `"month"`, `"season"`,
#'   `"year"`. The four coarse windows follow the calendar, so a bin is a real week or month
#'   rather than a fixed block of hours.
#' @param stats Statistics to compute per bin, one channel each, in the order given. See Details.
#' @param year_start `"MM-DD"` boundary of the hydrological year, used by `"season"` and
#'   `"year"`. Defaults to `"09-01"`.
#'
#' @details
#' Five statistics are available, and the distinction between an extreme reading and an extreme
#' day is deliberate rather than pedantic:
#'
#' \itemize{
#'   \item `mean`: arithmetic mean of the readings in the bin.
#'   \item `min`, `max`: coldest and warmest single reading in the bin.
#'   \item `cold_day`, `warm_day`: coldest and warmest day, each day first reduced to its own
#'     mean. Defined for `"day"` and coarser.
#' }
#'
#' An extreme day is a state the unit was in; an extreme reading can be one hour. On alpine soil
#' temperature the day-level pair carries more predictive signal than the bin mean, and by more
#' the coarser the bin.
#'
#' Nothing is standardised here. Scaling belongs to the fold it is computed on, never to the
#' representation, because computing it over all units would leak held-out units into the input.
#'
#' @return A numeric array of shape `[unit, bin, channel]`, with dimnames giving the sorted unit
#'   identifiers, the ISO-8601 start of each bin, and the statistic names. Attributes:
#'   \itemize{
#'     \item `window`: the window name.
#'     \item `stats`: the statistic names in channel order.
#'     \item `year_start`: the boundary used.
#'     \item `bin_start`: the bin start instants, `POSIXct`.
#'     \item `bin_n`: a `[unit, bin]` matrix of how many readings fell in each bin.
#'   }
#'
#' @examples
#' t <- seq(as.POSIXct("2021-09-01", tz = "UTC"), by = "hour", length.out = 24 * 40)
#' d <- data.frame(plot = rep(c("a", "b"), each = length(t)),
#'                 t = rep(t, 2),
#'                 temp = c(sin(seq_along(t) / 24), cos(seq_along(t) / 24)))
#' x <- window_matrix(d, plot, t, temp, window = "week",
#'                    stats = c("cold_day", "mean", "warm_day"))
#' dim(x)
#' dimnames(x)[[3]]
#'
#' @export
window_matrix <- function(data,
                          id,
                          time,
                          value,
                          window = "day",
                          stats = "mean",
                          year_start = "09-01") {
  id_col <- .resolve_column(substitute(id), data, parent.frame())
  time_col <- .resolve_column(substitute(time), data, parent.frame())
  value_col <- .resolve_column(substitute(value), data, parent.frame())

  window <- match.arg(window, .windows())
  stats <- .check_stats(stats, window)
  ys <- .parse_year_start(year_start)

  unit <- as.character(data[[id_col]])
  when <- data[[time_col]]
  reading <- as.numeric(data[[value_col]])

  if (!inherits(when, "POSIXct")) {
    stop("`", time_col, "` must be POSIXct, not ", class(when)[1L], ".", call. = FALSE)
  }
  tz <- attr(when, "tzone")
  if (is.null(tz) || !nzchar(tz)) tz <- "UTC"

  .check_readings(unit, when, reading, id_col, time_col, value_col)

  bin_start <- .bin_start(when, window, ys, tz)
  units <- sort(unique(unit))
  bins <- sort(unique(bin_start))
  n_u <- length(units)
  n_b <- length(bins)
  n_cell <- n_u * n_b

  cell <- (match(bin_start, bins) - 1L) * n_u + match(unit, units)
  count <- tabulate(cell, nbins = n_cell)
  .check_grid(count, units, bins, n_u)

  out <- array(NA_real_,
               dim = c(n_u, n_b, length(stats)),
               dimnames = list(units, format(bins, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"), stats))

  day_cell <- if (any(stats %in% .day_level_stats())) {
    .day_cells(reading, unit, when, bin_start, units, bins, ys, tz)
  } else {
    NULL
  }

  for (k in seq_along(stats)) {
    out[, , k] <- switch(
      stats[k],
      mean = matrix(.group_sum(reading, cell, n_cell) / count, nrow = n_u, ncol = n_b),
      min = matrix(.group_edge(reading, cell, n_cell, FALSE), nrow = n_u, ncol = n_b),
      max = matrix(.group_edge(reading, cell, n_cell, TRUE), nrow = n_u, ncol = n_b),
      cold_day = matrix(.group_edge(day_cell$value, day_cell$cell, n_cell, FALSE),
                        nrow = n_u, ncol = n_b),
      warm_day = matrix(.group_edge(day_cell$value, day_cell$cell, n_cell, TRUE),
                        nrow = n_u, ncol = n_b)
    )
  }

  attr(out, "window") <- window
  attr(out, "stats") <- stats
  attr(out, "year_start") <- year_start
  attr(out, "bin_start") <- bins
  attr(out, "bin_n") <- matrix(count, nrow = n_u, ncol = n_b, dimnames = dimnames(out)[1:2])
  class(out) <- c("timegrain_matrix", class(out))
  out
}

#' @export
print.timegrain_matrix <- function(x, ...) {
  d <- dim(x)
  cat("<timegrain matrix>", .plural(d[1L], "unit"), "x", .plural(d[2L], "bin"),
      "x", .plural(d[3L], "channel"), "\n")
  cat("window:", attr(x, "window"), "  stats:", paste(attr(x, "stats"), collapse = ", "), "\n")
  cat("from  :", format(min(attr(x, "bin_start"))), "to",
      format(max(attr(x, "bin_start"))), "\n")
  invisible(x)
}

.plural <- function(n, word) {
  paste0(n, " ", word, if (n == 1L) "" else "s")
}

.windows <- function() {
  c("hour", "halfday", "day", "week", "month", "season", "year")
}

.day_level_stats <- function() {
  c("cold_day", "warm_day")
}

.resolve_column <- function(expr, data, envir) {
  name <- if (is.character(expr) && length(expr) == 1L) expr else deparse(expr)
  if (!name %in% names(data)) {
    evaluated <- tryCatch(eval(expr, envir), error = function(e) NULL)
    if (is.character(evaluated) && length(evaluated) == 1L && evaluated %in% names(data)) {
      name <- evaluated
    } else {
      stop("column `", name, "` is not in the data.", call. = FALSE)
    }
  }
  name
}

.check_stats <- function(stats, window) {
  known <- c("mean", "min", "max", .day_level_stats())
  bad <- setdiff(stats, known)
  if (length(bad)) {
    stop("unknown statistic: ", paste(bad, collapse = ", "),
         ". Available: ", paste(known, collapse = ", "), ".", call. = FALSE)
  }
  if (anyDuplicated(stats)) {
    stop("`stats` names a statistic twice: ",
         paste(unique(stats[duplicated(stats)]), collapse = ", "), ".", call. = FALSE)
  }
  if (window %in% c("hour", "halfday") && any(stats %in% .day_level_stats())) {
    stop("`", window, "` bins are shorter than a day, so ",
         paste(intersect(stats, .day_level_stats()), collapse = " and "),
         " is not defined there. Use a window of `day` or coarser.", call. = FALSE)
  }
  stats
}

.parse_year_start <- function(year_start) {
  if (!grepl("^[0-9]{2}-[0-9]{2}$", year_start)) {
    stop("`year_start` must look like \"MM-DD\", got \"", year_start, "\".", call. = FALSE)
  }
  parts <- as.integer(strsplit(year_start, "-", fixed = TRUE)[[1L]])
  if (parts[1L] < 1L || parts[1L] > 12L || parts[2L] < 1L || parts[2L] > 28L) {
    stop("`year_start` must be a month 01-12 and a day 01-28, got \"", year_start, "\".",
         call. = FALSE)
  }
  list(month = parts[1L], day = parts[2L])
}

.check_readings <- function(unit, when, reading, id_col, time_col, value_col) {
  missing <- c(id_col, time_col, value_col)[c(anyNA(unit), anyNA(when), anyNA(reading))]
  if (length(missing)) {
    stop("missing values in ", paste(sprintf("`%s`", missing), collapse = " and "),
         ". Fill or drop them before building a representation.", call. = FALSE)
  }
  key <- paste(unit, format(when, "%Y-%m-%dT%H:%M:%S"), sep = "\r")
  if (anyDuplicated(key)) {
    dup <- unique(key[duplicated(key)])
    stop(length(dup), " duplicated (unit, time) pair", if (length(dup) > 1L) "s" else "",
         ", first: ", sub("\r", " at ", dup[1L], fixed = TRUE), ".", call. = FALSE)
  }
  invisible(TRUE)
}

.check_grid <- function(count, units, bins, n_u) {
  empty <- which(count == 0L)
  if (!length(empty)) {
    return(invisible(TRUE))
  }
  u <- units[((empty[1L] - 1L) %% n_u) + 1L]
  b <- bins[((empty[1L] - 1L) %/% n_u) + 1L]
  stop(length(empty), " (unit, bin) cell", if (length(empty) > 1L) "s" else "",
       " hold no readings, first: unit ", u, " at ", format(b),
       ". Every unit must span every bin; gaps are not padded.", call. = FALSE)
}

.group_sum <- function(values, cell, n_cell) {
  s <- rowsum(values, cell, reorder = TRUE)
  out <- numeric(n_cell)
  out[sort(unique(cell))] <- as.vector(s)
  out
}

.group_edge <- function(values, cell, n_cell, upper) {
  o <- order(cell, values)
  g <- cell[o]
  keep <- !duplicated(g, fromLast = upper)
  out <- rep(NA_real_, n_cell)
  out[g[keep]] <- values[o][keep]
  out
}

.day_cells <- function(reading, unit, when, bin_start, units, bins, ys, tz) {
  day_start <- .bin_start(when, "day", ys, tz)
  n_u <- length(units)
  days <- sort(unique(day_start))
  dcell <- (match(day_start, days) - 1L) * n_u + match(unit, units)
  n_dcell <- n_u * length(days)

  count <- tabulate(dcell, nbins = n_dcell)
  present <- which(count > 0L)
  value <- .group_sum(reading, dcell, n_dcell)[present] / count[present]

  day_unit <- ((present - 1L) %% n_u) + 1L
  day_of <- ((present - 1L) %/% n_u) + 1L
  bin_of <- findInterval(as.numeric(days[day_of]), as.numeric(bins))
  list(value = value, cell = (bin_of - 1L) * n_u + day_unit)
}

.bin_start <- function(when, window, ys, tz) {
  if (window == "hour") {
    return(when)
  }
  if (window == "halfday") {
    day <- as.POSIXct(trunc(when, units = "days"), tz = tz)
    return(day + 43200 * (as.integer(format(when, "%H", tz = tz)) >= 12L))
  }
  if (window == "day") {
    return(as.POSIXct(trunc(when, units = "days"), tz = tz))
  }
  if (window == "week") {
    day <- as.Date(when, tz = tz)
    monday <- day - (as.integer(format(day, "%u")) - 1L)
    return(as.POSIXct(paste0(monday, " 00:00:00"), tz = tz))
  }
  if (window == "month") {
    return(as.POSIXct(paste0(format(when, "%Y-%m", tz = tz), "-01 00:00:00"), tz = tz))
  }
  step <- if (window == "season") 3L else 12L
  .anniversary(.offset_months(when, ys, tz) %/% step * step, ys, tz)
}

.offset_months <- function(when, ys, tz) {
  y <- as.integer(format(when, "%Y", tz = tz))
  m <- as.integer(format(when, "%m", tz = tz))
  d <- as.integer(format(when, "%d", tz = tz))
  y * 12L + (m - 1L) - (ys$month - 1L) - as.integer(d < ys$day)
}

.anniversary <- function(offset, ys, tz) {
  absolute <- offset + (ys$month - 1L)
  as.POSIXct(sprintf("%04d-%02d-%02d 00:00:00",
                     absolute %/% 12L, absolute %% 12L + 1L, ys$day),
             tz = tz)
}
