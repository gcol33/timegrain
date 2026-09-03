# The benchmark's design: the constants every cell shares, the candidate sets, the cell table and
# the identity stamp each replicate is written with. Sourced by run.R and by anything reading the
# results, so a cell is defined in one place and no launcher carries its own copy.

BENCH <- list(
  scale        = "full",
  variables    = 10L,
  prevalence   = 0.10,
  auc          = 0.75,
  days         = 365L,
  step_hours   = 3,
  year_start   = "09-01",
  outer        = 5L,
  metric       = "roc_auc",
  windows      = c("halfday", "day", "week", "month", "season", "year"),
  elasticnet_squares = TRUE,
  elasticnet_n_inner  = 5L,
  cnn_epochs   = 40L,
  n_deploy     = 3000L,
  deploy_chunk = 750L,
  deploy_draw  = 100000L,
  mechanisms   = c("none", "event", "season", "lag"),
  design_seed  = c(none = 101L, event = 102L, season = 103L, lag = 104L),
  true_grain   = c(none = NA_character_, event = "day", season = "season", lag = "week"),
  # The windows whose bins tile the generating window exactly, so the driver is still an exact
  # linear functional of the representation there. A selection landing on one of these has lost
  # nothing to averaging; it has only spent more coefficients than it needed.
  nesting      = list(day = c("halfday", "day"),
                      week = c("halfday", "day", "week"),
                      season = c("halfday", "day", "month", "season"))
)

# A candidate is a (window, summary) pair. The penalised block searches both summaries, the neural
# block the window mean alone, which is what the sizing in the plan assumes.
bench_candidates <- function(block) {
  summaries <- if (block == "elasticnet") list(mean = "mean", mmm = c("min", "mean", "max"))
               else list(mean = "mean")
  out <- expand.grid(stat = names(summaries), window = BENCH$windows,
                     KEEP.OUT.ATTRS = FALSE, stringsAsFactors = FALSE)
  out <- out[order(match(out$window, BENCH$windows), out$stat), c("window", "stat")]
  out$candidate <- paste(out$window, out$stat, sep = ".")
  out$channels <- I(unname(summaries[out$stat]))
  rownames(out) <- NULL
  out
}

bench_cells <- function() {
  smoke <- identical(BENCH$scale, "smoke")
  sizes <- if (smoke) c(120L, 200L) else c(300L, 900L)
  elasticnet_cells <- expand.grid(mechanism = BENCH$mechanisms, n_unit = sizes,
                              KEEP.OUT.ATTRS = FALSE, stringsAsFactors = FALSE)
  elasticnet_cells$block <- "elasticnet"
  elasticnet_cells$inner <- if (smoke) 2L else 5L
  elasticnet_cells$replicates <- if (smoke) 3L else 200L
  cnn_cells <- data.frame(mechanism = BENCH$mechanisms, n_unit = max(sizes), block = "cnn",
                          inner = if (smoke) 2L else 3L,
                          replicates = if (smoke) 2L else 100L, stringsAsFactors = FALSE)
  out <- rbind(elasticnet_cells, cnn_cells)
  out$cell_id <- sprintf("%s%s-%s-n%d", if (smoke) "smoke-" else "", out$block, out$mechanism,
                         out$n_unit)
  out[c("cell_id", "block", "mechanism", "n_unit", "inner", "replicates")]
}

# The smoke scale is a different scale, not a smaller run of the same one: it shrinks the design and
# it renames every cell, so its rows land in their own directory and cannot be read as the design
# the paper reports.
bench_scale <- function(scale) {
  if (identical(scale, "full")) {
    return(invisible("full"))
  }
  if (!identical(scale, "smoke")) {
    stop("--scale is \"full\" or \"smoke\", got \"", scale, "\".", call. = FALSE)
  }
  BENCH$scale <<- "smoke"
  BENCH$variables <<- 4L
  BENCH$n_deploy <<- 600L
  BENCH$deploy_chunk <<- 600L
  BENCH$outer <<- 3L
  BENCH$cnn_epochs <<- 4L
  invisible("smoke")
}

bench_learner <- function(block) {
  switch(block,
         elasticnet = timegrain::elasticnet_learner(squares = BENCH$elasticnet_squares,
                                            n_inner = BENCH$elasticnet_n_inner),
         cnn = timegrain::cnn_learner(epochs = BENCH$cnn_epochs,
                                      device = Sys.getenv("TIMEGRAIN_DEVICE", unset = "cpu")),
         stop("unknown block: ", block))
}

# Two calls to window_matrix() cover every candidate, one per summary, because naming several
# windows already returns one representation each. The set is renamed to the candidate labels so
# select_grain() reports the pair rather than only the window.
bench_representation <- function(readings, candidates) {
  wanted <- unique(candidates$stat)
  parts <- lapply(wanted, function(s) {
    channels <- candidates$channels[[match(s, candidates$stat)]]
    m <- timegrain::window_matrix(readings, "unit", "time", "reading",
                                  window = BENCH$windows, stats = channels,
                                  year_start = BENCH$year_start)
    stats::setNames(unclass(m), paste(names(m), s, sep = "."))
  })
  set <- do.call(c, parts)
  timegrain::timegrain_set(set[candidates$candidate])
}

# Every run says what it was fed before it is fed it: the cell, the seeds, the package it is
# exercising and the candidate set it will search. A row without this cannot be traced to a cell
# and is not a row.
bench_stamp <- function(cell, replicate, candidates, pkg_dir, learner) {
  commit <- tryCatch(
    system2("git", c("-C", shQuote(pkg_dir), "rev-parse", "HEAD"), stdout = TRUE, stderr = NULL),
    error = function(e) NA_character_)
  dirty <- tryCatch(
    length(system2("git", c("-C", shQuote(pkg_dir), "status", "--porcelain"), stdout = TRUE,
                   stderr = NULL)) > 0L,
    error = function(e) NA)
  list(
    scale = BENCH$scale,
    cell_id = cell$cell_id,
    block = cell$block,
    mechanism = cell$mechanism,
    n_unit = cell$n_unit,
    inner = cell$inner,
    outer = BENCH$outer,
    replicate = replicate,
    design_seed = unname(BENCH$design_seed[cell$mechanism]),
    draw = replicate,
    deploy_draw = BENCH$deploy_draw + replicate,
    true_grain = unname(BENCH$true_grain[cell$mechanism]),
    metric = BENCH$metric,
    n_candidate = nrow(candidates),
    candidates = paste(candidates$candidate, collapse = ","),
    candidate_digest = .bench_digest(paste(candidates$candidate, collapse = ",")),
    learner = learner$name,
    learner_digest = .bench_digest(paste(utils::capture.output(utils::str(learner$params)),
                                         collapse = "|")),
    pkg_version = as.character(utils::packageVersion("timegrain")),
    pkg_commit = if (length(commit) == 1L) commit else NA_character_,
    pkg_dirty = isTRUE(dirty),
    r_version = paste(R.version$major, R.version$minor, sep = "."),
    platform = R.version$platform,
    device = Sys.getenv("TIMEGRAIN_DEVICE", unset = "cpu")
  )
}

# The candidate set actually searched is read back off the selection and checked against the one
# the stamp declares. A run that searched a different set than it recorded is stopped, not saved.
bench_assert_candidates <- function(selection, stamp) {
  searched <- paste(sort(unique(selection$candidates$window)), collapse = ",")
  declared <- paste(sort(strsplit(stamp$candidates, ",", fixed = TRUE)[[1L]]), collapse = ",")
  if (!identical(searched, declared)) {
    stop("cell ", stamp$cell_id, " replicate ", stamp$replicate, " searched {", searched,
         "} but declares {", declared, "}.", call. = FALSE)
  }
  invisible(TRUE)
}

.bench_digest <- function(text) {
  f <- tempfile()
  on.exit(unlink(f), add = TRUE)
  con <- file(f, open = "wb")
  writeBin(charToRaw(text), con)
  close(con)
  substr(unname(tools::md5sum(f)), 1L, 12L)
}
