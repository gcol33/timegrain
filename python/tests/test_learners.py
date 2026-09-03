"""The learners that ship on the aggregate-feature side: the penalised fit and the selector."""

from __future__ import annotations

import importlib.util

import numpy as np
import pytest

from timegrain import (Response, elasticnet_learner, fit_learner, roc_auc, stepwise_learner,
                       window_matrix)
from timegrain.learners import _apply_basis, _logistic, _poly_basis

needs_sklearn = pytest.mark.skipif(importlib.util.find_spec("sklearn") is None,
                                   reason="scikit-learn is not installed")


def planted(n_unit=40, days=56, noise=1.0, seed=17):
    """A record whose weekly level carries the response, and nothing else does."""
    rng = np.random.default_rng(seed)
    t = np.datetime64("2021-09-01T00:00:00", "s") + np.arange(24 * days) * np.timedelta64(1, "h")
    units = [f"p{i:02d}" for i in range(n_unit)]
    warmth = rng.normal(size=n_unit)
    value = np.concatenate([w * 2.0 + rng.normal(0, noise, len(t)) for w in warmth])
    d = {"id": [u for u in units for _ in range(len(t))],
         "time": list(t) * n_unit, "value": list(value)}
    y = rng.binomial(1, 1 / (1 + np.exp(-3 * np.column_stack([warmth, -warmth])))).astype(float)
    x = window_matrix(d, "id", "time", "value", window="week")
    return x, Response(y, tuple(units), ("sp1", "sp2"))


def test_the_selector_fits_predicts_and_finds_the_planted_signal():
    x, y = planted()
    fit = fit_learner(stepwise_learner(max_terms=2), x, y)
    p = fit.predict(x)
    assert p.shape == (len(y.units), 2)
    assert np.all((p >= 0) & (p <= 1))
    assert roc_auc(y.values[:, 0], p[:, 0]) > 0.75


def test_the_selector_admits_no_more_columns_than_its_budget():
    x, y = planted()
    for budget in (1, 3):
        model = fit_learner(stepwise_learner(max_terms=budget), x, y).model
        for f in model["models"]:
            assert len(f.get("columns", [])) <= budget


def test_a_variable_with_one_outcome_is_predicted_as_its_share():
    x, y = planted()
    flat = Response(np.column_stack([y.values[:, 0], np.zeros(len(y.units))]),
                    y.units, ("sp1", "absent"))
    fit = fit_learner(stepwise_learner(), x, flat)
    p = fit.predict(x)
    assert np.allclose(p[:, 1], 0.0)


def test_predicting_a_single_unit_returns_one_row_and_not_one_column():
    x, y = planted()
    fit = fit_learner(stepwise_learner(max_terms=2), x, y)
    one = x.take_units([0])
    assert fit.predict(one).shape == (1, 2)


def test_the_selector_refuses_a_representation_it_was_not_fitted_on():
    x, y = planted()
    fit = fit_learner(stepwise_learner(max_terms=1), x, y)
    with pytest.raises(ValueError, match="different channels or bins"):
        fit.predict(window_matrix(
            {"id": [u for u in y.units for _ in range(24)],
             "time": list(np.datetime64("2021-09-01T00:00:00", "s")
                          + np.arange(24) * np.timedelta64(1, "h")) * len(y.units),
             "value": list(np.zeros(24 * len(y.units)))},
            "id", "time", "value", window="day"))


def test_the_polynomial_basis_is_orthonormal_and_travels_with_the_fit():
    rng = np.random.default_rng(2)
    v = rng.normal(size=50)
    basis = _poly_basis(v, 3)
    z = basis["values"]
    # Orthonormal columns, and orthogonal to the constant: that is what makes a degree admitted
    # after another one carry only what the earlier one does not.
    assert np.allclose(z.T @ z, np.eye(3), atol=1e-10)
    assert np.allclose(z.sum(axis=0), 0.0, atol=1e-10)
    # New units are mapped through the basis the fit carries, never through one re-derived from
    # themselves: a subset re-derived would give a different basis.
    part = _apply_basis(basis, v[:10])
    assert np.allclose(part, z[:10])
    assert not np.allclose(_poly_basis(v[:10], 3)["values"], part)


def test_a_degree_beyond_what_the_readings_distinguish_is_dropped():
    assert _poly_basis(np.array([1.0, 1.0, 2.0, 2.0]), 3)["degree"] == 1
    assert _poly_basis(np.array([1.0, 2.0, 3.0]), 5)["degree"] == 2


def test_a_separated_or_unsettled_fit_is_refused_rather_than_returned():
    y = np.array([0.0, 0.0, 0.0, 1.0, 1.0, 1.0])
    separating = np.array([-3.0, -2.0, -1.0, 1.0, 2.0, 3.0]).reshape(-1, 1)
    assert _logistic(separating, y) is None
    overlapping = np.array([-1.0, 1.0, -0.5, 0.5, -0.2, 0.7]).reshape(-1, 1)
    fit = _logistic(overlapping, y)
    assert fit is not None and np.isfinite(fit["aic"])


@needs_sklearn
def test_a_setting_given_at_fit_time_overrides_the_one_the_learner_carries():
    x, y = planted(n_unit=24, days=28)
    overridden = fit_learner(elasticnet_learner(), x, y, squares=False)
    built = fit_learner(elasticnet_learner(squares=False), x, y)
    assert overridden.model["squares"] is False
    assert np.allclose(overridden.predict(x), built.predict(x))


@needs_sklearn
def test_the_settings_a_learner_carries_are_the_ones_it_reports():
    learner = elasticnet_learner(alpha=0.25, n_inner=3)
    assert learner.params["alpha"] == 0.25
    assert learner.params["n_inner"] == 3
    assert learner.params["weight_positives"] is True
