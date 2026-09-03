hourly_series <- function(units = c("a", "b"), from = "2021-09-01", hours = 24 * 400) {
  t <- seq(as.POSIXct(from, tz = "UTC"), by = "hour", length.out = hours)
  set.seed(1L)
  data.frame(
    plot = rep(units, each = length(t)),
    t = rep(t, length(units)),
    temp = as.numeric(replicate(length(units), rnorm(length(t)))),
    stringsAsFactors = FALSE
  )
}

# An independent reduction, written the slow obvious way, to check the fast one against.
brute <- function(d, key, fun) {
  out <- tapply(d$temp, list(d$plot, key), fun)
  out[order(rownames(out)), order(colnames(out)), drop = FALSE]
}

test_that("bins tile the record with no gap and no overlap", {
  d <- hourly_series()
  for (w in c("hour", "halfday", "day", "week", "month", "season", "year")) {
    x <- window_matrix(d, plot, t, temp, window = w)
    n <- attr(x, "bin_n")
    expect_equal(unname(rowSums(n)), c(24 * 400, 24 * 400),
                 info = paste("window", w))
    expect_true(all(n > 0L), info = paste("window", w))
  }
})

test_that("the mean matches an independent reduction", {
  d <- hourly_series()
  x <- window_matrix(d, plot, t, temp, window = "day", stats = "mean")
  ref <- brute(d, as.Date(d$t, tz = "UTC"), mean)
  expect_equal(as.numeric(x[, , "mean"]), as.numeric(ref))
})

test_that("min and max match an independent reduction", {
  d <- hourly_series()
  key <- format(d$t, "%Y-%m", tz = "UTC")
  x <- window_matrix(d, plot, t, temp, window = "month", stats = c("min", "max"))
  expect_equal(as.numeric(x[, , "min"]), as.numeric(brute(d, key, min)))
  expect_equal(as.numeric(x[, , "max"]), as.numeric(brute(d, key, max)))
})

test_that("an extreme day is not an extreme reading", {
  # One hour of day 2 is far colder than anything else, but day 3 is the coldest day on average.
  t <- seq(as.POSIXct("2021-09-06", tz = "UTC"), by = "hour", length.out = 24 * 7)
  temp <- rep(c(10, 5, 0, 5, 10, 10, 10), each = 24)
  temp[24 + 5] <- -50
  d <- data.frame(plot = "a", t = t, temp = temp)
  x <- window_matrix(d, plot, t, temp, window = "week",
                     stats = c("min", "cold_day", "mean", "warm_day", "max"))
  expect_equal(as.numeric(x[1, 1, "min"]), -50)
  expect_equal(as.numeric(x[1, 1, "cold_day"]), 0)
  expect_equal(as.numeric(x[1, 1, "warm_day"]), 10)
  expect_equal(as.numeric(x[1, 1, "max"]), 10)
})

test_that("cold_day, warm_day and mean coincide at the daily window", {
  d <- hourly_series(units = "a", hours = 24 * 30)
  x <- window_matrix(d, plot, t, temp, window = "day",
                     stats = c("cold_day", "mean", "warm_day"))
  expect_equal(as.numeric(x[, , "cold_day"]), as.numeric(x[, , "mean"]))
  expect_equal(as.numeric(x[, , "warm_day"]), as.numeric(x[, , "mean"]))
})

test_that("coarse bins follow the calendar rather than a fixed hour count", {
  d <- hourly_series(units = "a", hours = 24 * 400)
  x <- window_matrix(d, plot, t, temp, window = "month")
  n <- as.integer(attr(x, "bin_n")[1, ])
  # September has 30 days, October 31, February 28. A drifting 730-hour block would give 730.
  expect_equal(n[1], 30L * 24L)
  expect_equal(n[2], 31L * 24L)
  expect_true(any(n == 28L * 24L))
})

test_that("the hydrological year boundary moves with year_start", {
  t <- seq(as.POSIXct("2021-08-25", tz = "UTC"), by = "hour", length.out = 24 * 20)
  d <- data.frame(plot = "a", t = t, temp = 1)
  sep <- window_matrix(d, plot, t, temp, window = "year", year_start = "09-01")
  jan <- window_matrix(d, plot, t, temp, window = "year", year_start = "01-01")
  expect_equal(dim(sep)[2], 2L)
  expect_equal(dim(jan)[2], 1L)
  expect_equal(dimnames(sep)[[2]], c("2020-09-01T00:00:00Z", "2021-09-01T00:00:00Z"))
  expect_equal(dimnames(jan)[[2]], "2021-01-01T00:00:00Z")
})

test_that("seasons are three calendar months counted from year_start", {
  d <- hourly_series(units = "a", hours = 24 * 400)
  x <- window_matrix(d, plot, t, temp, window = "season", year_start = "09-01")
  starts <- format(attr(x, "bin_start"), "%Y-%m-%d", tz = "UTC")
  expect_equal(starts[1:3], c("2021-09-01", "2021-12-01", "2022-03-01"))
})

test_that("a bin the record does not fill is reported and can be dropped", {
  # 1 September 2021 is a Wednesday, so three hydrological years from it fill every month, season
  # and year of the calendar and neither the first nor the last week of it.
  aligned <- hourly_series(units = "a", from = "2021-09-01 00:00:00", hours = 26304)
  for (w in c("hour", "halfday", "day", "month", "season", "year")) {
    x <- window_matrix(aligned, plot, t, temp, window = w)
    expect_false(any(attr(x, "bin_partial")), info = w)
  }
  week <- window_matrix(aligned, plot, t, temp, window = "week")
  expect_equal(which(attr(week, "bin_partial")), c(1L, 157L))
  expect_equal(dim(window_matrix(aligned, plot, t, temp, window = "week",
                                 partial = "drop"))[2], 155L)

  # A logger deployed on no boundary at all carries one at the start of every window that
  # aggregates, and the bin it starts is the one holding fewer readings than its neighbours.
  offset <- hourly_series(units = "a", from = "2021-10-17 05:00:00", hours = 24 * 300)
  for (w in c("halfday", "day", "week", "month", "season")) {
    p <- attr(window_matrix(offset, plot, t, temp, window = w), "bin_partial")
    expect_true(p[1L], info = w)
    expect_false(any(p[-c(1L, length(p))]), info = w)
  }
  m <- window_matrix(offset, plot, t, temp, window = "month")
  n <- attr(m, "bin_n")[1, ]
  expect_lt(n[1], n[2])
  dropped <- window_matrix(offset, plot, t, temp, window = "month", partial = "drop")
  expect_equal(dim(dropped)[2], dim(m)[2] - sum(attr(m, "bin_partial")))
  expect_false(any(attr(dropped, "bin_partial")))
  expect_equal(as.numeric(dropped), as.numeric(m[, !attr(m, "bin_partial"), , drop = FALSE]))
})

test_that("a caller-supplied calendar owns its own bin lengths", {
  d <- hourly_series(units = "a", from = "2021-09-01 00:00:00", hours = 24 * 200)
  # Cut at the equinox rather than on the first of a month, with the first edge at the record's
  # own start: the leading bin is three weeks against a season's three months, and that is the
  # calendar the caller asked for rather than a bin the record failed to fill.
  edges <- as.POSIXct(c("2021-09-01", "2021-09-22", "2021-12-21", "2022-03-20"), tz = "UTC")
  astronomical <- function(when) edges[findInterval(as.numeric(when), as.numeric(edges))]
  x <- window_matrix(d, plot, t, temp, window = astronomical)
  expect_equal(dim(x)[2], 3L)
  expect_false(any(attr(x, "bin_partial")))
  expect_lt(attr(x, "bin_n")[1, 1], attr(x, "bin_n")[1, 2])

  # The same record on the named window counts three calendar months from the anniversary, so it
  # is a different rule and a different number of bins, not a different implementation of one.
  expect_equal(dim(window_matrix(d, plot, t, temp, window = "season"))[2], 3L)
  expect_equal(format(attr(window_matrix(d, plot, t, temp, window = "season"), "bin_start"),
                      "%Y-%m-%d", tz = "UTC"),
               c("2021-09-01", "2021-12-01", "2022-03-01"))
})

test_that("a column can be named bare or as a string", {
  d <- hourly_series(units = "a", hours = 48)
  bare <- window_matrix(d, plot, t, temp, window = "day")
  quoted <- window_matrix(d, "plot", "t", "temp", window = "day")
  expect_equal(as.numeric(bare), as.numeric(quoted))
})

test_that("the representation refuses input it cannot reduce honestly", {
  d <- hourly_series(units = "a", hours = 48)

  gap <- d[-c(1:24), ]
  gap <- rbind(gap, transform(d[1:24, ], plot = "b"))
  expect_error(window_matrix(gap, plot, t, temp, window = "day"), "no readings")

  dup <- rbind(d, d[1, ])
  expect_error(window_matrix(dup, plot, t, temp, window = "day"), "duplicated")

  na <- d
  na$temp[3] <- NA
  expect_error(window_matrix(na, plot, t, temp, window = "day"), "missing values")

  expect_error(window_matrix(d, plot, t, temp, window = "hour", stats = "cold_day"),
               "not defined")
  expect_error(window_matrix(d, plot, t, temp, window = "day", stats = c("mean", "mean")),
               "twice")
  expect_error(window_matrix(d, plot, t, temp, window = "day", stats = "median"),
               "unknown statistic")
  expect_error(window_matrix(d, plot, t, temp, window = "day", year_start = "9-1"),
               "MM-DD")
  expect_error(window_matrix(d, plot, nope, temp, window = "day"), "not in the data")
  expect_error(window_matrix(transform(d, t = as.character(t)), plot, t, temp),
               "must be POSIXct")
})

test_that("channel order follows the order asked for", {
  d <- hourly_series(units = "a", hours = 24 * 14)
  x <- window_matrix(d, plot, t, temp, window = "week",
                     stats = c("warm_day", "mean", "cold_day"))
  expect_equal(dimnames(x)[[3]], c("warm_day", "mean", "cold_day"))
  expect_true(all(x[, , "warm_day"] >= x[, , "cold_day"]))
})

test_that("units and bins come back sorted, whatever order they arrived in", {
  d <- hourly_series(units = c("b", "a"), hours = 24 * 5)
  x <- window_matrix(d[sample(nrow(d)), ], plot, t, temp, window = "day")
  expect_equal(dimnames(x)[[1]], c("a", "b"))
  expect_false(is.unsorted(attr(x, "bin_start")))
})

test_that("the average daily extremes are an average over days, not over readings", {
  # Day 1 swings between -10 and +10, day 2 sits at 0. The week's coldest reading is -10; its
  # average daily minimum is the mean of -10 and 0.
  t <- seq(as.POSIXct("2021-09-06", tz = "UTC"), by = "hour", length.out = 48)
  temp <- c(rep(c(-10, 10), each = 12), rep(0, 24))
  d <- data.frame(plot = "a", t = t, temp = temp)
  x <- window_matrix(d, plot, t, temp, window = "week",
                     stats = c("min", "mean_daily_min", "mean", "mean_daily_max", "max"))
  expect_equal(as.numeric(x[1, 1, "min"]), -10)
  expect_equal(as.numeric(x[1, 1, "mean_daily_min"]), -5)
  expect_equal(as.numeric(x[1, 1, "mean"]), 0)
  expect_equal(as.numeric(x[1, 1, "mean_daily_max"]), 5)
  expect_equal(as.numeric(x[1, 1, "max"]), 10)
})

test_that("the average daily extremes match an independent reduction", {
  d <- hourly_series()
  day <- format(d$t, "%Y-%m-%d", tz = "UTC")
  month <- format(d$t, "%Y-%m", tz = "UTC")
  daily_min <- tapply(d$temp, list(d$plot, day), min)
  key <- substr(colnames(daily_min), 1L, 7L)
  ref <- t(apply(daily_min, 1L, function(v) tapply(v, key, mean)))
  x <- window_matrix(d, plot, t, temp, window = "month", stats = "mean_daily_min")
  expect_equal(as.numeric(x[, , "mean_daily_min"]), as.numeric(ref[order(rownames(ref)), ]))
})

test_that("at the daily window an average daily extreme is that day's extreme", {
  d <- hourly_series(units = "a", hours = 24 * 30)
  x <- window_matrix(d, plot, t, temp,
                     window = "day", stats = c("min", "mean_daily_min", "mean_daily_max", "max"))
  expect_equal(as.numeric(x[, , "mean_daily_min"]), as.numeric(x[, , "min"]))
  expect_equal(as.numeric(x[, , "mean_daily_max"]), as.numeric(x[, , "max"]))
})

test_that("the three-channel schemes come back ordered", {
  d <- hourly_series(units = c("a", "b"), hours = 24 * 60)
  for (scheme in list(c("min", "mean", "max"),
                      c("mean_daily_min", "mean", "mean_daily_max"),
                      c("cold_day", "mean", "warm_day"))) {
    x <- window_matrix(d, plot, t, temp, window = "week", stats = scheme)
    expect_true(all(x[, , 1] <= x[, , 2]), info = scheme[1])
    expect_true(all(x[, , 2] <= x[, , 3]), info = scheme[3])
  }
})

test_that("the window's own extremes bound the day-level ones", {
  d <- hourly_series(units = "a", hours = 24 * 90)
  x <- window_matrix(d, plot, t, temp, window = "month",
                     stats = c("min", "mean_daily_min", "cold_day",
                               "warm_day", "mean_daily_max", "max"))
  expect_true(all(x[, , "min"] <= x[, , "mean_daily_min"]))
  expect_true(all(x[, , "min"] <= x[, , "cold_day"]))
  expect_true(all(x[, , "warm_day"] <= x[, , "max"]))
  expect_true(all(x[, , "mean_daily_max"] <= x[, , "max"]))
})

test_that("the mean of the daily minima is not the coldest day", {
  # A bin of one day at 0 and one at 10 has a coldest day of 0 and an average daily minimum of 5,
  # so the two day-level pairs are not ordered against each other.
  t <- seq(as.POSIXct("2021-09-06", tz = "UTC"), by = "hour", length.out = 48)
  d <- data.frame(plot = "a", t = t, temp = rep(c(0, 10), each = 24))
  x <- window_matrix(d, plot, t, temp, window = "week",
                     stats = c("cold_day", "mean_daily_min", "mean_daily_max", "warm_day"))
  expect_equal(as.numeric(x[1, 1, "cold_day"]), 0)
  expect_equal(as.numeric(x[1, 1, "mean_daily_min"]), 5)
  expect_equal(as.numeric(x[1, 1, "mean_daily_max"]), 5)
  expect_equal(as.numeric(x[1, 1, "warm_day"]), 10)
})

test_that("naming several windows returns one representation per window", {
  d <- hourly_series(units = c("a", "b"), hours = 24 * 60)
  s <- window_matrix(d, plot, t, temp, window = c("day", "week", "month"))
  expect_s3_class(s, "timegrain_set")
  expect_named(s, c("day", "week", "month"))
  expect_equal(as.numeric(s$week),
               as.numeric(window_matrix(d, plot, t, temp, window = "week")))
  expect_s3_class(s["week"], "timegrain_set")
  expect_error(window_matrix(d, plot, t, temp, window = c("day", "day")), "twice")
  expect_error(window_matrix(d, plot, t, temp, window = c("day", "fortnight")), "unknown window")
})

test_that("a calendar the package does not carry can be passed as a function", {
  d <- hourly_series(units = "a", hours = 24 * 120)
  # Astronomical seasons: the boundaries fall on the equinoxes and solstices, not on the first of
  # a month, so they are not any three calendar months.
  astronomical <- function(when) {
    edges <- as.POSIXct(c("2021-06-23", "2021-09-23", "2021-12-21", "2022-03-20", "2022-06-23"),
                        tz = "UTC")
    edges[findInterval(as.numeric(when), as.numeric(edges))]
  }
  x <- window_matrix(d, plot, t, temp, window = astronomical)
  expect_equal(attr(x, "window"), "custom")
  expect_equal(format(attr(x, "bin_start"), "%Y-%m-%d", tz = "UTC"),
               c("2021-06-23", "2021-09-23", "2021-12-21"))
  expect_equal(sum(attr(x, "bin_n")), 24 * 120)
  expect_error(window_matrix(d, plot, t, temp, window = function(when) rep(1, length(when))),
               "POSIXct bin start")
})

test_that("the bin end is the last reading the bin holds", {
  d <- hourly_series(units = "a", hours = 24 * 40)
  x <- window_matrix(d, plot, t, temp, window = "week")
  s <- attr(x, "bin_start")
  e <- attr(x, "bin_end")
  expect_true(all(e >= s))
  expect_equal(max(e), max(d$t))
  expect_equal(as.numeric(difftime(e[2], s[2], units = "hours")), 24 * 7 - 1)
})

test_that("the calendar channels are the position of a bin in the year", {
  d <- hourly_series(units = c("a", "b"), hours = 24 * 400)
  x <- window_matrix(d, plot, t, temp, window = "month")
  cc <- calendar_channels(x)
  expect_equal(dimnames(cc)[[3]], c("year_sin", "year_cos"))
  expect_equal(cc[1, , ], cc[2, , ])                       # the calendar is not a unit's property
  expect_equal(as.numeric(cc[1, , 1]^2 + cc[1, , 2]^2), rep(1, dim(x)[2]))
  # a month and the same month a year later sit at the same place in the year
  months <- format(attr(x, "bin_start"), "%m", tz = "UTC")
  repeated <- which(months == months[1])
  expect_equal(cc[1, repeated[1], 1], cc[1, repeated[2], 1], tolerance = 0.02)
})

test_that("channels are joined in the order they are given", {
  d <- hourly_series(units = c("a", "b"), hours = 24 * 60)
  x <- window_matrix(d, plot, t, temp, window = "week", stats = c("cold_day", "mean"))
  b <- bind_channels(x, calendar_channels(x))
  expect_equal(dimnames(b)[[3]], c("cold_day", "mean", "year_sin", "year_cos"))
  expect_equal(as.numeric(b[, , "mean"]), as.numeric(x[, , "mean"]))
  expect_equal(attr(b, "bin_start"), attr(x, "bin_start"))
  expect_error(bind_channels(x, x), "same name")
  other <- window_matrix(d, plot, t, temp, window = "month")
  expect_error(bind_channels(x, other), "different units or bins")
})
