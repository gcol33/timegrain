#!/usr/bin/env Rscript
# Regenerates spec/fixtures/. This is a deliberate act with its own commit: a digest that moves
# means the representation moved, and the question is which implementation is wrong.

# Run from the package root: Rscript inst/spec/make_fixtures.R
if (!file.exists("DESCRIPTION")) {
  stop("run this from the package root", call. = FALSE)
}
suppressMessages(pkgload::load_all(".", quiet = TRUE))
out_dir <- "inst/spec/fixtures"

# Two series, because a record that starts on a bin boundary cannot tell two binning rules apart.
# The first begins at midnight on the default year_start, so every coarse window is in phase with
# it from the first reading. The second begins at an arbitrary hour of an arbitrary day, which is
# what a logger deployed when someone could walk to it gives, and puts every window out of phase.
make_series <- function(from, units, days, seed) {
  t <- seq(as.POSIXct(from, tz = "UTC"), by = "hour", length.out = 24 * days)
  set.seed(seed)
  value <- unlist(lapply(seq_along(units), function(k) {
    season <- 8 * sin(2 * pi * (seq_along(t) / (24 * 365.25)) - pi / 2)
    diurnal <- 3 * sin(2 * pi * seq_along(t) / 24)
    round(season + diurnal + k + rnorm(length(t), sd = 0.5), 6)
  }))
  data.frame(id = rep(units, each = length(t)), time = rep(t, length(units)),
             value = value, stringsAsFactors = FALSE)
}

write_series <- function(series, file) {
  write.csv(
    data.frame(id = series$id,
               time = format(series$time, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
               value = sprintf("%.6f", series$value)),
    file.path(out_dir, file), row.names = FALSE, quote = FALSE
  )
}

# The third is short and sits across 4 November 2018, the night America/Sao_Paulo moved its clock
# at midnight and that local day began at 01:00. It is the record that tells a calendar read by
# arithmetic apart from one read by writing a local midnight and parsing it back.
SERIES <- list(
  aligned = make_series("2021-09-01 00:00:00", c("p01", "p02", "p03"), 400, 20260902L),
  offset = make_series("2021-10-17 05:00:00", c("p01", "p02"), 200, 20260903L),
  zoned = make_series("2018-11-01 00:00:00", c("p01", "p02"), 10, 20260904L)
)
write_series(SERIES$aligned, "series.csv")
write_series(SERIES$offset, "series_offset.csv")
write_series(SERIES$zoned, "series_zoned.csv")

# A calendar the package does not carry, cut where the deposit cuts its seasons: at the equinoxes
# and the solstices rather than on the first of a month. The first edge is the series' own first
# reading, so every reading falls at or after an edge and the two languages' interval lookups agree
# on every one of them.
EDGES <- list(
  aligned = c("2021-09-01", "2021-09-22", "2021-12-21", "2022-03-20", "2022-06-21", "2022-09-23"),
  offset = c("2021-10-17", "2021-12-21", "2022-03-20")
)
write.csv(
  data.frame(series = rep(names(EDGES), lengths(EDGES)),
             edge = paste0(unlist(EDGES, use.names = FALSE), "T00:00:00Z")),
  file.path(out_dir, "seasons.csv"), row.names = FALSE, quote = FALSE
)

astronomical <- function(name) {
  edges <- as.POSIXct(EDGES[[name]], tz = "UTC")
  function(when) edges[findInterval(as.numeric(when), as.numeric(edges))]
}

# The three-channel schemes a caller asks for by name in the literature this package serves: the
# window's own extremes, its typical day, and its coldest and warmest day.
schemes <- list(
  c("min", "mean", "max"),
  c("mean_daily_min", "mean", "mean_daily_max"),
  c("cold_day", "mean", "warm_day")
)

fine <- c("hour", "halfday")
coarse <- c("month", "season", "year")
windows <- c("hour", "halfday", "day", "week", "month", "season", "year")

rows <- list()
digest_row <- function(name, w, stats, year_start = "09-01", partial = "keep", tz = "UTC") {
  series <- SERIES[[name]]
  attr(series$time, "tzone") <- tz
  binning <- if (w == "astronomical") astronomical(name) else w
  x <- window_matrix(series, id, time, value, window = binning, stats = stats,
                     year_start = year_start, partial = partial)
  start <- attr(x, "bin_start")
  data.frame(series = name, window = w, tz = tz, year_start = year_start, partial = partial,
             stat = paste(stats, collapse = "+"), n_unit = dim(x)[1], n_bin = dim(x)[2],
             first_bin = format(start[1], "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
             last_bin = format(start[length(start)], "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
             n_partial = sum(attr(x, "bin_partial")), digest = .digest_array(x),
             stringsAsFactors = FALSE)
}
add <- function(...) rows[[length(rows) + 1L]] <<- digest_row(...)

for (name in c("aligned", "offset")) {
  for (w in windows) {
    available <- if (w %in% fine) c("mean", "min", "max") else
      c("mean", "min", "max", "cold_day", "warm_day", "mean_daily_min", "mean_daily_max")
    for (s in available) {
      add(name, w, s)
    }
    for (scheme in schemes) {
      if (w %in% fine && any(scheme %in% .day_level_stats())) {
        next
      }
      add(name, w, scheme)
    }
  }
  # The anniversary sets the phase of the two windows that count from it, so a contract checked at
  # the default alone pins only the phase the fixtures happen to start on.
  for (w in coarse) {
    for (ys in c("01-01", "03-01", "07-15")) {
      add(name, w, "mean", year_start = ys)
    }
  }
  # The bin the record does not fill is a choice, so both settings are pinned rather than the one
  # that happens to be the default. A window the record holds no whole one of has nothing to pin:
  # it errors, and the test suites assert that separately.
  for (w in setdiff(windows, "hour")) {
    whole <- !attr(window_matrix(SERIES[[name]], id, time, value, window = w), "bin_partial")
    if (any(whole)) {
      add(name, w, "mean", partial = "drop")
    }
  }
  for (stats in list("mean", c("cold_day", "mean", "warm_day"))) {
    add(name, "astronomical", stats)
  }
}

# The zone. The instants are the same bytes on disk whichever calendar reads them, so a zone row
# is the same series with a different clock over it, and the digest is what says the two languages
# read that clock the same way. Europe/Vienna moves its clock twice inside the aligned record;
# America/Sao_Paulo moves it at midnight inside the short one, which is the case that has no local
# midnight to parse.
for (w in windows) {
  add("aligned", w, "mean", tz = "Europe/Vienna")
}
add("aligned", "week", c("cold_day", "mean", "warm_day"), tz = "Europe/Vienna")
add("aligned", "day", c("min", "mean", "max"), tz = "Europe/Vienna")
add("zoned", "day", "mean")
for (w in c("hour", "halfday", "day", "week")) {
  add("zoned", w, "mean", tz = "America/Sao_Paulo")
}
add("zoned", "day", c("min", "mean", "max"), tz = "America/Sao_Paulo")
add("zoned", "day", c("cold_day", "mean", "warm_day"), tz = "America/Sao_Paulo")
add("zoned", "year", "mean", year_start = "11-04", tz = "America/Sao_Paulo")

write.csv(do.call(rbind, rows), file.path(out_dir, "digests.csv"),
          row.names = FALSE, quote = FALSE)
cat("wrote", length(rows), "digests\n")
