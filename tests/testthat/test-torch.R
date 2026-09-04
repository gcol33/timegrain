skip_if_no_torch <- function() {
  skip_if_not_installed("torch")
  skip_if_not(torch::torch_is_installed(), "the torch runtime is not installed")
}

torch_fixture <- function(n_unit = 40L, days = 90L) {
  sim <- sim_series(n_unit = n_unit, days = days, seed = 81L)
  list(sim = sim,
       y = sim_response(sim, n_var = 2L, seed = 82L),
       x = grain_matrix(sim$readings, plot, t, temp, grain = "week",
                         stats = c("cold_day", "mean", "warm_day")))
}

test_that("every encoder fits and returns one probability per unit and variable", {
  skip_if_no_torch()
  f <- torch_fixture()
  for (l in list(mlp_learner(epochs = 3L), cnn_learner(epochs = 3L),
                 rescnn_learner(epochs = 3L, channels = c(16L, 32L)))) {
    fit <- fit_learner(l, f$x, f$y)
    p <- stats::predict(fit, f$x)
    expect_equal(dim(p), c(40L, 2L), info = l$name)
    expect_true(all(p > 0 & p < 1), info = l$name)
    expect_equal(rownames(p), rownames(f$y), info = l$name)
  }
})

test_that("the same seed gives the same fit", {
  skip_if_no_torch()
  f <- torch_fixture(n_unit = 24L, days = 60L)
  a <- stats::predict(fit_learner(cnn_learner(epochs = 3L, seed = 4L), f$x, f$y), f$x)
  b <- stats::predict(fit_learner(cnn_learner(epochs = 3L, seed = 4L), f$x, f$y), f$x)
  expect_equal(a, b)
})

test_that("the stack still runs where the record is one bin per year", {
  skip_if_no_torch()
  sim <- sim_series(n_unit = 24L, days = 400L, seed = 83L)
  y <- sim_response(sim, n_var = 2L, seed = 84L)
  for (w in c("season", "year")) {
    x <- grain_matrix(sim$readings, plot, t, temp, grain = w)
    expect_lte(dim(x)[2L], 5L)
    for (l in list(cnn_learner(epochs = 2L), rescnn_learner(epochs = 2L,
                                                            channels = c(16L, 32L)))) {
      p <- stats::predict(fit_learner(l, x, y), x)
      expect_equal(dim(p), c(24L, 2L), info = paste(l$name, w))
    }
  }
})

test_that("standardisation is computed on the units the learner was handed", {
  skip_if_no_torch()
  f <- torch_fixture(n_unit = 24L, days = 60L)
  half <- seq_len(12L)
  fit <- fit_learner(cnn_learner(epochs = 2L), .subset_units(f$x, half),
                     f$y[half, , drop = FALSE])
  expect_equal(fit$model$scaler$centre[1L], mean(as.numeric(f$x[half, , ])))
  expect_false(isTRUE(all.equal(fit$model$scaler$centre[1L], mean(as.numeric(f$x)))))
})

test_that("an encoder refuses a representation it was not fitted on", {
  skip_if_no_torch()
  f <- torch_fixture(n_unit = 24L, days = 60L)
  fit <- fit_learner(cnn_learner(epochs = 2L), f$x, f$y)
  other <- grain_matrix(f$sim$readings, plot, t, temp, grain = "month")
  expect_error(stats::predict(fit, other), "different channels or bins")
})

test_that("a fully connected encoder recovers a planted signal", {
  skip_if_no_torch()
  sim <- sim_series(n_unit = 90L, days = 90L, sd = 0.3, level = 3, seed = 85L)
  y <- sim_response(sim, n_var = 2L, strength = 4, seed = 86L)
  x <- grain_matrix(sim$readings, plot, t, temp, grain = "week")
  fit <- fit_learner(mlp_learner(epochs = 40L, seed = 3L), x, y)
  p <- stats::predict(fit, x)
  expect_gt(roc_auc(y[, 1], p[, 1]), 0.8)
})

test_that("weight averaging runs the whole averaging grain and returns a usable fit", {
  skip_if_no_torch()
  f <- torch_fixture(n_unit = 30L, days = 60L)
  fit <- fit_learner(cnn_learner(epochs = 6L, swa = TRUE, swa_start = 0.5), f$x, f$y)
  p <- stats::predict(fit, f$x)
  expect_equal(dim(p), c(30L, 2L))
  expect_true(all(is.finite(p) & p > 0 & p < 1))
})

test_that("a setting given at fit time overrides the one the learner carries", {
  skip_if_no_torch()
  f <- torch_fixture(n_unit = 20L, days = 40L)
  wide <- fit_learner(cnn_learner(epochs = 2L), f$x, f$y, channels = c(8L, 16L))
  narrow <- fit_learner(cnn_learner(epochs = 2L, channels = c(8L, 16L)), f$x, f$y)
  expect_equal(stats::predict(wide, f$x), stats::predict(narrow, f$x))
  expect_false(isTRUE(all.equal(stats::predict(wide, f$x),
                                stats::predict(fit_learner(cnn_learner(epochs = 2L), f$x, f$y),
                                               f$x))))
})

test_that("a setting the learner does not have is refused rather than ignored", {
  skip_if_no_torch()
  f <- torch_fixture(n_unit = 20L, days = 40L)
  expect_error(fit_learner(cnn_learner(epochs = 2L), f$x, f$y, chanels = c(8L, 16L)),
               "no setting called chanels")
})
