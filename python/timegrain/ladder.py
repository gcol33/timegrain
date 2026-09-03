"""Fit at every grain, see where skill saturates, and compare two arms cell by cell."""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np

from ._stats import norm_ppf, wilcoxon_p
from .learners import fit_learner
from .metrics import tss
from .registry import METRICS, RESPONSES, get_learner
from .representation import timegrain_set
from .response import (Folds, Response, align_folds, as_response, fold_map,
                       scorable_cells)


@dataclass
class Ladder:
    """One score per ``(window, learner, variable, fold)`` cell, and what produced it."""

    window: np.ndarray
    learner: np.ndarray
    variable: np.ndarray
    fold: np.ndarray
    score: np.ndarray
    scorable: np.ndarray
    predictions: dict
    cells: object
    folds: Folds
    metric: str
    fits: dict

    def arm(self, name: str):
        window, learner = _split_arm(self, name)
        return (self.window == window) & (self.learner == learner)

    def summary(self):
        """The across-variable mean of the per-variable score, one row per arm."""
        rows = []
        for w in _ordered(self.window):
            for ln in _ordered(self.learner):
                hit = (self.window == w) & (self.learner == ln) & ~np.isnan(self.score)
                if not hit.any():
                    continue
                per_variable = [self.score[hit & (self.variable == v)].mean()
                                for v in np.unique(self.variable[hit])]
                rows.append(dict(learner=ln, window=w, score=float(np.mean(per_variable)),
                                 n_variable=len(per_variable)))
        for ln in {r["learner"] for r in rows}:
            same = [r for r in rows if r["learner"] == ln]
            best = max(same, key=lambda r: r["score"])
            for r in same:
                r["best"] = r is best
        return rows

    def __repr__(self) -> str:  # pragma: no cover - display only
        lines = [f"<timegrain ladder> {len(set(self.window))} windows x "
                 f"{len(set(self.learner))} learners",
                 f"metric: {self.metric} on {int(self.scorable.sum())} scorable cells"]
        for r in self.summary():
            lines.append(f"  {r['learner']:<10} {r['window']:<10} {r['score']:.4f}"
                         f"{'  <- best' if r['best'] else ''}")
        return "\n".join(lines)


def window_ladder(x, y, learners, folds=None, response: str = "presence_absence", metric=None,
                  keep_fits: bool = False, verbose: bool = True) -> Ladder:
    """Cross-validate every learner at every window, on one fold map and one mask of cells.

    Every arm sees identical splits and is restricted to identical cells, so the arms' means share
    a denominator and any two of them can be compared with ``paired_contrast``.

    ``folds`` left at ``None`` builds one with the defaults of ``fold_map``. Where both languages
    must see the same splits, build it once and read it in the other with ``read_folds``.
    """
    windows = timegrain_set(x)
    units = windows.units
    spec = RESPONSES.get(response)
    y = spec["prepare"](as_response(y)).align(units)
    if folds is None:
        folds = fold_map(y)
    f = align_folds(folds, units)
    cells = spec["cells"](y, Folds(fold=f, units=units))
    score = metric if callable(metric) else METRICS.get(metric or spec["metric"])
    learners = learner_dict(learners)
    levels = np.unique(f)

    window, learner, variable, fold, value, ok = [], [], [], [], [], []
    predictions, fits = {}, {}
    for w, m in windows.items():
        for name, ln in learners.items():
            arm = f"{w}|{name}"
            if verbose:
                print(f"fitting {name} at the {w} window")
            p = np.full(y.values.shape, np.nan)
            column = {v: j for j, v in enumerate(y.variables)}
            row = {u: i for i, u in enumerate(units)}
            for k in levels:
                train = np.flatnonzero(f != k)
                held = m.take_units(np.flatnonzero(f == k))
                fit = fit_learner(ln, m.take_units(train), y.take_units(train),
                                  response=response)
                predicted = fit.predict(held)
                # Keyed on both axes rather than positional: a learner returning its variables in
                # another order would otherwise scramble which prediction belongs to which one,
                # silently.
                for a, u in enumerate(held.units):
                    for b, v in enumerate(fit.variables):
                        p[row[u], column[v]] = predicted[a, b]
                if keep_fits:
                    fits[f"{arm}|{k}"] = fit
            predictions[arm] = p
            scored = score_arm(w, name, y, p, f, levels, cells, score)
            for key, into in (("window", window), ("learner", learner), ("variable", variable),
                              ("fold", fold), ("score", value), ("scorable", ok)):
                into.extend(scored[key])

    return ladder_from_rows(dict(window=window, learner=learner, variable=variable, fold=fold,
                                 score=value, scorable=ok),
                            predictions=predictions, cells=cells,
                            folds=Folds(fold=f, units=units), metric=metric or spec["metric"],
                            fits=fits)


def score_arm(window, learner, y: Response, p: np.ndarray, f: np.ndarray, levels,
              cells, score) -> dict:
    """One arm's cells: which of them a score is defined on, and the score of each.

    A ladder and a selection both read a level off this, so the two report the same quantity
    computed the same way rather than each computing it.
    """
    rows = dict(window=[], learner=[], variable=[], fold=[], score=[], scorable=[])
    for k in levels:
        take = f == k
        for j, v in enumerate(y.variables):
            ok = cells.is_scorable(v, int(k))
            rows["window"].append(window)
            rows["learner"].append(learner)
            rows["variable"].append(v)
            rows["fold"].append(int(k))
            rows["scorable"].append(ok)
            rows["score"].append(score(y.values[take, j], p[take, j]) if ok else np.nan)
    return rows


def ladder_from_rows(rows: dict, predictions: dict, cells, folds: Folds, metric: str,
                     fits: dict) -> Ladder:
    return Ladder(window=np.asarray(rows["window"]), learner=np.asarray(rows["learner"]),
                  variable=np.asarray(rows["variable"]), fold=np.asarray(rows["fold"]),
                  score=np.asarray(rows["score"], dtype=float),
                  scorable=np.asarray(rows["scorable"]), predictions=predictions, cells=cells,
                  folds=folds, metric=metric, fits=fits)


def concat_ladders(a: Ladder, b: Ladder) -> Ladder:
    """Two arms' cells in one table, which is what a contrast between them reads."""
    if a.metric != b.metric:
        raise ValueError(f"one table is scored by {a.metric} and the other by {b.metric}")
    return Ladder(
        window=np.concatenate([a.window, b.window]),
        learner=np.concatenate([a.learner, b.learner]),
        variable=np.concatenate([a.variable, b.variable]),
        fold=np.concatenate([a.fold, b.fold]),
        score=np.concatenate([a.score, b.score]),
        scorable=np.concatenate([a.scorable, b.scorable]),
        predictions={**a.predictions, **b.predictions}, cells=a.cells, folds=a.folds,
        metric=a.metric, fits={})


def per_variable(ladder: Ladder) -> dict:
    """The mean score of each arm's variables over the folds it was scorable in.

    A variable is the independent replicate, so a cell mean is taken within a variable before
    anything is averaged across variables. Averaging cells directly would weight a variable by how
    many folds it happened to be scorable in.
    """
    keep = ~np.isnan(ladder.score)
    out = {}
    for w, ln, v, value in zip(ladder.window[keep], ladder.learner[keep], ladder.variable[keep],
                               ladder.score[keep]):
        out.setdefault((str(w), str(ln), str(v)), []).append(float(value))
    return {k: float(np.mean(v)) for k, v in out.items()}


def mean_se(values) -> tuple[float, float]:
    """A level and the spread of the variables it was averaged over, in one place, so a ladder and
    a selection report the same quantity computed the same way."""
    v = np.asarray([x for x in np.asarray(values, dtype=float) if not np.isnan(x)])
    if not len(v):
        return float("nan"), float("nan")
    se = float(v.std(ddof=1) / np.sqrt(len(v))) if len(v) > 1 else float("nan")
    return float(v.mean()), se


def paired_contrast(ladder: Ladder, a: str, b: str) -> dict:
    """The difference between two arms, taken inside each cell both scored.

    Two arms scored on the same held-out units do not necessarily have the same set of defined
    cells, so a difference of two marginal means is not a difference between the arms. Pairing also
    cancels what a threshold-selected metric carries in its level, since both arms carry the same
    bias on the same cell.
    """
    hit_a, hit_b = ladder.arm(a), ladder.arm(b)
    key = np.char.add(np.char.add(ladder.variable.astype(str), "|"), ladder.fold.astype(str))
    defined_a = hit_a & ~np.isnan(ladder.score)
    defined_b = hit_b & ~np.isnan(ladder.score)
    shared = np.intersect1d(key[defined_a], key[defined_b])
    if not len(shared):
        raise ValueError("the two arms share no cell both scored")

    ix_a = {k: i for i, k in zip(np.flatnonzero(defined_a), key[defined_a])}
    ix_b = {k: i for i, k in zip(np.flatnonzero(defined_b), key[defined_b])}
    diff = np.asarray([ladder.score[ix_a[k]] - ladder.score[ix_b[k]] for k in shared])
    variable = np.asarray([k.split("|")[0] for k in shared])

    by_variable = np.asarray([diff[variable == v].mean() for v in np.unique(variable)])
    n = len(by_variable)
    d, se = mean_se(by_variable)
    return dict(a=_label(ladder, a), b=_label(ladder, b), diff=d, lower=d - 1.96 * se,
                upper=d + 1.96 * se, n_variable=n, n_cell=len(shared),
                n_favour=int((by_variable > 0).sum()), p_value=_wilcoxon(by_variable))


def tss_inflation(y: Response, folds, skill=(0.6, 0.7, 0.9), replicates: int = 200,
                  seed: int = 1) -> list[dict]:
    """How much a threshold chosen on the scored units inflates the level it reports.

    Predictions are simulated under a normal model whose population skill is exactly the value
    planted, at the cell sizes and presence counts of this design, and read back the way a ladder
    reports a level. The gap is the inflation. It cancels in a paired difference and does not
    cancel in a level, so a level is an upper bound on the skill a population has.
    """
    cells = scorable_cells(y, folds)
    keep = cells.scorable
    if not keep.any():
        raise ValueError("no cell of this design is scorable, so there is no level to measure")

    rng = np.random.default_rng(seed)
    out = []
    for target in skill:
        delta = 2 * norm_ppf((target + 1) / 2)
        per_replicate = np.empty(replicates)
        for r in range(replicates):
            by_variable = []
            for v in np.unique(cells.variable[keep]):
                rows = keep & (cells.variable == v)
                by_variable.append(np.mean([
                    tss(np.r_[np.ones(n_pos), np.zeros(n_neg)],
                        np.r_[rng.normal(delta, 1, n_pos), rng.normal(0, 1, n_neg)])
                    for n_pos, n_neg in zip(cells.pres_test[rows], cells.abs_test[rows])]))
            per_replicate[r] = float(np.mean(by_variable))
        out.append(dict(skill=target, reported=float(per_replicate.mean()),
                        inflation=float(per_replicate.mean()) - target,
                        lower=float(np.quantile(per_replicate, 0.025)),
                        upper=float(np.quantile(per_replicate, 0.975)),
                        replicates=replicates))
    return out


def implied_skill(y: Response, folds, observed, grid=None, replicates: int = 200,
                  seed: int = 1) -> list[dict]:
    """What population skill a level actually read is consistent with.

    ``tss_inflation`` maps a population skill to the level a design reports for it; this inverts
    that map. It is the only honest way to read a level as a statement about a population rather
    than about a scoring rule, and it says nothing about a difference between two arms, where the
    inflation cancels and the reported number stands as it is.
    """
    grid = np.arange(0, 0.96, 0.05) if grid is None else np.asarray(grid, dtype=float)
    forward = tss_inflation(y, folds, skill=grid, replicates=replicates, seed=seed)
    reported = np.asarray([r["reported"] for r in forward])
    skill = np.asarray([r["skill"] for r in forward])
    order = np.argsort(reported)
    reported, skill = reported[order], skill[order]
    observed = np.atleast_1d(np.asarray(observed, dtype=float))
    return [dict(observed=float(o), skill=float(np.interp(o, reported, skill)),
                 within_grid=bool(reported[0] <= o <= reported[-1])) for o in observed]


def learner_dict(learners):
    if isinstance(learners, dict):
        return {k: get_learner(v) for k, v in learners.items()}
    if not isinstance(learners, (list, tuple)):
        learners = [learners]
    out = {}
    for l in learners:
        l = get_learner(l)
        if l.name in out:
            raise ValueError(f'two learners are reported under the name "{l.name}". '
                             "Pass a dict to tell them apart.")
        out[l.name] = l
    return out


def _split_arm(ladder: Ladder, name: str):
    if "|" in name:
        window, learner = name.split("|", 1)
    else:
        learner = name
        rows = [r for r in ladder.summary() if r["learner"] == learner]
        if not rows:
            raise KeyError(f'no learner called "{learner}" in this ladder')
        window = max(rows, key=lambda r: r["score"])["window"]
    if not ((ladder.window == window) & (ladder.learner == learner)).any():
        raise KeyError(f'no arm "{window}|{learner}" in this ladder')
    return window, learner


def _label(ladder: Ladder, name: str) -> str:
    window, learner = _split_arm(ladder, name)
    return f"{window}|{learner}"


def _ordered(values):
    seen = []
    for v in values:
        if v not in seen:
            seen.append(v)
    return seen


def _wilcoxon(values) -> float:
    if len(values) < 2 or not np.any(values != 0):
        return float("nan")
    return wilcoxon_p(values)
