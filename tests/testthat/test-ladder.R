constant_learner <- function(offset = 0) {
  learner(
    "constant",
    fit = function(x, y, ...) list(rate = colMeans(y), offset = offset),
    predict = function(model, x) {
      # ranks the units by their mean reading and by how much it moves across the bins, so the arm
      # has a defined direction to score and the windows do not all give the same answer
      m <- apply(x[, , 1, drop = FALSE], 1L, mean) + apply(x[, , 1, drop = FALSE], 1L, stats::sd)
      outer(rank(m) / length(m), model$rate, function(a, b) stats::plogis(a - 0.5 + model$offset))
    }
  )
}

ladder_fixture <- function(v = 4L) {
  sim <- sim_series(n_unit = 48L, days = 90L, seed = 21L)
  y <- sim_response(sim, n_var = 3L, seed = 22L)
  x <- window_matrix(sim$readings, plot, t, temp, window = c("day", "week", "month"))
  list(x = x, y = y, folds = fold_map(y, v = v, seed = 5L))
}

test_that("every arm is scored on the same cells", {
  f <- ladder_fixture()
  lad <- window_ladder(f$x, f$y, list(a = constant_learner(), b = constant_learner(0.2)),
                       folds = f$folds, verbose = FALSE)
  by_arm <- split(lad$scorable, paste(lad$window, lad$learner))
  expect_true(all(vapply(by_arm, identical, logical(1L), by_arm[[1L]])))
  expect_equal(nrow(lad), 3L * 2L * 3L * 4L)
  expect_true(all(is.na(lad$score[!lad$scorable])))
})

test_that("a ladder carries one held-out prediction per unit and arm", {
  f <- ladder_fixture()
  lad <- window_ladder(f$x, f$y, constant_learner(), folds = f$folds, verbose = FALSE)
  preds <- attr(lad, "predictions")
  expect_named(preds, c("day|constant", "week|constant", "month|constant"))
  for (p in preds) {
    expect_equal(dim(p), c(48L, 3L))
    expect_false(anyNA(p))
  }
})

test_that("a unit is never fitted on and scored in the same fold", {
  seen <- new.env(parent = emptyenv())
  seen$train <- list()
  spy <- learner(
    "spy",
    fit = function(x, y, ...) {
      seen$train[[length(seen$train) + 1L]] <- dimnames(x)[[1L]]
      list(rate = colMeans(y))
    },
    predict = function(model, x) {
      seen$train[[length(seen$train)]] <- list(fit = seen$train[[length(seen$train)]],
                                               test = dimnames(x)[[1L]])
      matrix(rep(model$rate, each = dim(x)[1L]), nrow = dim(x)[1L])
    }
  )
  f <- ladder_fixture()
  invisible(window_ladder(f$x, f$y, spy, folds = f$folds, verbose = FALSE))
  for (s in seen$train) {
    expect_length(intersect(s$fit, s$test), 0L)
  }
})

test_that("the summary marks each learner's best window", {
  f <- ladder_fixture()
  lad <- window_ladder(f$x, f$y, list(a = constant_learner(), b = constant_learner(0.3)),
                       folds = f$folds, verbose = FALSE)
  s <- summary(lad)
  expect_equal(sum(s$best), 2L)
  for (l in unique(s$learner)) {
    rows <- s[s$learner == l, ]
    expect_equal(rows$window[rows$best], rows$window[which.max(rows$score)])
  }
})

test_that("a paired contrast runs on cells both arms scored", {
  f <- ladder_fixture()
  lad <- window_ladder(f$x, f$y, list(a = constant_learner(), b = constant_learner(0.3)),
                       folds = f$folds, verbose = FALSE)
  p <- paired_contrast(lad, "week|a", "week|b")
  expect_equal(p$n_variable, 3L)
  expect_lte(p$n_cell, sum(lad$scorable) / 6L)
  expect_true(p$lower <= p$diff && p$diff <= p$upper)
  expect_equal(paired_contrast(lad, "week|a", "week|b")$diff,
               -paired_contrast(lad, "week|b", "week|a")$diff)
})

test_that("naming a learner alone contrasts it at its own best window", {
  f <- ladder_fixture()
  lad <- window_ladder(f$x, f$y, list(a = constant_learner(), b = constant_learner(0.3)),
                       folds = f$folds, verbose = FALSE)
  s <- summary(lad)
  best <- s$window[s$learner == "a" & s$best]
  expect_equal(paired_contrast(lad, "a", "b")$a, paste(best, "a", sep = "|"))
})

test_that("two learners cannot be reported under one name", {
  f <- ladder_fixture()
  expect_error(window_ladder(f$x, f$y, list(constant_learner(), constant_learner(0.3)),
                             folds = f$folds, verbose = FALSE),
               "same name")
})

test_that("the plot returns what it drew", {
  f <- ladder_fixture()
  lad <- window_ladder(f$x, f$y, constant_learner(), folds = f$folds, verbose = FALSE)
  path <- tempfile(fileext = ".png")
  grDevices::png(path)
  drawn <- plot(lad)
  grDevices::dev.off()
  expect_true(file.exists(path))
  expect_equal(nrow(drawn), 3L)
  expect_named(drawn, c("learner", "window", "score", "se"))
  unlink(path)
})

test_that("a ladder on which nothing was scorable reports no level rather than failing", {
  skip_if_not_installed("glmnet")
  sim <- sim_series(n_unit = 24L, days = 40L)
  y <- sim_response(sim)
  x <- window_matrix(sim$readings, plot, t, temp, window = c("week", "month"))
  lad <- suppressWarnings(
    window_ladder(x, y, glmnet_learner(), folds = fold_map(y, v = 3L), verbose = FALSE))
  lad$score <- NA_real_
  out <- summary(lad)
  expect_equal(nrow(out), 0L)
  expect_named(out, c("learner", "window", "score", "n_variable", "best"))
  expect_output(print(lad), "timegrain ladder")
})
