#' Sequence encoders with a joint multi-label head
#'
#' Three encoders, all fitted the same way and all ending the same way: one encoder maps a unit's
#' representation to an embedding and a single linear layer maps that embedding to one output per
#' variable, so every variable is predicted together from a shared representation. Pooling strength
#' across variables is what makes the rarer ones learnable at all at these sample sizes.
#'
#' `mlp_learner()` flattens the channels and builds in no temporal geometry. It is what separates
#' the effect of the model class from the effect of the representation: where it matches a
#' penalised regression, the difference a convolutional encoder makes is the convolution rather
#' than the network.
#'
#' `cnn_learner()` is blocks of a one-dimensional convolution, batch normalisation, a rectified
#' linear activation and max pooling, then global average pooling. Pooling becomes an identity once
#' a sequence is shorter than its kernel, so the same stack runs at every grain of a ladder,
#' including one bin per year.
#'
#' `rescnn_learner()` adds dilated residual blocks with squeeze-excitation channel gates, whose
#' stage dilations widen the receptive field toward the seasonal scale without widening the kernel,
#' and concatenates global average with global maximum pooling so extremes reach the head beside
#' the level.
#'
#' @param channels Channel width of each stage.
#' @param hidden Hidden layer widths, for the fully connected encoder.
#' @param kernel Convolution kernel width.
#' @param dilations Dilation of each stage, cycled if shorter than `channels`.
#' @param blocks_per_stage Residual blocks in each stage.
#' @param dropout Dropout rate.
#' @param epochs Epoch budget the cosine schedule anneals over.
#' @param batch_size Units per optimiser step.
#' @param lr Learning rate.
#' @param weight_decay AdamW weight decay.
#' @param val_frac Share of the fitting units held back as an inner validation set, used for early
#'   stopping and for nothing else. It is never scored as a result.
#' @param patience Epochs without an inner-validation improvement before training stops.
#' @param pos_weight_cap Ceiling on the per-variable positive-class weight, which is the ratio of
#'   absences to presences among the fitting units.
#' @param swa Average the weights of the tail epochs instead of restoring the best single epoch.
#'   The schedule anneals to `swa_start` of the epoch budget and is then held flat while the
#'   remaining epochs' weights are averaged, and the batch-normalisation statistics are recomputed
#'   for the average. Early stopping is off while an average is being accumulated, so the
#'   averaging window always runs.
#' @param swa_start Share of the epoch budget after which averaging begins.
#' @param seed Seed for initialisation, batching and the inner validation split.
#' @param device `"cuda"`, `"cpu"`, or `NULL` to take a graphics processor where there is one.
#'
#' @return A [learner()].
#'
#' @examples
#' cnn_learner(epochs = 5)
#'
#' @name torch_learners
NULL

#' @rdname torch_learners
#' @export
mlp_learner <- function(hidden = c(512L, 256L), dropout = 0.3, epochs = 60L, batch_size = 64L,
                        lr = 1e-3, weight_decay = 1e-4, val_frac = 0.15, patience = 10L,
                        pos_weight_cap = 50, swa = FALSE, swa_start = 0.7, seed = 1L,
                        device = NULL) {
  .torch_learner("mlp", .mlp_module,
                 list(hidden = as.integer(hidden), dropout = dropout),
                 .fit_settings(epochs, batch_size, lr, weight_decay, val_frac, patience,
                               pos_weight_cap, swa, swa_start, seed, device))
}

#' @rdname torch_learners
#' @export
cnn_learner <- function(channels = c(16L, 32L, 64L, 128L), kernel = 7L, dropout = 0.3,
                        epochs = 60L, batch_size = 32L, lr = 1e-3, weight_decay = 1e-4,
                        val_frac = 0.15, patience = 10L, pos_weight_cap = 50, swa = FALSE,
                        swa_start = 0.7, seed = 1L, device = NULL) {
  .torch_learner("cnn", .cnn_module,
                 list(channels = as.integer(channels), kernel = as.integer(kernel),
                      dropout = dropout),
                 .fit_settings(epochs, batch_size, lr, weight_decay, val_frac, patience,
                               pos_weight_cap, swa, swa_start, seed, device))
}

#' @rdname torch_learners
#' @export
rescnn_learner <- function(channels = c(32L, 64L, 128L, 256L), blocks_per_stage = 2L, kernel = 7L,
                           dilations = c(1L, 2L, 4L, 8L), dropout = 0.3, epochs = 60L,
                           batch_size = 32L, lr = 1e-3, weight_decay = 1e-4, val_frac = 0.15,
                           patience = 10L, pos_weight_cap = 50, swa = FALSE, swa_start = 0.7,
                           seed = 1L, device = NULL) {
  .torch_learner("rescnn", .rescnn_module,
                 list(channels = as.integer(channels),
                      blocks_per_stage = as.integer(blocks_per_stage),
                      kernel = as.integer(kernel), dilations = as.integer(dilations),
                      dropout = dropout),
                 .fit_settings(epochs, batch_size, lr, weight_decay, val_frac, patience,
                               pos_weight_cap, swa, swa_start, seed, device))
}

.fit_settings <- function(epochs, batch_size, lr, weight_decay, val_frac, patience,
                          pos_weight_cap, swa, swa_start, seed, device) {
  list(epochs = as.integer(epochs), batch_size = as.integer(batch_size), lr = lr,
       weight_decay = weight_decay, val_frac = val_frac, patience = as.integer(patience),
       pos_weight_cap = pos_weight_cap, swa = isTRUE(swa), swa_start = swa_start,
       seed = as.integer(seed), device = device)
}

# One learner factory for every encoder: the architecture is a module constructor and nothing else,
# so the training recipe, the standardiser, the class weighting and the early stopping have one
# definition and cannot drift between architectures.
.torch_learner <- function(name, module_fn, arch, fit_args) {
  learner(
    name = name,
    needs = "torch",
    params = c(arch, fit_args),
    fit = function(x, y, ...) {
      given <- list(...)
      unknown <- setdiff(names(given), c(names(arch), names(fit_args)))
      if (length(unknown)) {
        stop("the ", name, " learner has no setting called ",
             paste(sort(unknown, method = "radix"), collapse = ", "), ".", call. = FALSE)
      }
      .torch_fit(x, y, module_fn,
                 utils::modifyList(arch, given[intersect(names(given), names(arch))]),
                 utils::modifyList(fit_args, given[intersect(names(given), names(fit_args))]))
    },
    predict = function(model, x) .torch_predict(model, x)
  )
}

# ---- the training recipe -------------------------------------------------------------------

.torch_fit <- function(x, y, module_fn, arch, cfg) {
  torch <- .torch()
  device <- .torch_device(cfg$device)

  m <- .to_nchw(x)
  scaler <- .scaler(matrix(as.numeric(m), nrow = dim(m)[1L]), per_column = FALSE)
  m <- (m - scaler$centre[1L]) / scaler$scale[1L]

  n <- dim(m)[1L]
  old <- .seed_state()
  on.exit(.restore_seed(old), add = TRUE)
  set.seed(cfg$seed)
  torch$torch_manual_seed(cfg$seed)

  n_val <- max(1L, round(cfg$val_frac * n))
  val <- if (cfg$val_frac > 0 && n - n_val >= 2L) sample.int(n, n_val) else integer(0)
  fit_idx <- setdiff(seq_len(n), val)

  xt <- torch$torch_tensor(m, dtype = torch$torch_float())$to(device = device)
  yt <- torch$torch_tensor(y, dtype = torch$torch_float())$to(device = device)

  pos <- colSums(y[fit_idx, , drop = FALSE])
  neg <- length(fit_idx) - pos
  w <- pmin(pmax(ifelse(pos > 0, neg / pmax(pos, 1), 1), 1), cfg$pos_weight_cap)
  pw <- torch$torch_tensor(w, dtype = torch$torch_float())$to(device = device)

  net <- module_fn(in_ch = dim(m)[2L], in_len = dim(m)[3L], n_out = ncol(y), arch = arch)
  net$to(device = device)
  opt <- torch$optim_adamw(net$parameters, lr = cfg$lr, weight_decay = cfg$weight_decay)
  sched <- torch$lr_cosine_annealing(opt, T_max = cfg$epochs)

  best <- list(loss = Inf, state = NULL)
  bad <- 0L
  swa_from <- if (cfg$swa) max(1L, as.integer(cfg$swa_start * cfg$epochs)) else cfg$epochs + 1L
  average <- list(state = NULL, n = 0L)
  for (epoch in seq_len(cfg$epochs)) {
    net$train()
    for (b in .batches(fit_idx, cfg$batch_size, shuffle = TRUE)) {
      idx <- .index(torch, b, device)
      opt$zero_grad()
      loss <- torch$nnf_binary_cross_entropy_with_logits(
        net(xt[idx, , ]), yt[idx, ], pos_weight = pw)
      loss$backward()
      opt$step()
    }
    if (epoch < swa_from) {
      sched$step()
    } else {
      average <- .accumulate(net, average)
      next
    }
    if (!length(val)) {
      next
    }
    vloss <- .torch_loss(torch, net, xt, yt, val, pw, cfg$batch_size, device)
    if (vloss < best$loss - 1e-4) {
      best <- list(loss = vloss, state = lapply(net$state_dict(), function(p) p$detach()$cpu()))
      bad <- 0L
    } else {
      bad <- bad + 1L
      if (bad >= cfg$patience) {
        break
      }
    }
  }
  if (average$n > 0L) {
    net$load_state_dict(average$state)
    net$to(device = device)
    .refresh_batchnorm(torch, net, xt, fit_idx, cfg$batch_size, device)
  } else if (!is.null(best$state)) {
    net$load_state_dict(best$state)
    net$to(device = device)
  }
  net$eval()
  structure(list(net = net, scaler = scaler, device = device, channels = dimnames(x)[[3L]],
                 bins = dim(x)[2L], batch_size = cfg$batch_size),
            class = "climgrain_torch")
}

.torch_predict <- function(model, x) {
  torch <- .torch()
  if (!identical(dimnames(x)[[3L]], model$channels) || dim(x)[2L] != model$bins) {
    stop("the representation predicted on has different channels or bins from the fitted one.",
         call. = FALSE)
  }
  m <- (.to_nchw(x) - model$scaler$centre[1L]) / model$scaler$scale[1L]
  xt <- torch$torch_tensor(m, dtype = torch$torch_float())$to(device = model$device)
  out <- vector("list", 0L)
  torch$with_no_grad({
    for (b in .batches(seq_len(dim(m)[1L]), model$batch_size, shuffle = FALSE)) {
      idx <- .index(torch, b, model$device)
      out[[length(out) + 1L]] <- as.matrix(
        torch$torch_sigmoid(model$net(xt[idx, , ]))$to(device = "cpu"))
    }
  })
  do.call(rbind, out)
}

.torch_loss <- function(torch, net, xt, yt, idx_all, pw, batch_size, device) {
  net$eval()
  total <- 0
  torch$with_no_grad({
    for (b in .batches(idx_all, batch_size, shuffle = FALSE)) {
      idx <- .index(torch, b, device)
      total <- total + as.numeric(torch$nnf_binary_cross_entropy_with_logits(
        net(xt[idx, , ]), yt[idx, ], pos_weight = pw)$to(device = "cpu")) * length(b)
    }
  })
  total / length(idx_all)
}

# A running mean of the weights over the tail epochs. Averaging flattens the minimum the optimiser
# settled in, which is a lever on generalisation orthogonal to the architecture and to averaging
# several fitted models at prediction time.
.accumulate <- function(net, average) {
  state <- lapply(net$state_dict(), function(p) p$detach()$cpu())
  if (average$n == 0L) {
    return(list(state = state, n = 1L))
  }
  n <- average$n + 1L
  for (k in names(state)) {
    # Only the floating-point entries are weights. A batch-normalisation module also carries an
    # integer count of the batches it has seen, and a running mean of that is not a number.
    if (state[[k]]$dtype == .torch()$torch_float()) {
      average$state[[k]] <- average$state[[k]] + (state[[k]] - average$state[[k]]) / n
    } else {
      average$state[[k]] <- state[[k]]
    }
  }
  list(state = average$state, n = n)
}

# Batch normalisation carries running statistics that belong to the weights that produced them, so
# an average of weights needs its own pass over the fitting units before it predicts anything.
.refresh_batchnorm <- function(torch, net, xt, fit_idx, batch_size, device) {
  net$train()
  torch$with_no_grad({
    for (b in .batches(fit_idx, batch_size, shuffle = FALSE)) {
      net(xt[.index(torch, b, device), , ])
    }
  })
  invisible(net)
}

.batches <- function(idx, size, shuffle) {
  if (shuffle) {
    idx <- sample(idx)
  }
  split(idx, ceiling(seq_along(idx) / size))
}

.index <- function(torch, b, device) {
  torch$torch_tensor(as.integer(b), dtype = torch$torch_long())$to(device = device)
}

# torch wants (unit, channel, bin); the representation is (unit, bin, channel).
.to_nchw <- function(x) {
  aperm(array(as.numeric(x), dim = dim(x)), c(1L, 3L, 2L))
}

.torch <- function() {
  if (!requireNamespace("torch", quietly = TRUE)) {
    stop("this learner needs torch. Install it with install.packages(\"torch\").", call. = FALSE)
  }
  asNamespace("torch")
}

.torch_device <- function(device) {
  torch <- .torch()
  if (!is.null(device)) {
    return(device)
  }
  if (torch$cuda_is_available()) "cuda" else "cpu"
}

# ---- the encoders --------------------------------------------------------------------------

# Length-safe pooling. A stack of halving pools assumes the sequence is at least as long as the
# number of stages doubled; handed a single step it would halve it to none. This pools while there
# is something to halve and is the identity once there is not, so the coarse end of a ladder runs
# through the same stack as the fine end rather than through a second architecture.
.pool_module <- function() {
  torch <- .torch()
  torch$nn_module(
    "climgrain_lensafe_pool",
    initialize = function(kernel = 2L) {
      self$kernel <- kernel
      self$pool <- torch$nn_max_pool1d(kernel)
    },
    forward = function(x) {
      if (x$shape[3L] < self$kernel) x else self$pool(x)
    }
  )
}

.head_module <- function(torch, embed_dim, n_out, dropout) {
  torch$nn_sequential(torch$nn_dropout(dropout), torch$nn_linear(embed_dim, n_out))
}

.mlp_module <- function(in_ch, in_len, n_out, arch) {
  torch <- .torch()
  torch$nn_module(
    "climgrain_mlp",
    initialize = function() {
      layers <- list(torch$nn_flatten())
      prev <- in_ch * in_len
      for (k in seq_along(arch$hidden)) {
        layers <- c(layers, list(torch$nn_linear(prev, arch$hidden[k]), torch$nn_relu()))
        if (k < length(arch$hidden)) {
          layers <- c(layers, list(torch$nn_dropout(arch$dropout)))
        }
        prev <- arch$hidden[k]
      }
      self$body <- do.call(torch$nn_sequential, layers)
      self$head <- .head_module(torch, prev, n_out, arch$dropout)
    },
    forward = function(x) self$head(self$body(x))
  )()
}

.cnn_module <- function(in_ch, in_len, n_out, arch) {
  torch <- .torch()
  pool <- .pool_module()
  torch$nn_module(
    "climgrain_cnn",
    initialize = function() {
      layers <- list()
      prev <- in_ch
      for (c in arch$channels) {
        layers <- c(layers, list(
          torch$nn_conv1d(prev, c, arch$kernel, padding = arch$kernel %/% 2L),
          torch$nn_batch_norm1d(c), torch$nn_relu(), pool()))
        prev <- c
      }
      self$features <- do.call(torch$nn_sequential, layers)
      self$pool <- torch$nn_sequential(torch$nn_adaptive_avg_pool1d(1L), torch$nn_flatten())
      self$head <- .head_module(torch, prev, n_out, arch$dropout)
    },
    forward = function(x) self$head(self$pool(self$features(x)))
  )()
}

.rescnn_module <- function(in_ch, in_len, n_out, arch) {
  torch <- .torch()
  pool <- .pool_module()

  se <- torch$nn_module(
    "climgrain_se",
    initialize = function(c, r = 8L) {
      h <- max(c %/% r, 4L)
      self$fc <- torch$nn_sequential(torch$nn_linear(c, h), torch$nn_gelu(),
                                     torch$nn_linear(h, c), torch$nn_sigmoid())
    },
    forward = function(x) x * self$fc(x$mean(dim = 3L))$unsqueeze(3L)
  )

  block <- torch$nn_module(
    "climgrain_resblock",
    initialize = function(c, kernel, dilation, dropout) {
      pad <- (kernel %/% 2L) * dilation
      self$conv <- torch$nn_sequential(
        torch$nn_conv1d(c, c, kernel, padding = pad, dilation = dilation),
        torch$nn_batch_norm1d(c), torch$nn_gelu(), torch$nn_dropout(dropout),
        torch$nn_conv1d(c, c, kernel, padding = pad, dilation = dilation),
        torch$nn_batch_norm1d(c))
      self$se <- se(c)
    },
    forward = function(x) torch$nnf_gelu(x + self$se(self$conv(x)))
  )

  torch$nn_module(
    "climgrain_rescnn",
    initialize = function() {
      self$stem <- torch$nn_sequential(
        torch$nn_conv1d(in_ch, arch$channels[1L], arch$kernel, padding = arch$kernel %/% 2L),
        torch$nn_batch_norm1d(arch$channels[1L]), torch$nn_gelu())
      layers <- list()
      prev <- arch$channels[1L]
      for (si in seq_along(arch$channels)) {
        c <- arch$channels[si]
        if (c != prev) {
          layers <- c(layers, list(torch$nn_conv1d(prev, c, 1L),
                                   torch$nn_batch_norm1d(c), torch$nn_gelu()))
        }
        d <- arch$dilations[((si - 1L) %% length(arch$dilations)) + 1L]
        for (b in seq_len(arch$blocks_per_stage)) {
          layers <- c(layers, list(block(c, arch$kernel, d, arch$dropout)))
        }
        layers <- c(layers, list(pool()))
        prev <- c
      }
      self$features <- do.call(torch$nn_sequential, layers)
      self$head <- .head_module(torch, prev * 2L, n_out, arch$dropout)
    },
    forward = function(x) {
      h <- self$features(self$stem(x))
      self$head(torch$torch_cat(list(h$mean(dim = 3L), h$amax(dim = 3L)), dim = 2L))
    }
  )()
}
