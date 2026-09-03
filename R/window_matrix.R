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
#'   rather than a fixed block of hours. Naming several windows returns one representation per
#'   window, a [timegrain_set()]. A function is called on the reading instants and must return
#'   the `POSIXct` start of each reading's bin, which is how a calendar the package does not
#'   carry, such as astronomical seasons, is binned.
#' @param stats Statistics to compute per bin, one channel each, in the order given. See Details.
#' @param year_start `"MM-DD"` boundary of the hydrological year, used by `"season"` and
#'   `"year"`. Defaults to `"09-01"`.
#' @param partial What to do with a bin the record does not cover for its whole calendar span,
#'   which is what a record beginning or ending away from a bin boundary produces. `"keep"`, the
#'   default, returns it alongside the full bins; `"drop"` removes it. See Partial bins.
#'
#' @details
#' Seven statistics are available, and the distinction between an extreme reading, an extreme day
#' and a typical day is deliberate rather than pedantic:
#'
#' \itemize{
#'   \item `mean`: arithmetic mean of the readings in the bin.
#'   \item `min`, `max`: coldest and warmest single reading in the bin.
#'   \item `cold_day`, `warm_day`: coldest and warmest day, each day first reduced to its own
#'     mean. Defined for `"day"` and coarser.
#'   \item `mean_daily_min`, `mean_daily_max`: the bin's average daily minimum and average daily
#'     maximum, each day first reduced to its own extreme. Defined for `"day"` and coarser.
#' }
#'
#' An extreme day is a state the unit was in; an extreme reading can be one hour; an average daily
#' extreme is the exposure a typical day of the bin brought. On alpine soil temperature the
#' day-level pair carries more predictive signal than the bin mean, and by more the coarser the
#' bin.
#'
#' Nothing is standardised here. Scaling belongs to the fold it is computed on, never to the
#' representation, because computing it over all units would leak held-out units into the input.
#'
#' @section Partial bins:
#' A bin is partial when the record does not cover its whole calendar span. Which bins those are
#' follows from where the record starts and stops against the calendar, not from the window alone:
#' three years of hourly readings from 1 September carry no partial month and no partial season on
#' a `"09-01"` boundary, but the same record carries a partial week at each end, because 1
#' September is a Wednesday. A record from an arbitrary deployment date carries one at each end of
#' almost every window.
#'
#' A bin is partial if its start precedes the first reading of the record, or if its calendar span
#' runs past the last reading plus the record's own sampling interval, taken as the smallest gap
#' between consecutive distinct reading instants. Only a bin at an end of the record can satisfy
#' either, because every unit is required to span every bin in between. The verdict is returned as
#' the `bin_partial` attribute whichever way `partial` is set, so a kept partial bin is labelled
#' rather than silent.
#'
#' Keeping partial bins is the default because dropping them discards the record's ends: on a
#' seasonal window that is up to three months of readings at each end. The cost of keeping them is
#' that such a bin's mean is taken over fewer readings and its extremes over fewer days, so
#' `cold_day` and `warm_day` there are drawn from a shorter draw and sit closer to the bin mean
#' than a full bin's would. `bin_n` gives the count the bin was actually reduced from.
#'
#' A caller-supplied binning declares its own bins, so the package cannot know where the last one
#' was meant to end and takes the record's end as its end. Such a final bin is never reported
#' partial; its leading bin is judged as any other.
#'
#' @return A numeric array of shape `[unit, bin, channel]`, with dimnames giving the sorted unit
#'   identifiers, the ISO-8601 start of each bin, and the statistic names. Attributes:
#'   \itemize{
#'     \item `window`: the window name.
#'     \item `stats`: the statistic names in channel order.
#'     \item `year_start`: the boundary used.
#'     \item `bin_start`, `bin_end`: the first and last reading instant assigned to each bin.
#'     \item `bin_n`: a `[unit, bin]` matrix of how many readings fell in each bin.
#'     \item `bin_partial`: a logical vector marking the bins the record does not cover for their
#'       whole calendar span.
#'   }
#'   Naming more than one window returns a [timegrain_set()] of those arrays.
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
#' ladder <- window_matrix(d, plot, t, temp, window = c("day", "week"))
#' names(ladder)
#'
#' @export
window_matrix <- function(data,
                          id,
                          time,
                          value,
                          window = "day",
                          stats = "mean",
                          year_start = "09-01",
                          partial = c("keep", "drop")) {
  id_col <- .resolve_column(substitute(id), data, parent.frame())
  time_col <- .resolve_column(substitute(time), data, parent.frame())
  value_col <- .resolve_column(substitute(value), data, parent.frame())

  partial <- match.arg(partial)
  window <- .check_window(window)
  if (length(window) > 1L) {
    out <- lapply(window, function(w) {
      window_matrix(data, id = id_col, time = time_col, value = value_col,
                    window = w, stats = stats, year_start = year_start, partial = partial)
    })
    return(timegrain_set(stats::setNames(out, window)))
  }

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

  bin_of <- match(unclass(bin_start), unclass(bins))
  cell <- (bin_of - 1L) * n_u + match(unit, units)
  count <- tabulate(cell, nbins = n_cell)
  .check_grid(count, units, bins, n_u)

  out <- array(NA_real_,
               dim = c(n_u, n_b, length(stats)),
               dimnames = list(units, format(bins, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"), stats))

  day <- if (any(stats %in% .day_level_stats())) {
    .day_level(reading, unit, when, units, bins, ys, tz, n_cell)
  } else {
    NULL
  }

  for (k in seq_along(stats)) {
    out[, , k] <- switch(
      stats[k],
      mean = matrix(.group_sum(reading, cell, n_cell) / count, nrow = n_u, ncol = n_b),
      min = matrix(.group_edge(reading, cell, n_cell, FALSE), nrow = n_u, ncol = n_b),
      max = matrix(.group_edge(reading, cell, n_cell, TRUE), nrow = n_u, ncol = n_b),
      cold_day = matrix(.group_edge(day$mean, day$cell, n_cell, FALSE), nrow = n_u, ncol = n_b),
      warm_day = matrix(.group_edge(day$mean, day$cell, n_cell, TRUE), nrow = n_u, ncol = n_b),
      mean_daily_min = matrix(.group_sum(day$min, day$cell, n_cell) / day$n_day,
                              nrow = n_u, ncol = n_b),
      mean_daily_max = matrix(.group_sum(day$max, day$cell, n_cell) / day$n_day,
                              nrow = n_u, ncol = n_b)
    )
  }

  attr(out, "window") <- if (is.function(window)) "custom" else window
  attr(out, "stats") <- stats
  attr(out, "year_start") <- year_start
  attr(out, "bin_start") <- bins
  attr(out, "bin_end") <- .POSIXct(
    .group_edge(as.numeric(when), bin_of, n_b, TRUE), tz = tz)
  attr(out, "bin_n") <- matrix(count, nrow = n_u, ncol = n_b, dimnames = dimnames(out)[1:2])
  attr(out, "bin_partial") <- .bin_partial(when, bins, window, ys, tz)
  class(out) <- c("timegrain_matrix", class(out))
  if (partial == "drop") .drop_partial(out) else out
}

# Keeping or dropping a partial bin is the caller's choice, so the array is built over every bin
# the calendar produced and the unwanted ones are removed afterwards, which keeps one binning path
# rather than one per setting.
.drop_partial <- function(x) {
  keep <- which(!attr(x, "bin_partial"))
  if (!length(keep)) {
    stop("dropping the partial bins leaves no bin: the record covers no whole ",
         attr(x, "window"), ". Use `partial = \"keep\"` or a finer window.", call. = FALSE)
  }
  if (length(keep) == dim(x)[2L]) {
    return(x)
  }
  out <- x[, keep, , drop = FALSE]
  dimnames(out) <- list(dimnames(x)[[1L]], dimnames(x)[[2L]][keep], dimnames(x)[[3L]])
  for (a in c("window", "stats", "year_start")) {
    attr(out, a) <- attr(x, a)
  }
  attr(out, "bin_start") <- attr(x, "bin_start")[keep]
  attr(out, "bin_end") <- attr(x, "bin_end")[keep]
  attr(out, "bin_n") <- attr(x, "bin_n")[, keep, drop = FALSE]
  attr(out, "bin_partial") <- attr(x, "bin_partial")[keep]
  class(out) <- c("timegrain_matrix", "array")
  out
}

#' @export
print.timegrain_matrix <- function(x, ...) {
  d <- dim(x)
  cat("<timegrain matrix>", .plural(d[1L], "unit"), "x", .plural(d[2L], "bin"),
      "x", .plural(d[3L], "channel"), "\n")
  cat("window:", attr(x, "window"), "  stats:", paste(attr(x, "stats"), collapse = ", "), "\n")
  span <- attr(x, "bin_start")
  if (!all(is.na(span))) {
    cat("from  :", format(min(span)), "to", format(max(span)), "\n")
  }
  invisible(x)
}

.plural <- function(n, word) {
  paste0(n, " ", word, if (n == 1L) "" else "s")
}

.windows <- function() {
  c("hour", "halfday", "day", "week", "month", "season", "year")
}

.day_level_stats <- function() {
  c("cold_day", "warm_day", "mean_daily_min", "mean_daily_max")
}

.known_stats <- function() {
  c("mean", "min", "max", .day_level_stats())
}

.check_window <- function(window) {
  if (is.function(window)) {
    return(window)
  }
  if (!is.character(window) || !length(window)) {
    stop("`window` must be a window name, a vector of them, or a function.", call. = FALSE)
  }
  bad <- setdiff(window, .windows())
  if (length(bad)) {
    stop("unknown window: ", paste(bad, collapse = ", "),
         ". Available: ", paste(.windows(), collapse = ", "), ".", call. = FALSE)
  }
  if (anyDuplicated(window)) {
    stop("`window` names a window twice: ",
         paste(unique(window[duplicated(window)]), collapse = ", "), ".", call. = FALSE)
  }
  window
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
  known <- .known_stats()
  bad <- setdiff(stats, known)
  if (length(bad)) {
    stop("unknown statistic: ", paste(bad, collapse = ", "),
         ". Available: ", paste(known, collapse = ", "), ".", call. = FALSE)
  }
  if (anyDuplicated(stats)) {
    stop("`stats` names a statistic twice: ",
         paste(unique(stats[duplicated(stats)]), collapse = ", "), ".", call. = FALSE)
  }
  if (is.character(window) && window %in% c("hour", "halfday") &&
        any(stats %in% .day_level_stats())) {
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
  # Sort by (unit, time) and look at neighbours. Pasting the two into a key would be the obvious
  # way and builds one string per reading, which on a record of tens of millions of readings costs
  # more memory than the readings themselves.
  n <- length(unit)
  if (n < 2L) {
    return(invisible(TRUE))
  }
  code <- match(unit, sort(unique(unit)))
  o <- order(code, when, method = "radix")
  same <- code[o][-1L] == code[o][-n] & unclass(when)[o][-1L] == unclass(when)[o][-n]
  if (any(same)) {
    first <- o[which(same)[1L] + 1L]
    stop(sum(same), " duplicated (unit, time) pair", if (sum(same) > 1L) "s" else "",
         ", first: ", unit[first], " at ", format(when[first]), ".", call. = FALSE)
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
  o <- order(cell, values, method = "radix")
  g <- cell[o]
  keep <- !duplicated(g, fromLast = upper)
  out <- rep(NA_real_, n_cell)
  out[g[keep]] <- values[o][keep]
  out
}

# The day-level stage: reduce every (unit, calendar day) to its own mean, minimum and maximum, and
# say which bin cell each of those days belongs to. The four day-level statistics are then a second
# reduction over the days of a bin, which is what keeps an extreme day distinct from an extreme
# reading.
.day_level <- function(reading, unit, when, units, bins, ys, tz, n_cell) {
  day_start <- .bin_start(when, "day", ys, tz)
  n_u <- length(units)
  days <- sort(unique(day_start))
  dcell <- (match(unclass(day_start), unclass(days)) - 1L) * n_u + match(unit, units)
  n_dcell <- n_u * length(days)

  count <- tabulate(dcell, nbins = n_dcell)
  present <- which(count > 0L)

  day_unit <- ((present - 1L) %% n_u) + 1L
  day_of <- ((present - 1L) %/% n_u) + 1L
  bin_of <- findInterval(as.numeric(days[day_of]), as.numeric(bins))
  cell <- (bin_of - 1L) * n_u + day_unit

  list(cell = cell,
       mean = .group_sum(reading, dcell, n_dcell)[present] / count[present],
       min = .group_edge(reading, dcell, n_dcell, FALSE)[present],
       max = .group_edge(reading, dcell, n_dcell, TRUE)[present],
       n_day = tabulate(cell, nbins = n_cell))
}

# A record of many units shares its reading instants across them, and binning is a function of the
# instant alone, so the calendar is read once per distinct instant rather than once per reading.
# On three years of hourly readings from 894 units that is 26,304 calendar lookups instead of
# 23,515,776, and the difference is minutes.
.bin_start <- function(when, window, ys, tz) {
  u <- unique(when)
  if (length(u) == length(when)) {
    return(.bin_of(when, window, ys, tz))
  }
  .bin_of(u, window, ys, tz)[match(unclass(when), unclass(u))]
}

.bin_of <- function(when, window, ys, tz) {
  if (is.function(window)) {
    out <- window(when)
    if (!inherits(out, "POSIXct") || length(out) != length(when)) {
      stop("a `window` function must return one POSIXct bin start per reading.", call. = FALSE)
    }
    return(out)
  }
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

# Which bins the record does not cover for their whole calendar span. The record covers from its
# first reading to its last plus one sampling interval, and a bin is partial when its own span
# reaches outside that. Only a bin at an end of the record can, because .check_grid() has already
# required every unit to hold readings in every bin between them.
.bin_partial <- function(when, bins, window, ys, tz) {
  covered <- range(as.numeric(when))
  covered[2L] <- covered[2L] + .sampling_step(when)
  as.numeric(bins) < covered[1L] |
    as.numeric(.bin_next(bins, window, ys, tz, covered[2L])) > covered[2L]
}

.sampling_step <- function(when) {
  u <- sort(unique(as.numeric(when)))
  if (length(u) < 2L) 0 else min(diff(u))
}

# Where each bin ends, which is where the next one on the same calendar starts. The four coarse
# windows step by the calendar rather than by a count of seconds, so the successor is taken by
# landing well inside the following bin and flooring that, which is exact whatever the month length
# or the daylight-saving offset. A caller-supplied binning declares its own bins, so its successors
# are read off the bins themselves and its last bin is taken to end with the record.
.bin_next <- function(bins, window, ys, tz, covered_end) {
  if (is.function(window)) {
    return(c(bins[-1L], .POSIXct(covered_end, tz = tz)))
  }
  switch(window,
         hour = bins + 3600,
         halfday = bins + 43200,
         day = .bin_of(bins + 36 * 3600, "day", ys, tz),
         week = .bin_of(bins + 180 * 3600, "week", ys, tz),
         month = .bin_of(bins + 40 * 86400, "month", ys, tz),
         season = .anniversary(.offset_months(bins, ys, tz) + 3L, ys, tz),
         year = .anniversary(.offset_months(bins, ys, tz) + 12L, ys, tz))
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
