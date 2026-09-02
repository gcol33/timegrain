test_that("TSS is the maximum over every cut, written out the slow way", {
  set.seed(3)
  for (i in 1:20) {
    n <- sample(8:60, 1L)
    y <- stats::rbinom(n, 1L, 0.35)
    if (length(unique(y)) < 2L) next
    p <- round(stats::runif(n), 2)  # rounding forces ties, which is where a cut rule shows
    expect_equal(tss(y, p), brute_tss(y, p), info = paste("draw", i))
  }
})

test_that("units sharing a prediction are decided together", {
  y <- c(1, 1, 0, 0)
  expect_equal(tss(y, c(0.5, 0.5, 0.5, 0.5)), 0)
  expect_equal(tss(y, c(0.9, 0.5, 0.5, 0.1)), 0.5)
})

test_that("the score does not depend on the order the units arrived in", {
  set.seed(4)
  y <- stats::rbinom(50, 1L, 0.3)
  p <- round(stats::runif(50), 2)
  o <- sample(50)
  expect_equal(tss(y, p), tss(y[o], p[o]))
  expect_equal(roc_auc(y, p), roc_auc(y[o], p[o]))
})

test_that("a one-class cell has no skill to measure", {
  expect_true(is.na(tss(c(0, 0, 0), c(0.1, 0.2, 0.3))))
  expect_true(is.na(tss(c(1, 1, 1), c(0.1, 0.2, 0.3))))
  expect_true(is.na(roc_auc(c(0, 0, 0), c(0.1, 0.2, 0.3))))
  expect_true(is.na(kappa_score(c(0, 0, 0), c(0.1, 0.2, 0.3))))
})

test_that("a perfect and a reversed ranking score the way they earned", {
  y <- c(0, 0, 1, 1)
  expect_equal(tss(y, c(0.1, 0.2, 0.8, 0.9)), 1)
  expect_equal(roc_auc(y, c(0.1, 0.2, 0.8, 0.9)), 1)
  expect_equal(roc_auc(y, c(0.9, 0.8, 0.2, 0.1)), 0)
  expect_equal(tss(y, c(0.9, 0.8, 0.2, 0.1)), 0)
})

test_that("the ROC area is the rank sum of the presences", {
  set.seed(5)
  y <- stats::rbinom(40, 1L, 0.4)
  p <- stats::runif(40)
  pairs <- outer(p[y == 1L], p[y == 0L], ">") + 0.5 * outer(p[y == 1L], p[y == 0L], "==")
  expect_equal(roc_auc(y, p), mean(pairs))
})

test_that("kappa recovers what its two-by-two table says", {
  y <- c(rep(1L, 30), rep(0L, 70))
  p <- c(rep(0.9, 25), rep(0.1, 5), rep(0.9, 10), rep(0.1, 60))
  # 25 both, 60 neither, 10 predicted-only, 5 observed-only
  po <- 0.85
  pe <- (35 * 30 + 65 * 70) / 100^2
  expect_equal(kappa_score(y, p, "prevalence"), (po - pe) / (1 - pe))
})

test_that("the prevalence cut predicts as many presences as were observed", {
  set.seed(6)
  y <- stats::rbinom(200, 1L, 0.25)
  p <- stats::runif(200)
  thr <- decision_threshold(y, p, "prevalence")
  expect_equal(sum(p >= thr), sum(y), tolerance = 1)
})

test_that("agreement counts the decisions two models make differently", {
  y <- c(1, 1, 0, 0)
  same <- model_agreement(y, c(0.9, 0.8, 0.2, 0.1), c(0.7, 0.6, 0.3, 0.2), "prevalence")
  expect_equal(same$n_disagree, 0)
  expect_equal(same$kappa, 1)
  apart <- model_agreement(y, c(0.9, 0.8, 0.2, 0.1), c(0.1, 0.2, 0.8, 0.9), "prevalence")
  expect_equal(apart$n_disagree, 4)
  expect_equal(apart$a_right, 4)
  expect_equal(apart$b_right, 0)
})

test_that("the registered metrics are the ones the package ships", {
  expect_true(all(c("tss", "roc_auc", "kappa") %in% metrics()))
  expect_equal(.metrics_reg$get("tss")(c(0, 1), c(0.1, 0.9)), 1)
  expect_error(.metrics_reg$get("nope"), "unknown metric")
})
