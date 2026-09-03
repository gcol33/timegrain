test_that("a learner of one's own needs nothing but a fit and a predict", {
  mine <- learner(
    "mine",
    fit = function(x, y, ...) colMeans(y),
    predict = function(model, x) matrix(rep(model, each = dim(x)[1L]), nrow = dim(x)[1L])
  )
  sim <- sim_series(n_unit = 20L, days = 30L)
  y <- sim_response(sim, n_var = 2L)
  x <- window_matrix(sim$readings, plot, t, temp, window = "week")
  fit <- fit_learner(mine, x, y)
  p <- stats::predict(fit, x)
  expect_equal(dim(p), c(20L, 2L))
  expect_equal(colnames(p), colnames(y))
  expect_equal(rownames(p), rownames(y))
})

test_that("a registered learner can be asked for by name", {
  expect_true(all(c("elasticnet", "stepwise", "mlp", "cnn", "rescnn") %in% learners()))
  expect_s3_class(.as_learner("elasticnet"), "timegrain_learner")
  expect_error(.as_learner("nope"), "unknown learner")
  register_learner("test_only", function() learner("test_only",
                                                  fit = function(x, y, ...) NULL,
                                                  predict = function(model, x) NULL),
                   overwrite = TRUE)
  expect_true("test_only" %in% learners())
  expect_error(register_learner("test_only", function() NULL), "already registered")
})

test_that("a learner that cannot run says so instead of doing something else", {
  needy <- learner("needy", fit = function(x, y, ...) NULL,
                   predict = function(model, x) NULL,
                   needs = "a.package.that.does.not.exist")
  sim <- sim_series(n_unit = 10L, days = 10L)
  x <- window_matrix(sim$readings, plot, t, temp, window = "week")
  expect_error(fit_learner(needy, x, sim_response(sim)),
               "needs a.package.that.does.not.exist")
})

test_that("the response is matched to the representation by unit, not by position", {
  sim <- sim_series(n_unit = 20L, days = 30L)
  y <- sim_response(sim, n_var = 2L)
  x <- window_matrix(sim$readings, plot, t, temp, window = "week")
  seen <- NULL
  spy <- learner("spy",
                 fit = function(x, y, ...) {
                   seen <<- y
                   colMeans(y)
                 },
                 predict = function(model, x)
                   matrix(rep(model, each = dim(x)[1L]), nrow = dim(x)[1L]))
  invisible(fit_learner(spy, x, y[nrow(y):1, , drop = FALSE]))
  expect_equal(rownames(seen), dimnames(x)[[1]])
  expect_equal(seen, y)
  expect_error(fit_learner(spy, x, y[-1, , drop = FALSE]), "not the response")
})

test_that("flattening names every predictor by its bin and its channel", {
  sim <- sim_series(n_unit = 5L, days = 20L)
  x <- window_matrix(sim$readings, plot, t, temp, window = "week", stats = c("mean", "max"))
  m <- .flatten(x)
  expect_equal(dim(m), c(5L, dim(x)[2] * 2L))
  expect_equal(m[, 1], x[, 1, "mean"])
  expect_true(all(grepl("^mean@|^max@", colnames(m))))
})

test_that("a scaler is computed on what it is given and applied to something else", {
  m <- matrix(c(1, 2, 3, 10, 20, 30), ncol = 2)
  s <- .scaler(m)
  expect_equal(s$centre, c(2, 20))
  expect_equal(.apply_scaler(s, m)[, 1], c(-1, 0, 1))
  scalar <- .scaler(m, per_column = FALSE)
  expect_equal(scalar$centre, rep(mean(m), 2))
  constant <- .scaler(matrix(1, nrow = 4, ncol = 2))
  expect_equal(constant$scale, c(1, 1))
})

test_that("the penalised learner fits, predicts and refuses a different representation", {
  skip_if_not_installed("glmnet")
  sim <- sim_series(n_unit = 60L, days = 60L, seed = 31L)
  y <- sim_response(sim, n_var = 2L, seed = 32L)
  x <- window_matrix(sim$readings, plot, t, temp, window = "week")
  fit <- fit_learner(elasticnet_learner(), x, y)
  p <- stats::predict(fit, x)
  expect_true(all(p >= 0 & p <= 1))
  expect_gt(tss(y[, 1], p[, 1]), 0.4)
  other <- window_matrix(sim$readings, plot, t, temp, window = "month")
  expect_error(stats::predict(fit, other), "different channels or bins")
})

test_that("forward selection stops at its budget and is non-monotone in a predictor", {
  sim <- sim_series(n_unit = 60L, days = 60L, seed = 33L)
  y <- sim_response(sim, n_var = 1L, seed = 34L)
  x <- window_matrix(sim$readings, plot, t, temp, window = "month")
  fit <- fit_learner(stepwise_learner(max_terms = 2L), x, y)
  chosen <- fit$model$models[[1L]]$columns
  expect_lte(length(chosen), 2L)
  p <- stats::predict(fit, x)
  expect_true(all(p >= 0 & p <= 1))
})

test_that("an ensemble averages its members before the threshold is chosen", {
  skip_if_not_installed("glmnet")
  sim <- sim_series(n_unit = 50L, days = 60L, seed = 41L)
  y <- sim_response(sim, n_var = 2L, seed = 42L)
  x <- window_matrix(sim$readings, plot, t, temp, window = "week")

  members <- list(a = elasticnet_learner(alpha = 0.5, seed = 1L),
                  b = elasticnet_learner(alpha = 1, seed = 1L))
  both <- suppressWarnings(stats::predict(fit_learner(ensemble_learner(members), x, y), x))
  one <- suppressWarnings(stats::predict(fit_learner(members$a, x, y), x))
  two <- suppressWarnings(stats::predict(fit_learner(members$b, x, y), x))
  expect_equal(both, (one + two) / 2)

  tilted <- suppressWarnings(stats::predict(
    fit_learner(ensemble_learner(members, weights = c(3, 1)), x, y), x))
  expect_equal(tilted, 0.75 * one + 0.25 * two)
  expect_error(ensemble_learner(list(elasticnet_learner())), "at least two members")
  expect_error(ensemble_learner(members, weights = c(1, 0, 1)), "one non-negative number")
})

test_that("a setting given at fit time overrides the one a linear learner carries", {
  skip_if_not_installed("glmnet")
  sim <- sim_series(n_unit = 40L, days = 40L, seed = 43L)
  y <- sim_response(sim, n_var = 1L, seed = 44L)
  x <- window_matrix(sim$readings, plot, t, temp, window = "week")
  overridden <- suppressWarnings(fit_learner(elasticnet_learner(), x, y, squares = FALSE))
  built <- suppressWarnings(fit_learner(elasticnet_learner(squares = FALSE), x, y))
  expect_false(overridden$model$squares)
  expect_equal(suppressWarnings(stats::predict(overridden, x)),
               suppressWarnings(stats::predict(built, x)))
})

test_that("predicting a single unit returns one row and not one column", {
  skip_if_not_installed("glmnet")
  sim <- sim_series(n_unit = 24L, days = 40L)
  y <- sim_response(sim, n_var = 3L)
  x <- window_matrix(sim$readings, plot, t, temp, window = "week")
  one <- x[1L, , , drop = FALSE]
  attributes(one) <- utils::modifyList(attributes(x)[c("window", "stats", "year_start",
                                                       "bin_start", "bin_end", "bin_partial")],
                                       list(dim = dim(one), dimnames = dimnames(one),
                                            class = c("timegrain_matrix", "array")))
  for (l in list(elasticnet_learner(), stepwise_learner())) {
    fit <- suppressWarnings(fit_learner(l, x, y))
    p <- stats::predict(fit, one)
    expect_equal(dim(p), c(1L, 3L))
    expect_identical(rownames(p), dimnames(x)[[1L]][1L])
  }
})
