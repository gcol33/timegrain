#!/usr/bin/env Rscript
# Reproduce the Schrankogel grid with timegrain.
#
#   Rscript schrankogel.R <deposit_dir> <out_dir> [options]
#
# <deposit_dir> is the unpacked data directory of the Chytry et al. deposit
# (doi:10.5281/zenodo.17047026), holding logger_data.csv, spe_wide.csv, seasons.csv and
# output_temperature_variables_scaled.csv. <out_dir> receives one CSV per stage.
#
# Options, each --name=value:
#   --stages    which stages to run, comma-separated: contract, representation, baseline,
#               networks, contrasts, windows, inflation. Default all but networks.
#   --windows   which windows the network grid covers. Default day,week,month,season,year.
#   --learners  which encoders the network grid covers, plus `ensemble` for the
#               convolutional-plus-residual set averaged before scoring. Default cnn.
#   --baseline  which aggregated-feature arms to fit: elastic_net, stepwise, or both. Default
#               elastic_net. Forward selection over 188 columns is three glm fits per candidate
#               per species per fold and takes many hours single-threaded.
#   --folds     a CSV of logger_ID and fold to use instead of building one.
#   --epochs    epoch budget per network fit. Default 60, the budget the study used.
#
# The four fine windows are affordable on a processor; the hourly rung is 26,304 steps per plot
# and wants a graphics processor, as it had in the study. Nothing here caps the data: a stage
# either runs over all 894 plots and all 101 species or it does not run.

suppressMessages({
  library(timegrain)
})

# ---- arguments -------------------------------------------------------------------------------

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 2L) {
  stop("usage: Rscript schrankogel.R <deposit_dir> <out_dir> [--name=value ...]", call. = FALSE)
}
deposit <- args[1L]
out_dir <- args[2L]
opt <- local({
  named <- grep("^--", args, value = TRUE)
  keys <- sub("^--([^=]+)=.*$", "\\1", named)
  stats::setNames(as.list(sub("^--[^=]+=", "", named)), keys)
})
pick <- function(name, default) if (is.null(opt[[name]])) default else opt[[name]]
split_opt <- function(name, default) {
  strsplit(pick(name, default), ",", fixed = TRUE)[[1L]]
}

stages <- split_opt("stages", "contract,representation,baseline,contrasts,inflation")
grid_windows <- split_opt("windows", "day,week,month,season,year")
grid_learners <- split_opt("learners", "cnn")
baseline_arms <- split_opt("baseline", "elastic_net")
epochs <- as.integer(pick("epochs", "60"))
dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)

say <- function(...) cat(format(Sys.time(), "[%H:%M:%S] "), ..., "\n", sep = "")
assert_equal <- function(what, got, expected) {
  say(sprintf("%-38s %s", paste0(what, ":"), format(got)))
  if (!isTRUE(all.equal(got, expected))) {
    stop(what, " is ", format(got), ", the deposit gives ", format(expected),
         ". The input is not what this script was written against.", call. = FALSE)
  }
}
write_out <- function(x, name) {
  path <- file.path(out_dir, name)
  utils::write.csv(x, path, row.names = FALSE)
  say("wrote ", path)
  invisible(path)
}

# The contract of Chytry et al.: species in at least 25 plots, then five aggregate taxa removed.
MIN_OCCURRENCES <- 25L
DROP_TAXA <- c("Alchemilla vulgaris agg.", "Taraxacum sp.", "Festuca halleri agg.",
               "Euphrasia sp.", "Phleum alpinum agg.")
CV_FOLDS <- 10L
CV_SEED <- 1L
REPORTED_STATS <- c("cold_day", "mean", "warm_day")

# ---- the response, the folds and the cells ----------------------------------------------------

say("reading ", file.path(deposit, "spe_wide.csv"))
spe <- utils::read.csv(file.path(deposit, "spe_wide.csv"), check.names = FALSE)
rownames(spe) <- as.character(spe$logger_ID)
counts <- colSums(spe[setdiff(names(spe), "logger_ID")])
keep <- setdiff(names(counts)[counts >= MIN_OCCURRENCES], DROP_TAXA)
y <- as.matrix(spe[, keep, drop = FALSE])

assert_equal("plots", nrow(y), 894L)
assert_equal("species after the contract filter", ncol(y), 101L)
assert_equal("rarest retained species", min(colSums(y)), 26)

folds <- if (!is.null(opt$folds)) {
  say("reading the fold map from ", opt$folds)
  f <- utils::read.csv(opt$folds)
  stats::setNames(as.integer(f$fold), as.character(f$logger_ID))
} else {
  say("building a fold map: ", CV_FOLDS, " folds, seed ", CV_SEED, ", richness quintiles")
  fold_map(y, v = CV_FOLDS, seed = CV_SEED, strata = 5L)
}

cells <- scorable_cells(y, folds)
assert_equal("cells", nrow(cells), 1010L)
say(sprintf("%-38s %d (%.1f%%)", "scorable cells:", sum(cells$scorable),
            100 * mean(cells$scorable)))
say(sprintf("%-38s %d of %d", "species with a scorable fold:",
            sum(tapply(cells$scorable, cells$variable, any)), ncol(y)))
write_out(cells, "cells.csv")

if (!"representation" %in% stages && !"networks" %in% stages) {
  readings <- NULL
} else {
  say("reading ", file.path(deposit, "logger_data.csv"), " (1.2 GB, a few minutes)")
  readings <- utils::read.csv(
    file.path(deposit, "logger_data.csv"),
    colClasses = c(logger_ID = "character", date = "character", logger_serial_number = "NULL",
                   temp = "numeric", day = "NULL", month = "NULL"))
  readings$date <- as.POSIXct(readings$date, format = "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
  assert_equal("readings", nrow(readings), 894L * 26304L)
  assert_equal("readings per plot", nrow(readings) / length(unique(readings$logger_ID)), 26304)
}

# The deposit cuts its seasons at the equinoxes and the solstices rather than on the first of a
# month, and labels every date of the record in seasons.csv. Reading that file back as a binning
# function is how the season rung of the ladder is the deposit's season rather than a quarter.
astronomical_seasons <- function(path) {
  labels <- utils::read.csv(path)
  key <- paste(labels$season, format(as.Date(labels$day), "%Y"))
  edges <- as.POSIXct(paste0(labels$day[!duplicated(key)], " 00:00:00"), tz = "UTC")
  edges <- sort(edges)
  function(when) edges[findInterval(as.numeric(when), as.numeric(edges))]
}

BINNING <- list(hour = "hour", halfday = "halfday", day = "day", week = "week", month = "month",
                season = astronomical_seasons(file.path(deposit, "seasons.csv")), year = "year")
EXPECTED_BINS <- c(hour = 26304L, halfday = 2192L, day = 1096L, week = 157L, month = 36L,
                   season = 13L, year = 3L)

build <- function(window, stats) {
  x <- window_matrix(readings, logger_ID, date, temp, window = BINNING[[window]], stats = stats)
  assert_equal(paste(window, "bins"), dim(x)[2L], EXPECTED_BINS[[window]])
  x
}

if ("representation" %in% stages) {
  say("building the representation at every window")
  shape <- lapply(names(BINNING), function(w) {
    x <- build(w, "mean")
    data.frame(window = w, bins = dim(x)[2L], readings_per_bin = mean(attr(x, "bin_n")),
               numbers_per_plot = dim(x)[2L], stringsAsFactors = FALSE)
  })
  shape <- do.call(rbind, shape)
  # The reported reading is three channels of whole days, so a week of it is three numbers.
  shape$numbers_per_plot_reported <- ifelse(shape$window %in% c("hour", "halfday"), NA_integer_,
                                            3L * shape$bins)
  write_out(shape, "representation.csv")
}

# ---- the aggregated-feature arms --------------------------------------------------------------

if ("baseline" %in% stages) {
  say("reading the deposit's aggregated temperature features")
  agg <- utils::read.csv(file.path(deposit, "output_temperature_variables_scaled.csv"),
                         check.names = FALSE)
  rownames(agg) <- as.character(agg$logger_ID)
  agg <- as.matrix(agg[rownames(y), setdiff(names(agg), "logger_ID"), drop = FALSE])
  assert_equal("aggregated temperature variables", ncol(agg), 188L)

  features <- feature_matrix(agg, label = "aggregates")
  say("fitting the aggregated-feature arms, selection redone inside every fold")
  arms <- list(
    elastic_net = elasticnet_learner(alpha = 0.5, n_inner = 5L, squares = TRUE, seed = CV_SEED),
    stepwise = stepwise_learner(max_terms = 3L, degree = 2L))[baseline_arms]
  baseline <- window_ladder(features, y, arms, folds = folds)
  write_out(baseline, "baseline.csv")
  print(summary(baseline))
}

# ---- the network grid ---------------------------------------------------------------------

if ("networks" %in% stages) {
  # The eleven-member set of the study spans two architectures, three widths and three seeds, and
  # is trained with weight averaging. Members were chosen on inner-validation strength and on
  # architectural diversity, never on the held-out folds.
  members <- c(
    lapply(list(c(16L, 32L, 64L, 128L), c(32L, 64L, 128L, 256L), c(16L, 32L, 64L)),
           function(ch) cnn_learner(channels = ch, epochs = epochs, swa = TRUE)),
    lapply(c(5L, 7L, 9L), function(k) cnn_learner(kernel = k, epochs = epochs, swa = TRUE)),
    lapply(c(1L, 2L, 3L), function(sd) cnn_learner(epochs = epochs, swa = TRUE, seed = sd)),
    lapply(c(1L, 2L), function(sd) rescnn_learner(epochs = epochs, swa = TRUE, seed = sd)))
  names(members) <- sprintf("m%02d", seq_along(members))

  encoders <- list(mlp = mlp_learner(epochs = epochs), cnn = cnn_learner(epochs = epochs),
                   rescnn = rescnn_learner(epochs = epochs),
                   ensemble = ensemble_learner(members))[grid_learners]
  for (statistic in c("mean", "extremeday")) {
    windows <- if (statistic == "mean") grid_windows else
      intersect(grid_windows, c("week", "month", "season", "year"))
    if (!length(windows)) {
      next
    }
    stats_used <- if (statistic == "mean") "mean" else REPORTED_STATS
    say("network grid on the ", statistic, " reading: ", paste(windows, collapse = ", "))
    set <- timegrain_set(stats::setNames(
      lapply(windows, function(w) {
        x <- build(w, stats_used)
        bind_channels(x, calendar_channels(x))
      }), windows))
    grid <- window_ladder(set, y, encoders, folds = folds, keep_fits = FALSE)
    write_out(grid, paste0("networks_", statistic, ".csv"))
    print(summary(grid))
  }
}

# ---- the contrasts every claim is made on -----------------------------------------------------

if ("contrasts" %in% stages) {
  parts <- list.files(out_dir, pattern = "^(baseline|networks_)", full.names = TRUE)
  if (length(parts) < 2L) {
    say("contrasts need at least two result files in ", out_dir, "; skipping")
  } else {
    ladder <- do.call(rbind, lapply(parts, utils::read.csv, stringsAsFactors = FALSE))
    ladder <- structure(ladder, class = c("timegrain_ladder", "data.frame"),
                        metric = "tss", response = "presence_absence")
    arms <- unique(paste(ladder$window, ladder$learner, sep = "|"))
    pairs <- utils::combn(arms, 2L, simplify = FALSE)
    out <- do.call(rbind, lapply(pairs, function(p) paired_contrast(ladder, p[1L], p[2L])))
    write_out(out[order(-out$diff), ], "contrasts.csv")
  }
}

# ---- each window against its architecture's best ----------------------------------------------

if ("windows" %in% stages) {
  parts <- list.files(out_dir, pattern = "^networks_mean", full.names = TRUE)
  if (!length(parts)) {
    say("the window contrast needs networks_mean.csv in ", out_dir, "; skipping")
  } else {
    ladder <- utils::read.csv(parts[1L], stringsAsFactors = FALSE)
    ladder <- structure(ladder, class = c("timegrain_ladder", "data.frame"),
                        metric = "tss", response = "presence_absence")
    out <- do.call(rbind, lapply(unique(ladder$learner), function(l)
      window_contrasts(ladder, learner = l)))
    out$p_bh <- stats::p.adjust(out$p_value, method = "BH")
    write_out(out, "window_contrasts.csv")
    print(out)
  }
}

# ---- what the reported level is an upper bound on ---------------------------------------------

if ("inflation" %in% stages) {
  say("measuring how much the self-selected threshold inflates a level on this design")
  out <- tss_inflation(y, folds, skill = c(0.6, 0.7, 0.9), replicates = 2000L, seed = CV_SEED)
  write_out(out, "inflation.csv")
  print(out)

  # What a level actually read is consistent with, which is the only reading of a level that is
  # about the population rather than about the scoring rule.
  levels_read <- list.files(out_dir, pattern = "^(baseline|networks_)", full.names = TRUE)
  if (length(levels_read)) {
    ladder <- do.call(rbind, lapply(levels_read, utils::read.csv, stringsAsFactors = FALSE))
    ladder <- structure(ladder, class = c("timegrain_ladder", "data.frame"),
                        metric = "tss", response = "presence_absence")
    reported <- summary(ladder)
    back <- implied_skill(y, folds, observed = reported$score, replicates = 500L, seed = CV_SEED)
    write_out(cbind(reported[c("learner", "window")], back), "implied_skill.csv")
  }
}

say("done")
