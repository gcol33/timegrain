from __future__ import annotations

import importlib.util

import numpy as np
import pytest

from timegrain import (Learner, Response, bin_occlusion, ensemble_learner, feature_matrix,
                       fit_learner, fold_map, window_ladder, window_matrix)


def planted(planted_month="2021-11", n_unit=60, seed=61):
    """A record in which the units differ from each other in one stretch of the calendar and
    nowhere else, so the profile has a known answer to be checked against."""
    rng = np.random.default_rng(seed)
    t = np.datetime64("2021-09-01T00:00:00", "s") + np.arange(24 * 210) * np.timedelta64(1, "h")
    in_month = np.array([str(d)[:7] == planted_month for d in t.astype("datetime64[D]")])
    units = [f"p{i:03d}" for i in range(n_unit)]
    warmth = rng.normal(size=n_unit)
    shape = 5 * np.sin(np.arange(len(t)) / (24 * 40))
    value = np.concatenate([shape + w * in_month * 6 + rng.normal(0, 0.3, len(t))
                            for w in warmth])
    readings = {"id": [u for u in units for _ in range(len(t))],
                "time": list(t) * n_unit, "value": list(value)}
    y = rng.binomial(1, 1 / (1 + np.exp(-3 * np.outer(warmth, [1, -1]))))
    return readings, Response(y.astype(float), tuple(units), ("sp0", "sp1")), planted_month


def test_a_feature_table_becomes_a_one_channel_representation():
    m = np.arange(30, dtype=float).reshape(10, 3)
    x = feature_matrix(m, units=[f"p{i}" for i in range(10)], features=["a", "b", "c"])
    assert x.values.shape == (10, 3, 1)
    assert x.bins == ("a", "b", "c")
    assert x.window == "features"
    assert np.array_equal(x.channel("features"), m)


def test_an_ensemble_averages_its_members_before_the_threshold_is_chosen():
    readings, y, _ = planted(n_unit=20)
    x = window_matrix(readings, "id", "time", "value", window="month")
    a = Learner(name="a", fit=lambda x, y, **k: y.mean(axis=0),
                predict=lambda m, x: np.tile(m, (x.values.shape[0], 1)))
    b = Learner(name="b", fit=lambda x, y, **k: y.mean(axis=0) / 2,
                predict=lambda m, x: np.tile(m, (x.values.shape[0], 1)))
    both = fit_learner(ensemble_learner([a, b]), x, y).predict(x)
    assert np.allclose(both, (fit_learner(a, x, y).predict(x)
                              + fit_learner(b, x, y).predict(x)) / 2)
    tilted = fit_learner(ensemble_learner([a, b], weights=[3, 1]), x, y).predict(x)
    assert np.allclose(tilted, 0.75 * fit_learner(a, x, y).predict(x)
                       + 0.25 * fit_learner(b, x, y).predict(x))
    with pytest.raises(ValueError, match="at least two members"):
        ensemble_learner([a])


def test_the_bin_a_signal_was_planted_in_is_the_bin_the_profile_weights():
    if importlib.util.find_spec("sklearn") is None:
        pytest.skip("scikit-learn is not installed")
    readings, y, month = planted()
    x = window_matrix(readings, "id", "time", "value", window="month")
    lad = window_ladder(x, y, "elasticnet", folds=fold_map(y, v=4, seed=6),
                        keep_fits=True, verbose=False)
    out = bin_occlusion(lad, x, y, "month|elasticnet", permutations=5, seed=4)
    mean_weight = np.nanmean(out["weight"], axis=1)
    heaviest = out["part"][int(np.nanargmax(mean_weight))]
    assert heaviest[:7] == month
    assert np.nanmax(mean_weight) > 2 * np.nanmedian(mean_weight)


def test_holding_a_channel_back_asks_what_the_statistic_carries():
    if importlib.util.find_spec("sklearn") is None:
        pytest.skip("scikit-learn is not installed")
    readings, y, _ = planted(n_unit=40, seed=63)
    x = window_matrix(readings, "id", "time", "value", window="month",
                      stats=["cold_day", "mean", "warm_day"])
    lad = window_ladder(x, y, "elasticnet", folds=fold_map(y, v=3, seed=6),
                        keep_fits=True, verbose=False)
    out = bin_occlusion(lad, x, y, "month|elasticnet", over="channel", permutations=3)
    assert list(out["part"]) == ["cold_day", "mean", "warm_day"]


def test_occlusion_needs_the_fits_the_ladder_was_told_to_keep():
    readings, y, _ = planted(n_unit=20)
    x = window_matrix(readings, "id", "time", "value", window="month")
    a = Learner(name="a", fit=lambda x, y, **k: y.mean(axis=0),
                predict=lambda m, x: np.tile(m, (x.values.shape[0], 1)))
    lad = window_ladder(x, y, a, folds=fold_map(y, v=3, seed=2), verbose=False)
    with pytest.raises(ValueError, match="kept no fits"):
        bin_occlusion(lad, x, y, "month|a")
