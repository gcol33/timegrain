skip_if_no_mixed_model <- function() {
  for (p in c("lme4", "lmerTest", "emmeans")) skip_if_not_installed(p)
}

contrast_fixture <- function() {
  sim <- sim_series(n_unit = 60L, days = 90L, sd = 6, seed = 51L)
  y <- sim_response(sim, n_var = 6L, seed = 52L)
  x <- grain_matrix(sim$readings, plot, t, temp, grain = c("day", "week", "month"))
  suppressWarnings(grain_ladder(x, y, elasticnet_learner(), folds = fold_map(y, v = 4L, seed = 9L),
                                 verbose = FALSE))
}

test_that("every grain is compared against the reference, and the reference is not", {
  skip_if_no_mixed_model()
  lad <- contrast_fixture()
  out <- grain_contrasts(lad)
  best <- summary(lad)$grain[summary(lad)$best]
  expect_equal(nrow(out), 2L)
  expect_false(best %in% out$grain)
  expect_setequal(out$grain, setdiff(unique(lad$grain), best))
  expect_true(all(out$reference == best))
  expect_true(all(out$lower <= out$diff & out$diff <= out$upper))
  expect_true(all(out$diff <= 0))
})

test_that("a reference of one's own is honoured", {
  skip_if_no_mixed_model()
  lad <- contrast_fixture()
  out <- grain_contrasts(lad, reference = "day")
  expect_true(all(out$reference == "day"))
  expect_setequal(out$grain, c("week", "month"))
})

test_that("a contrast says which learner it needs and which grains it has", {
  skip_if_no_mixed_model()
  lad <- contrast_fixture()
  expect_error(grain_contrasts(lad, reference = "fortnight"), "not a grain")
  expect_error(grain_contrasts(lad["day" == lad$grain, ]), "at least two grains")
})
