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
