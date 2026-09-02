#!/usr/bin/env Rscript
# Regenerates spec/fixtures/. This is a deliberate act with its own commit: a digest that moves
# means the representation moved, and the question is which implementation is wrong.

# Run from the package root: Rscript spec/fixtures/make_fixtures.R
if (!file.exists("DESCRIPTION")) {
  stop("run this from the package root", call. = FALSE)
}
suppressMessages(devtools::load_all("."))
out_dir <- "spec/fixtures"

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

fine <- c("hour", "halfday")
rows <- list()
for (w in c("hour", "halfday", "day", "week", "month", "season", "year")) {
  available <- if (w %in% fine) c("mean", "min", "max") else
    c("mean", "min", "max", "cold_day", "warm_day")
  for (s in available) {
    x <- window_matrix(series, id, time, value, window = w, stats = s)
    rows[[length(rows) + 1L]] <- data.frame(
      window = w, stat = s, n_unit = dim(x)[1], n_bin = dim(x)[2],
      digest = .digest_array(x), stringsAsFactors = FALSE
    )
  }
  reported <- if (w %in% fine) NULL else c("cold_day", "mean", "warm_day")
  if (!is.null(reported)) {
    x <- window_matrix(series, id, time, value, window = w, stats = reported)
    rows[[length(rows) + 1L]] <- data.frame(
      window = w, stat = paste(reported, collapse = "+"), n_unit = dim(x)[1],
      n_bin = dim(x)[2], digest = .digest_array(x), stringsAsFactors = FALSE
    )
  }
}

write.csv(do.call(rbind, rows), file.path(out_dir, "digests.csv"),
          row.names = FALSE, quote = FALSE)
cat("wrote", length(rows), "digests\n")
