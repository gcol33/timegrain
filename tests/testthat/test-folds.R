test_that("every unit lands in exactly one fold", {
  y <- sim_response(sim_series(n_unit = 97L, days = 2L))
  f <- fold_map(y, v = 10L)
  expect_length(f, 97L)
  expect_equal(names(f), rownames(y))
  expect_setequal(unique(f), 1:10)
})

test_that("folds are the same size to within one unit", {
  y <- sim_response(sim_series(n_unit = 100L, days = 2L))
  n <- table(fold_map(y, v = 10L))
  expect_lte(max(n) - min(n), 2L)
})

test_that("the same seed gives the same map and a different one does not", {
  y <- sim_response(sim_series(n_unit = 60L, days = 2L))
  expect_identical(unclass(fold_map(y, seed = 1L)), unclass(fold_map(y, seed = 1L)))
  expect_false(identical(unclass(fold_map(y, seed = 1L)), unclass(fold_map(y, seed = 2L))))
})

test_that("stratification spreads the stratifying value across the folds", {
  set.seed(11)
  y <- matrix(0, nrow = 200, ncol = 4, dimnames = list(sprintf("p%03d", 1:200), paste0("v", 1:4)))
  richness <- sample(0:4, 200, replace = TRUE)
  for (i in 1:200) if (richness[i] > 0) y[i, seq_len(richness[i])] <- 1

  spread <- function(f) {
    stats::sd(tapply(rowSums(y), f, mean))
  }
  expect_lt(spread(fold_map(y, v = 10L, strata = 5L)),
            spread(fold_map(y, v = 10L, strata = 1L)))
})

test_that("a map can be stratified on something other than richness", {
  y <- sim_response(sim_series(n_unit = 80L, days = 2L))
  elevation <- seq_len(80)
  f <- fold_map(y, v = 8L, by = elevation)
  expect_lt(stats::sd(tapply(elevation, f, mean)), 5)
})

test_that("fold_map leaves the session's random stream where it found it", {
  y <- sim_response(sim_series(n_unit = 40L, days = 2L))
  set.seed(99)
  before <- stats::runif(1L)
  set.seed(99)
  invisible(fold_map(y))
  expect_equal(stats::runif(1L), before)
})

test_that("a fold map arrives named, bare or as a table, and disagreement is an error", {
  units <- sprintf("p%02d", 1:10)
  named <- stats::setNames(rep(1:5, 2), units)
  expect_equal(.as_folds(named, units), rep(1:5, 2))
  expect_equal(.as_folds(unname(named), units), rep(1:5, 2))
  expect_equal(.as_folds(data.frame(id = units, fold = rep(1:5, 2)), units), rep(1:5, 2))
  expect_equal(.as_folds(named[10:1], units), rep(1:5, 2))
  expect_error(.as_folds(named[-1], units), "no fold")
  expect_error(.as_folds(unname(named)[-1], units), "one entry per unit")
})

test_that("a fold count the sample cannot carry is refused", {
  y <- sim_response(sim_series(n_unit = 6L, days = 2L))
  expect_error(fold_map(y, v = 20L), "between 2 and")
  expect_error(fold_map(y, v = 1L), "between 2 and")
})
