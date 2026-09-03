"""What part of the record a fitted model reads, and what an already-reduced feature table is."""

from __future__ import annotations

from dataclasses import replace

import numpy as np

from .learners import Learner
from .registry import METRICS, get_learner
from .representation import WindowMatrix
from .response import Response, align_folds


def feature_matrix(m, units=None, features=None, label: str = "features") -> WindowMatrix:
    """Bring an already-reduced feature table into a ladder as a one-channel representation.

    It carries no time axis, because it has none: the reduction already happened, elsewhere, and
    what reaches the model is a list of numbers per unit. That is the whole point of comparing
    against it.
    """
    m = np.asarray(m, dtype=np.float64)
    n_u, n_f = m.shape
    units = tuple(units) if units is not None else tuple(str(i) for i in range(n_u))
    features = tuple(features) if features is not None else tuple(f"f{j}" for j in range(n_f))
    empty = np.full(n_f, np.datetime64("NaT"), dtype="datetime64[s]")
    return WindowMatrix(values=m.reshape(n_u, n_f, 1), units=units, bins=features,
                        stats=(label,), window=label, year_start="", bin_start=empty,
                        bin_end=empty, bin_n=np.zeros((n_u, n_f), dtype=np.int64),
                        bin_partial=np.zeros(n_f, dtype=bool))


def ensemble_learner(members, weights=None, name: str = "ensemble") -> Learner:
    """Average several learners' predicted probabilities before the threshold is chosen.

    The average is taken before any decision is made, so the set is scored as one model rather than
    as a vote between decisions. Choose the members on an inner validation split or on prior
    grounds, never on the held-out folds.
    """
    members = [get_learner(m) for m in members]
    if len(members) < 2:
        raise ValueError("an ensemble needs at least two members")
    w = np.ones(len(members)) if weights is None else np.asarray(weights, dtype=np.float64)
    if len(w) != len(members) or (w < 0).any() or w.sum() <= 0:
        raise ValueError("`weights` needs one non-negative number per member and cannot be all "
                         "zero")
    w = w / w.sum()

    def fit(x, y, **kwargs):
        return [m.fit(x, y, **{**m.params, **kwargs}) for m in members]

    def predict(model, x):
        return sum(w[k] * np.asarray(members[k].predict(model[k], x), dtype=np.float64)
                   for k in range(len(members)))

    needs = tuple({n for m in members for n in m.needs})
    return Learner(name=name, fit=fit, predict=predict, needs=needs)


def bin_occlusion(ladder, x, y: Response, arm: str, over: str = "bin",
                  substitute: str = "permute", metric: str = "roc_auc",
                  permutations: int = 20, seed: int = 1):
    """Hold one bin of the record back at a time and record the fall in score as its weight.

    Nothing is refitted: the models kept by ``window_ladder(keep_fits=True)`` are the ones read.
    What a held-back bin is replaced by decides what the weight means, so the substitute is part of
    the answer: ``permute`` keeps the observed readings and cuts only the link between a reading
    and its unit, ``fold_mean`` removes all between-unit variation, ``unit_mean`` keeps how warm a
    unit is and removes only that bin's departure from it.
    """
    if not ladder.fits:
        raise ValueError("this ladder kept no fits; refit with window_ladder(..., keep_fits=True)")
    if over not in ("bin", "channel"):
        raise ValueError(f"`over` must be 'bin' or 'channel', got {over!r}")
    if substitute not in ("permute", "fold_mean", "unit_mean"):
        raise ValueError(f"unknown substitute {substitute!r}")

    window, learner = arm.split("|", 1) if "|" in arm else (None, arm)
    label = f"{window}|{learner}"
    m = x if isinstance(x, WindowMatrix) else dict(x)[window]
    y = y.align(m.units).check_presence_absence()
    f = align_folds(ladder.folds, m.units)
    score = metric if callable(metric) else METRICS.get(metric)

    n_parts = m.values.shape[1] if over == "bin" else m.values.shape[2]
    labels = m.bins if over == "bin" else m.stats
    rng = np.random.default_rng(seed)

    weight = np.full((n_parts, len(y.variables)), np.nan)
    counted = np.zeros((n_parts, len(y.variables)))
    for k in np.unique(f):
        fit = ladder.fits.get(f"{label}|{k}")
        if fit is None:
            continue
        test = np.flatnonzero(f == k)
        train = np.flatnonzero(f != k)
        sub = m.take_units(test)
        base = np.asarray([score(y.values[test, j], fit.predict(sub)[:, j])
                           for j in range(len(y.variables))])
        for i in range(n_parts):
            draws = permutations if substitute == "permute" else 1
            acc = np.zeros((draws, len(y.variables)))
            for r in range(draws):
                occluded = _occlude(m, sub, train, i, over, substitute, rng)
                p = fit.predict(occluded)
                acc[r] = [score(y.values[test, j], p[:, j]) for j in range(len(y.variables))]
            fall = base - acc.mean(axis=0)
            ok = np.isfinite(fall)
            weight[i, ok] = np.where(np.isnan(weight[i, ok]), 0, weight[i, ok]) + fall[ok]
            counted[i, ok] += 1

    with np.errstate(invalid="ignore"):
        weight = weight / np.where(counted > 0, counted, np.nan)
    return {"part": list(labels), "variable": list(y.variables), "weight": weight}


def _occlude(m: WindowMatrix, sub: WindowMatrix, train, i, over, substitute, rng) -> WindowMatrix:
    values = sub.values.copy()
    n = values.shape[0]
    if over == "channel":
        if substitute == "permute":
            values[:, :, i] = values[rng.permutation(n), :, i]
        elif substitute == "fold_mean":
            values[:, :, i] = m.values[train, :, i].mean(axis=0)[None, :]
        else:
            values[:, :, i] = values[:, :, i].mean(axis=1)[:, None]
        return replace(sub, values=values)
    for ch in range(values.shape[2]):
        if substitute == "permute":
            values[:, i, ch] = values[rng.permutation(n), i, ch]
        elif substitute == "fold_mean":
            values[:, i, ch] = m.values[train, i, ch].mean()
        else:
            values[:, i, ch] = values[:, :, ch].mean(axis=1)
    return replace(sub, values=values)
