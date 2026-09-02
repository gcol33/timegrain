fixture_dir <- function() {
  for (p in c("../../spec/fixtures", "spec/fixtures")) {
    if (file.exists(file.path(p, "digests.csv"))) {
      return(p)
    }
  }
  NULL
}

test_that("every representation matches the digest the Python side reads", {
  dir <- fixture_dir()
  skip_if(is.null(dir), "fixtures are not in the built package")

  series <- read.csv(file.path(dir, "series.csv"), stringsAsFactors = FALSE)
  series$time <- as.POSIXct(series$time, format = "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
  expected <- read.csv(file.path(dir, "digests.csv"), stringsAsFactors = FALSE)

  for (i in seq_len(nrow(expected))) {
    row <- expected[i, ]
    stats <- strsplit(row$stat, "+", fixed = TRUE)[[1L]]
    x <- window_matrix(series, id, time, value, window = row$window, stats = stats)
    expect_equal(dim(x)[1], row$n_unit, info = paste(row$window, row$stat))
    expect_equal(dim(x)[2], row$n_bin, info = paste(row$window, row$stat))
    expect_identical(timegrain:::.digest_array(x), row$digest,
                     info = paste(row$window, row$stat))
  }
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
