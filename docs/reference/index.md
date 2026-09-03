# Package index

## The representation

Readings in long form to the array a model is fitted on, at one grain or
at every grain of a ladder.

- [`window_matrix()`](https://gillescolling.com/climgrain/reference/window_matrix.md)
  : Reduce sensor series to a temporal grain
- [`climgrain_set()`](https://gillescolling.com/climgrain/reference/climgrain_set.md)
  : A ladder of representations, one per window
- [`calendar_channels()`](https://gillescolling.com/climgrain/reference/calendar_channels.md)
  : Where in the year each bin sits
- [`bind_channels()`](https://gillescolling.com/climgrain/reference/bind_channels.md)
  : Put channels side by side
- [`feature_matrix()`](https://gillescolling.com/climgrain/reference/feature_matrix.md)
  : Bring an already-reduced feature table into a ladder

## The split and the cells

One fold map read by everything that scores, and the cells a score is
defined on, computed with no model involved.

- [`fold_map()`](https://gillescolling.com/climgrain/reference/fold_map.md)
  : Assign units to cross-validation folds
- [`scorable_cells()`](https://gillescolling.com/climgrain/reference/scorable_cells.md)
  : Which cells a score is defined on

## Fitting

- [`window_ladder()`](https://gillescolling.com/climgrain/reference/window_ladder.md)
  [`summary(`*`<climgrain_ladder>`*`)`](https://gillescolling.com/climgrain/reference/window_ladder.md)
  : Fit at every grain and see where skill saturates
- [`fit_learner()`](https://gillescolling.com/climgrain/reference/fit_learner.md)
  [`predict(`*`<climgrain_fit>`*`)`](https://gillescolling.com/climgrain/reference/fit_learner.md)
  : Fit one learner at one grain
- [`select_grain()`](https://gillescolling.com/climgrain/reference/select_grain.md)
  [`summary(`*`<climgrain_selection>`*`)`](https://gillescolling.com/climgrain/reference/select_grain.md)
  : Choose the grain inside the training data, and score the whole
  procedure
- [`plot(`*`<climgrain_ladder>`*`)`](https://gillescolling.com/climgrain/reference/plot.climgrain_ladder.md)
  : Draw a ladder
- [`plot(`*`<climgrain_selection>`*`)`](https://gillescolling.com/climgrain/reference/plot.climgrain_selection.md)
  : Draw how stable the choice of grain was

## Learners

The arms that ship, and the interface a learner of your own goes
through.

- [`elasticnet_learner()`](https://gillescolling.com/climgrain/reference/elasticnet_learner.md)
  : Penalised logistic regression on the flattened representation
- [`stepwise_learner()`](https://gillescolling.com/climgrain/reference/stepwise_learner.md)
  : Forward selection by AIC on the flattened representation
- [`mlp_learner()`](https://gillescolling.com/climgrain/reference/torch_learners.md)
  [`cnn_learner()`](https://gillescolling.com/climgrain/reference/torch_learners.md)
  [`rescnn_learner()`](https://gillescolling.com/climgrain/reference/torch_learners.md)
  : Sequence encoders with a joint multi-label head
- [`ensemble_learner()`](https://gillescolling.com/climgrain/reference/ensemble_learner.md)
  : Average several learners before scoring
- [`learner()`](https://gillescolling.com/climgrain/reference/learner.md)
  : Define a learner
- [`register_learner()`](https://gillescolling.com/climgrain/reference/register_learner.md)
  [`learners()`](https://gillescolling.com/climgrain/reference/register_learner.md)
  : Register a learner

## Scoring and comparison

- [`tss()`](https://gillescolling.com/climgrain/reference/tss.md) : The
  true skill statistic
- [`roc_auc()`](https://gillescolling.com/climgrain/reference/roc_auc.md)
  : The area under the ROC curve
- [`kappa_score()`](https://gillescolling.com/climgrain/reference/kappa_score.md)
  [`decision_threshold()`](https://gillescolling.com/climgrain/reference/kappa_score.md)
  [`model_agreement()`](https://gillescolling.com/climgrain/reference/kappa_score.md)
  : Cohen's kappa, and where two models disagree
- [`paired_contrast()`](https://gillescolling.com/climgrain/reference/paired_contrast.md)
  : Compare two arms cell by cell
- [`window_contrasts()`](https://gillescolling.com/climgrain/reference/window_contrasts.md)
  : Compare every window against a learner's best one
- [`tss_inflation()`](https://gillescolling.com/climgrain/reference/tss_inflation.md)
  : How much a self-selected threshold inflates the reported level
- [`implied_skill()`](https://gillescolling.com/climgrain/reference/implied_skill.md)
  : What population skill a reported level is consistent with
- [`bin_occlusion()`](https://gillescolling.com/climgrain/reference/bin_occlusion.md)
  : What part of the record a fitted model reads

## Extending

The response head and the metric are registrations, never a fork of the
fitting code.

- [`register_response()`](https://gillescolling.com/climgrain/reference/register_response.md)
  [`responses()`](https://gillescolling.com/climgrain/reference/register_response.md)
  : Register a response head
- [`register_metric()`](https://gillescolling.com/climgrain/reference/register_metric.md)
  [`metrics()`](https://gillescolling.com/climgrain/reference/register_metric.md)
  : Register a metric

## What crosses the boundary

The three artifacts a split is carried in, and the digest that says two
arrays are the same array.

- [`write_folds()`](https://gillescolling.com/climgrain/reference/artifacts.md)
  [`read_folds()`](https://gillescolling.com/climgrain/reference/artifacts.md)
  [`write_response()`](https://gillescolling.com/climgrain/reference/artifacts.md)
  [`read_response()`](https://gillescolling.com/climgrain/reference/artifacts.md)
  [`write_cells()`](https://gillescolling.com/climgrain/reference/artifacts.md)
  [`read_cells()`](https://gillescolling.com/climgrain/reference/artifacts.md)
  : Read and write the artifacts that cross the language boundary
- [`digest_array()`](https://gillescolling.com/climgrain/reference/digest_array.md)
  : The cross-language digest of a representation

## A record to test on

- [`simulate_records()`](https://gillescolling.com/climgrain/reference/simulate_records.md)
  : Simulate sensor records whose response acts at a known temporal
  grain

## The package

- [`climgrain`](https://gillescolling.com/climgrain/reference/climgrain-package.md)
  [`climgrain-package`](https://gillescolling.com/climgrain/reference/climgrain-package.md)
  : climgrain: Temporal Climate Resolution for Ecological Prediction
