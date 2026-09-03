# Sequence encoders with a joint multi-label head

Three encoders, all fitted the same way and all ending the same way: one
encoder maps a unit's representation to an embedding and a single linear
layer maps that embedding to one output per variable, so every variable
is predicted together from a shared representation. Pooling strength
across variables is what makes the rarer ones learnable at all at these
sample sizes.

## Usage

``` r
mlp_learner(
  hidden = c(512L, 256L),
  dropout = 0.3,
  epochs = 60L,
  batch_size = 64L,
  lr = 0.001,
  weight_decay = 1e-04,
  val_frac = 0.15,
  patience = 10L,
  pos_weight_cap = 50,
  swa = FALSE,
  swa_start = 0.7,
  seed = 1L,
  device = NULL
)

cnn_learner(
  channels = c(16L, 32L, 64L, 128L),
  kernel = 7L,
  dropout = 0.3,
  epochs = 60L,
  batch_size = 32L,
  lr = 0.001,
  weight_decay = 1e-04,
  val_frac = 0.15,
  patience = 10L,
  pos_weight_cap = 50,
  swa = FALSE,
  swa_start = 0.7,
  seed = 1L,
  device = NULL
)

rescnn_learner(
  channels = c(32L, 64L, 128L, 256L),
  blocks_per_stage = 2L,
  kernel = 7L,
  dilations = c(1L, 2L, 4L, 8L),
  dropout = 0.3,
  epochs = 60L,
  batch_size = 32L,
  lr = 0.001,
  weight_decay = 1e-04,
  val_frac = 0.15,
  patience = 10L,
  pos_weight_cap = 50,
  swa = FALSE,
  swa_start = 0.7,
  seed = 1L,
  device = NULL
)
```

## Arguments

- hidden:

  Hidden layer widths, for the fully connected encoder.

- dropout:

  Dropout rate.

- epochs:

  Epoch budget the cosine schedule anneals over.

- batch_size:

  Units per optimiser step.

- lr:

  Learning rate.

- weight_decay:

  AdamW weight decay.

- val_frac:

  Share of the fitting units held back as an inner validation set, used
  for early stopping and for nothing else. It is never scored as a
  result.

- patience:

  Epochs without an inner-validation improvement before training stops.

- pos_weight_cap:

  Ceiling on the per-variable positive-class weight, which is the ratio
  of absences to presences among the fitting units.

- swa:

  Average the weights of the tail epochs instead of restoring the best
  single epoch. The schedule anneals to `swa_start` of the epoch budget
  and is then held flat while the remaining epochs' weights are
  averaged, and the batch-normalisation statistics are recomputed for
  the average. Early stopping is off while an average is being
  accumulated, so the averaging window always runs.

- swa_start:

  Share of the epoch budget after which averaging begins.

- seed:

  Seed for initialisation, batching and the inner validation split.

- device:

  `"cuda"`, `"cpu"`, or `NULL` to take a graphics processor where there
  is one.

- channels:

  Channel width of each stage.

- kernel:

  Convolution kernel width.

- blocks_per_stage:

  Residual blocks in each stage.

- dilations:

  Dilation of each stage, cycled if shorter than `channels`.

## Value

A
[`learner()`](https://gillescolling.com/climgrain/reference/learner.md).

## Details

`mlp_learner()` flattens the channels and builds in no temporal
geometry. It is what separates the effect of the model class from the
effect of the representation: where it matches a penalised regression,
the difference a convolutional encoder makes is the convolution rather
than the network.

`cnn_learner()` is blocks of a one-dimensional convolution, batch
normalisation, a rectified linear activation and max pooling, then
global average pooling. Pooling becomes an identity once a sequence is
shorter than its kernel, so the same stack runs at every grain of a
ladder, including one bin per year.

`rescnn_learner()` adds dilated residual blocks with squeeze-excitation
channel gates, whose stage dilations widen the receptive field toward
the seasonal scale without widening the kernel, and concatenates global
average with global maximum pooling so extremes reach the head beside
the level.

## Examples

``` r
cnn_learner(epochs = 5)
```
