fixture_dir <- function() {
  installed <- system.file("spec", "fixtures", package = "timegrain")
  candidates <- c(installed, "../../inst/spec/fixtures", "inst/spec/fixtures")
  for (p in candidates) {
    if (nzchar(p) && file.exists(file.path(p, "digests.csv"))) {
      return(p)
    }
  }
  NULL
}

fixture_series <- function(dir, name) {
  file <- if (name == "aligned") "series.csv" else "series_offset.csv"
  s <- read.csv(file.path(dir, file), stringsAsFactors = FALSE)
  s$time <- as.POSIXct(s$time, format = "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
  s
}

fixture_binning <- function(dir, name, window) {
  if (window != "astronomical") {
    return(window)
  }
  edges <- read.csv(file.path(dir, "seasons.csv"), stringsAsFactors = FALSE)
  edges <- as.POSIXct(edges$edge[edges$series == name], format = "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
  function(when) edges[findInterval(as.numeric(when), as.numeric(edges))]
}

test_that("every representation matches the digest the Python side reads", {
  dir <- fixture_dir()
  skip_if(is.null(dir), "fixtures are not in the built package")

  expected <- read.csv(file.path(dir, "digests.csv"), stringsAsFactors = FALSE)
  series <- lapply(stats::setNames(nm = unique(expected$series)), fixture_series, dir = dir)

  for (i in seq_len(nrow(expected))) {
    row <- expected[i, ]
    label <- paste(row$series, row$window, row$year_start, row$partial, row$stat)
    x <- window_matrix(series[[row$series]], id, time, value,
                       window = fixture_binning(dir, row$series, row$window),
                       stats = strsplit(row$stat, "+", fixed = TRUE)[[1L]],
                       year_start = row$year_start, partial = row$partial)
    start <- attr(x, "bin_start")
    # The shape is asserted before the digest, so a binning that puts the record into a different
    # number of bins is reported as that rather than as an unexplained hash mismatch.
    expect_equal(dim(x)[1], row$n_unit, info = label)
    expect_equal(dim(x)[2], row$n_bin, info = label)
    expect_equal(format(start[1], "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"), row$first_bin, info = label)
    expect_equal(format(start[length(start)], "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
                 row$last_bin, info = label)
    expect_equal(sum(attr(x, "bin_partial")), row$n_partial, info = label)
    expect_identical(timegrain:::.digest_array(x), row$digest, info = label)
  }
})

test_that("the fixtures cover a record that starts on no bin boundary", {
  dir <- fixture_dir()
  skip_if(is.null(dir), "fixtures are not in the built package")
  expected <- read.csv(file.path(dir, "digests.csv"), stringsAsFactors = FALSE)

  # A record beginning at midnight on the year_start anniversary puts every window in phase with
  # it, which is the one input on which a rule that keeps a partial leading bin and a rule that
  # never makes one agree. The contract is only a contract if it also carries the other case.
  expect_true(all(c("aligned", "offset") %in% expected$series))
  offset <- expected[expected$series == "offset", ]
  expect_true(all(c("hour", "halfday", "day", "week", "month", "season", "year", "astronomical")
                  %in% offset$window))
  expect_gt(sum(offset$n_partial), 0)
  expect_true(all(c("keep", "drop") %in% expected$partial))
  expect_gt(length(unique(expected$year_start)), 1L)

  # Every window whose bin count the offset record splits differently from the aligned one is
  # pinned by a row of its own, so a change to either binning rule moves a digest here.
  aligned <- expected[expected$series == "aligned" & expected$stat == "mean" &
                        expected$partial == "keep" & expected$year_start == "09-01", ]
  expect_setequal(aligned$window,
                  c("hour", "halfday", "day", "week", "month", "season", "year", "astronomical"))
})

test_that("dropping every bin is an error rather than an empty representation", {
  t <- seq(as.POSIXct("2021-10-17 05:00:00", tz = "UTC"), by = "hour", length.out = 24 * 40)
  d <- data.frame(plot = "a", t = t, temp = sin(seq_along(t) / 24), stringsAsFactors = FALSE)
  expect_error(window_matrix(d, plot, t, temp, window = "year", partial = "drop"),
               "no whole year")
  expect_error(window_matrix(d, plot, t, temp, window = "day", partial = "sometimes"),
               "'arg' should be one of")
})

test_that("the digest is the LF-terminated twelve-place form and nothing else", {
  x <- array(c(1, -0.5), dim = c(2L, 1L, 1L))
  body <- charToRaw("1.000000000000\n-0.500000000000\n")
  f <- tempfile()
  con <- file(f, open = "wb")
  writeBin(body, con)
  close(con)
  expect_identical(timegrain:::.digest_array(x), unname(tools::md5sum(f)))
  unlink(f)
})
