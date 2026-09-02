#!/usr/bin/env Rscript
# Regenerates spec/fixtures/. This is a deliberate act with its own commit: a digest that moves
# means the representation moved, and the question is which implementation is wrong.

# Run from the package root: Rscript inst/spec/make_fixtures.R
if (!file.exists("DESCRIPTION")) {
  stop("run this from the package root", call. = FALSE)
}
suppressMessages(pkgload::load_all(".", quiet = TRUE))
out_dir <- "inst/spec/fixtures"

make_series <- function() {
  t <- seq(as.POSIXct("2021-09-01 00:00:00", tz = "UTC"), by = "hour", length.out = 24 * 400)
  units <- c("p01", "p02", "p03")
  set.seed(20260902L)
  value <- unlist(lapply(seq_along(units), function(k) {
    season <- 8 * sin(2 * pi * (seq_along(t) / (24 * 365.25)) - pi / 2)
    diurnal <- 3 * sin(2 * pi * seq_along(t) / 24)
    round(season + diurnal + k + rnorm(length(t), sd = 0.5), 6)
  }))
  data.frame(id = rep(units, each = length(t)), time = rep(t, length(units)),
             value = value, stringsAsFactors = FALSE)
}

series <- make_series()
write.csv(
  data.frame(id = series$id,
             time = format(series$time, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
             value = sprintf("%.6f", series$value)),
  file.path(out_dir, "series.csv"), row.names = FALSE, quote = FALSE
)

# The three-channel schemes a caller asks for by name in the literature this package serves: the
# window's own extremes, its typical day, and its coldest and warmest day.
schemes <- list(
  c("min", "mean", "max"),
  c("mean_daily_min", "mean", "mean_daily_max"),
  c("cold_day", "mean", "warm_day")
)

fine <- c("hour", "halfday")
rows <- list()
digest_row <- function(w, stats) {
  x <- window_matrix(series, id, time, value, window = w, stats = stats)
  data.frame(window = w, stat = paste(stats, collapse = "+"), n_unit = dim(x)[1],
             n_bin = dim(x)[2], digest = .digest_array(x), stringsAsFactors = FALSE)
}

for (w in c("hour", "halfday", "day", "week", "month", "season", "year")) {
  available <- if (w %in% fine) c("mean", "min", "max") else
    c("mean", "min", "max", "cold_day", "warm_day", "mean_daily_min", "mean_daily_max")
  for (s in available) {
    rows[[length(rows) + 1L]] <- digest_row(w, s)
  }
  for (scheme in schemes) {
    if (w %in% fine && any(scheme %in% c("cold_day", "warm_day",
                                         "mean_daily_min", "mean_daily_max"))) {
      next
    }
    rows[[length(rows) + 1L]] <- digest_row(w, scheme)
  }
}

write.csv(do.call(rbind, rows), file.path(out_dir, "digests.csv"),
          row.names = FALSE, quote = FALSE)
cat("wrote", length(rows), "digests\n")
