from __future__ import annotations

import importlib.util

import numpy as np
import pytest

from timesift.control import TrainControl, train_control
from timesift.learners import cnn, fit_learner, mlp, rescnn
from timesift.metrics import roc_auc
from timesift.representation import grain_matrix
from timesift.response import Response

pytestmark = pytest.mark.skipif(importlib.util.find_spec("torch") is None,
                                reason="torch is not installed")


def fixture(n_unit=40, days=90, noise=0.5, level=3.0, seed=81):
    rng = np.random.default_rng(seed)
    t = np.datetime64("2021-09-01T00:00:00", "s") + np.arange(24 * days) * np.timedelta64(1, "h")
    units = [f"p{i:03d}" for i in range(n_unit)]
    warmth = rng.normal(size=n_unit)
    shape = 5 * np.sin(np.arange(len(t)) / (24 * 30))
    value = np.concatenate([level * w + shape + rng.normal(0, noise, len(t)) for w in warmth])
    readings = {"id": [u for u in units for _ in range(len(t))],
                "time": list(t) * n_unit, "value": list(value)}
    y = rng.binomial(1, 1 / (1 + np.exp(-4 * np.outer(warmth, [1, -1]))))
    x = grain_matrix(readings, "id", "time", "value", grain="week",
                      stats=["cold_day", "mean", "warm_day"])
    return x, Response(y.astype(float), tuple(units), ("sp0", "sp1")), readings


@pytest.mark.parametrize("build", [
    lambda: mlp(epochs=3),
    lambda: cnn(epochs=3),
    lambda: rescnn(epochs=3, channels=(16, 32)),
])
def test_every_encoder_fits_and_returns_one_probability_per_unit_and_variable(build):
    x, y, _ = fixture()
    p = fit_learner(build(), x, y).predict(x)
    assert p.shape == (40, 2)
    assert ((p > 0) & (p < 1)).all()


def test_the_same_seed_gives_the_same_fit():
    x, y, _ = fixture(n_unit=24, days=60)
    a = fit_learner(cnn(epochs=3, seed=4), x, y).predict(x)
    b = fit_learner(cnn(epochs=3, seed=4), x, y).predict(x)
    assert np.allclose(a, b)


def test_the_stack_still_runs_where_the_record_is_one_bin_per_year():
    _, y, readings = fixture(n_unit=24, days=400, seed=83)
    for w in ("season", "year"):
        x = grain_matrix(readings, "id", "time", "value", grain=w)
        assert x.values.shape[1] <= 5
        for build in (lambda: cnn(epochs=2),
                      lambda: rescnn(epochs=2, channels=(16, 32))):
            assert fit_learner(build(), x, y).predict(x).shape == (24, 2)


def test_an_encoder_refuses_a_representation_it_was_not_fitted_on():
    x, y, readings = fixture(n_unit=24, days=60)
    fit = fit_learner(cnn(epochs=2), x, y)
    other = grain_matrix(readings, "id", "time", "value", grain="month")
    with pytest.raises(ValueError, match="different channels or bins"):
        fit.predict(other)


def test_a_fully_connected_encoder_recovers_a_planted_signal():
    x, y, _ = fixture(n_unit=90, days=90, noise=0.3, seed=85)
    p = fit_learner(mlp(epochs=40, seed=3), x, y).predict(x)
    assert roc_auc(y.values[:, 0], p[:, 0]) > 0.8


def test_weight_averaging_runs_the_whole_averaging_grain_and_returns_a_usable_fit():
    x, y, _ = fixture(n_unit=30, days=60)
    p = fit_learner(cnn(epochs=6, swa=True, swa_start=0.5), x, y).predict(x)
    assert p.shape == (30, 2)
    assert np.isfinite(p).all() and ((p > 0) & (p < 1)).all()


def test_averaging_the_tail_is_not_the_same_fit_as_keeping_one_epoch_of_it():
    x, y, _ = fixture(n_unit=30, days=60)
    averaged = fit_learner(cnn(epochs=6, swa=True, swa_start=0.5, seed=7), x, y).predict(x)
    single = fit_learner(cnn(epochs=6, seed=7), x, y).predict(x)
    assert not np.allclose(averaged, single)


def test_a_setting_given_at_fit_time_overrides_the_one_the_learner_carries():
    x, y, _ = fixture(n_unit=20, days=40)
    wide = fit_learner(cnn(epochs=2), x, y, channels=(8, 16)).predict(x)
    narrow = fit_learner(cnn(epochs=2, channels=(8, 16)), x, y).predict(x)
    assert np.allclose(wide, narrow)
    assert not np.allclose(wide, fit_learner(cnn(epochs=2), x, y).predict(x))


def test_an_architecture_carries_architecture_and_the_control_carries_the_training():
    learner = cnn(channels=(8, 16), epochs=4)
    assert learner.params["channels"] == (8, 16)
    # The settings a learner was not told about are the control's, so there is one place they are
    # defaulted and a learner carries only what it was asked to change.
    assert learner.params["epochs"] == 4
    assert "batch_size" not in learner.params
    assert TrainControl().batch_size == train_control().batch_size == 64


def test_a_training_setting_reaches_a_learner_through_the_control():
    x, y, _ = fixture(n_unit=20, days=40)
    control = fit_learner(cnn(channels=(8, 16)), x, y,
                          control=train_control(epochs=2, seed=5)).predict(x)
    given = fit_learner(cnn(channels=(8, 16), epochs=2, seed=5), x, y).predict(x)
    assert np.allclose(control, given)


def test_a_setting_on_a_learner_wins_over_the_control_it_is_fitted_under():
    x, y, _ = fixture(n_unit=20, days=40)
    pinned = fit_learner(cnn(channels=(8, 16), epochs=2, seed=5), x, y,
                         control=train_control(epochs=2, seed=11)).predict(x)
    same = fit_learner(cnn(channels=(8, 16), epochs=2, seed=5), x, y).predict(x)
    assert np.allclose(pinned, same)


def test_a_setting_no_learner_and_no_control_carries_is_refused():
    with pytest.raises(TypeError, match="no training setting called learning_rat"):
        cnn(learning_rat=1e-3)
    x, y, _ = fixture(n_unit=20, days=40)
    with pytest.raises(TypeError, match="no setting called kernal"):
        fit_learner(cnn(epochs=2), x, y, kernal=3)
