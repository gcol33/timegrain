"""The response, the fold map, and the cells a score is defined on.

The fold map is an artifact rather than an algorithm: it is built once and read by everything that
scores, in either language, so that every arm sees identical splits and any two of them can be
compared cell by cell. ``fold_map`` builds one; ``read_folds`` reads one somebody else built.
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np


@dataclass(frozen=True)
class Response:
    """A ``[unit, variable]`` matrix of observed values, with the units named."""

    values: np.ndarray
    units: tuple[str, ...]
    variables: tuple[str, ...]

    @classmethod
    def from_columns(cls, data, id: str, variables=None) -> "Response":
        units = [str(v) for v in data[id]]
        variables = list(variables) if variables is not None else \
            [k for k in data.keys() if k != id]
        values = np.column_stack([np.asarray(data[v], dtype=np.float64) for v in variables])
        return cls(values=values, units=tuple(units), variables=tuple(variables))

    def take_units(self, index) -> "Response":
        index = np.asarray(index)
        return Response(self.values[index], tuple(np.asarray(self.units)[index]), self.variables)

    def align(self, units) -> "Response":
        if tuple(units) == self.units:
            return self
        position = {u: i for i, u in enumerate(self.units)}
        missing = [u for u in units if u not in position]
        if missing:
            raise ValueError(f"{len(missing)} units are in the representation but not the "
                             f"response, first: {missing[0]}")
        return self.take_units([position[u] for u in units])

    def check_presence_absence(self) -> "Response":
        if not np.isin(self.values, (0, 1)).all():
            raise ValueError("a presence-absence response must be 0/1 or logical")
        if np.isnan(self.values).any():
            raise ValueError("the response holds missing values")
        return self


@dataclass(frozen=True)
class Cells:
    """Which ``(variable, fold)`` cells admit a score, and the counts that decided it."""

    variable: np.ndarray
    fold: np.ndarray
    n_occ: np.ndarray
    pres_train: np.ndarray
    abs_train: np.ndarray
    pres_test: np.ndarray
    abs_test: np.ndarray
    scorable: np.ndarray

    def is_scorable(self, variable: str, fold: int) -> bool:
        hit = (self.variable == variable) & (self.fold == fold)
        return bool(self.scorable[hit][0]) if hit.any() else False

    def __repr__(self) -> str:  # pragma: no cover - display only
        by_variable = {v: False for v in self.variable}
        for v, ok in zip(self.variable, self.scorable):
            by_variable[v] = by_variable[v] or bool(ok)
        return (f"<timegrain cells> {len(self.variable)} cells over {len(by_variable)} variables\n"
                f"scorable: {int(self.scorable.sum())} "
                f"({100 * self.scorable.mean():.1f}%); variables with at least one scorable fold: "
                f"{sum(by_variable.values())} of {len(by_variable)}")


def fold_map(y: Response, v: int = 10, seed: int = 1, strata: int = 5, by=None) -> np.ndarray:
    """Assign units to folds, balanced within equal-count strata of a stratifying value.

    The stream is numpy's, so a map built here is not the map the R side builds from the same seed.
    Where both languages must see identical splits, build the map once and read it in the other
    with ``read_folds``.
    """
    n = y.values.shape[0]
    if not 2 <= v <= n:
        raise ValueError(f"`v` must be between 2 and the {n} units, got {v}")
    value = y.values.sum(axis=1) if by is None else np.asarray(by, dtype=np.float64)
    if len(value) != n:
        raise ValueError(f"`by` must have one value per unit, got {len(value)} for {n}")
    stratum = np.ones(n, dtype=int) if strata <= 1 else _quantile_strata(value, strata)

    rng = np.random.default_rng(seed)
    fold = np.empty(n, dtype=int)
    for s in np.unique(stratum):
        idx = np.flatnonzero(stratum == s)
        rng.shuffle(idx)
        labels = rng.permutation(v) + 1
        fold[idx] = np.resize(labels, len(idx))
    return fold


def read_folds(mapping, units) -> np.ndarray:
    """Put a fold map somebody else built into the row order of a representation."""
    if isinstance(mapping, dict):
        missing = [u for u in units if u not in mapping]
        if missing:
            raise ValueError(f"{len(missing)} units have no fold, first: {missing[0]}")
        return np.asarray([int(mapping[u]) for u in units])
    out = np.asarray(mapping, dtype=int)
    if len(out) != len(units):
        raise ValueError(f"an unnamed fold map must have one entry per unit, got {len(out)} "
                         f"for {len(units)}")
    return out


def scorable_cells(y: Response, folds) -> Cells:
    """Which cells admit a score, from the response and the fold map alone.

    A cell needs both classes among the held-out units and both classes among the units a model is
    fitted on. Computing the mask without a model is what lets every arm be restricted to the same
    cells, so their means share a denominator and every paired difference runs on matched cells.
    """
    folds = read_folds(folds, y.units)
    levels = np.unique(folds)
    n_occ = y.values.sum(axis=0).astype(np.int64)

    variable, fold, occ, p_test, a_test = [], [], [], [], []
    for k in levels:
        rows = folds == k
        pres = y.values[rows].sum(axis=0)
        for j, name in enumerate(y.variables):
            variable.append(name)
            fold.append(int(k))
            occ.append(n_occ[j])
            p_test.append(pres[j])
            a_test.append(int(rows.sum()) - pres[j])

    occ = np.asarray(occ, dtype=np.int64)
    p_test = np.asarray(p_test, dtype=np.int64)
    a_test = np.asarray(a_test, dtype=np.int64)
    p_train = occ - p_test
    a_train = (y.values.shape[0] - occ) - a_test
    order = np.lexsort((np.asarray(fold), np.asarray(variable)))
    return Cells(variable=np.asarray(variable)[order], fold=np.asarray(fold)[order],
                 n_occ=occ[order], pres_train=p_train[order], abs_train=a_train[order],
                 pres_test=p_test[order], abs_test=a_test[order],
                 scorable=((p_train >= 1) & (a_train >= 1) &
                           (p_test >= 1) & (a_test >= 1))[order])


def _quantile_strata(value: np.ndarray, k: int) -> np.ndarray:
    edges = np.unique(np.quantile(value, np.linspace(0, 1, k + 1)))
    if len(edges) < 3:
        return np.ones(len(value), dtype=int)
    return np.clip(np.searchsorted(edges[1:-1], value, side="left"), 0, len(edges) - 2) + 1
