#!/usr/bin/env Rscript
# Reads the replicate files a run left on disk and answers the four questions the benchmark exists
# for, one row per cell, each with the Monte Carlo margin the replicate count buys. Selection rule,
# estimator and metric are read off the same stored rows, so a second reading costs nothing and no
# fit is repeated.
#
# Usage:
#   Rscript inst/benchmark/summarise.R --out=<results dir> [--csv=<file>]

.sum_args <- function() {
  raw <- commandArgs(trailingOnly = TRUE)
  out <- list(out = "benchmark-results", csv = NA_character_)
  for (a in raw) {
    key <- sub("^--([a-z]+)=.*$", "\\1", a)
    out[[key]] <- sub("^--[a-z]+=", "", a)
  }
  out
}

opt <- .sum_args()
here <- grep("^--file=", commandArgs(FALSE), value = TRUE)
here <- if (length(here)) dirname(normalizePath(sub("^--file=", "", here[1L]))) else getwd()
source(file.path(here, "design.R"))

files <- list.files(opt$out, pattern = "^rep_[0-9]+[.]csv[.]gz$", recursive = TRUE,
                    full.names = TRUE)
if (!length(files)) {
  stop("no replicate files under ", opt$out, ".", call. = FALSE)
}
rows <- do.call(rbind, lapply(files, utils::read.csv, stringsAsFactors = FALSE))

# A cell that mixed two candidate sets, two package builds or two scales is not one cell, and the
# rows cannot be pooled. Say so rather than averaging over it.
mixed <- unique(rows[c("cell_id", "scale", "candidate_digest", "learner_digest", "pkg_commit")])
clash <- names(which(table(mixed$cell_id) > 1L))
if (length(clash)) {
  stop("these cells hold rows from more than one design or build: ",
       paste(clash, collapse = ", "), ". Rerun them under one.", call. = FALSE)
}

.pick <- function(d, arm, quantity, metric = BENCH$metric) {
  keep <- d$arm == arm & d$quantity == quantity
  if (!is.na(metric)) {
    keep <- keep & !is.na(d$metric) & d$metric == metric
  }
  d[keep, , drop = FALSE]
}

.margin <- function(v) 1.96 * stats::sd(v) / sqrt(length(v))

.proportion <- function(hit) {
  p <- mean(hit)
  c(p = p, mc = 1.96 * sqrt(p * (1 - p) / length(hit)))
}

per_cell <- lapply(split(rows, rows$cell_id), function(d) {
  reps <- sort(unique(d$replicate))
  true_grain <- d$true_grain[1L]
  adequate <- if (is.na(true_grain)) character() else BENCH$nesting[[true_grain]]

  chosen <- .pick(d, "nested", "selected")
  by_rep <- vapply(reps, function(r) {
    pick <- chosen$candidate[chosen$replicate == r]
    window <- sub("[.].*$", "", pick)
    c(exact = mean(pick == paste0(true_grain, ".mean")),
      window = mean(window == true_grain),
      adequate = mean(window %in% adequate))
  }, numeric(3L))

  nested_rep <- .pick(d, "nested", "reported")$value[order(.pick(d, "nested", "reported")$replicate)]
  nested_true <- .pick(d, "nested", "true")$value[order(.pick(d, "nested", "true")$replicate)]
  single_rep <- .pick(d, "single_loop", "reported")
  single_true <- .pick(d, "single_loop", "true")
  oracle <- .pick(d, "oracle", "true")
  lower <- .pick(d, "nested", "reported_lower")
  upper <- .pick(d, "nested", "reported_upper")

  covered <- (lower$value[order(lower$replicate)] <= nested_true) &
    (upper$value[order(upper$replicate)] >= nested_true)
  cov <- .proportion(covered)
  nested_bias <- nested_rep - nested_true
  single_bias <- single_rep$value[order(single_rep$replicate)] -
    single_true$value[order(single_true$replicate)]
  regret <- oracle$value[order(oracle$replicate)] - nested_true

  data.frame(
    cell_id = d$cell_id[1L], scale = d$scale[1L], block = d$block[1L],
    mechanism = d$mechanism[1L], n_unit = d$n_unit[1L], replicates = length(reps),
    true_grain = true_grain,
    select_exact = mean(by_rep["exact", ]), select_exact_mc = .margin(by_rep["exact", ]),
    select_window = mean(by_rep["window", ]), select_window_mc = .margin(by_rep["window", ]),
    select_adequate = mean(by_rep["adequate", ]),
    select_adequate_mc = .margin(by_rep["adequate", ]),
    nested_reported = mean(nested_rep), nested_true = mean(nested_true),
    nested_bias = mean(nested_bias), nested_bias_mc = .margin(nested_bias),
    single_reported = mean(single_rep$value), single_bias = mean(single_bias),
    single_bias_mc = .margin(single_bias),
    optimism_gap = mean(single_bias) - mean(nested_bias),
    optimism_gap_mc = .margin(single_bias - nested_bias),
    coverage = cov[["p"]], coverage_mc = cov[["mc"]],
    regret = mean(regret), regret_mc = .margin(regret),
    secs = mean(tapply(.pick(d, "stage", "secs", NA)$value,
                       .pick(d, "stage", "secs", NA)$replicate, sum)),
    stringsAsFactors = FALSE)
})
per_cell <- do.call(rbind, per_cell)
rownames(per_cell) <- NULL

stage <- .pick(rows, "stage", "secs", NA)
cat("\n== stage seconds per replicate, mean\n")
print(round(tapply(stage$value, list(stage$candidate, stage$cell_id), mean), 1))

cat("\n== where the selection landed\n")
chosen <- .pick(rows, "nested", "selected")
print(table(candidate = chosen$candidate, cell = chosen$cell_id))

cat("\n== per cell\n")
print(per_cell[c("cell_id", "replicates", "true_grain", "select_exact", "select_adequate",
                 "nested_reported", "nested_true", "nested_bias", "single_reported",
                 "optimism_gap", "coverage", "regret", "secs")], digits = 3)

if (!is.na(opt$csv)) {
  utils::write.csv(per_cell, opt$csv, row.names = FALSE)
  cat("\nwritten to", opt$csv, "\n")
}
