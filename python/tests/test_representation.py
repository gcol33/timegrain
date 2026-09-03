from __future__ import annotations

import numpy as np
import pytest

from timegrain import (WINDOWS, bind_channels, calendar_channels, window_matrix)


def hourly(units=("a", "b"), hours=24 * 400, start="2021-09-01"):
    t = np.arange(np.datetime64(start, "s"), dtype="datetime64[s]") if False else \
        np.datetime64(start, "s") + np.arange(hours) * np.timedelta64(1, "h")
    rng = np.random.default_rng(1)
    return {"id": [u for u in units for _ in range(hours)],
            "time": list(t) * len(units),
            "value": rng.normal(size=hours * len(units))}


def brute(data, key, fun):
    out = {}
    for u, k, v in zip(data["id"], key, data["value"]):
        out.setdefault((u, k), []).append(v)
    return {k: fun(v) for k, v in out.items()}


def test_bins_tile_the_record_with_no_gap_and_no_overlap():
    d = hourly()
    for w in WINDOWS:
        x = window_matrix(d, "id", "time", "value", window=w)
        assert x.bin_n.sum(axis=1).tolist() == [24 * 400, 24 * 400], w
        assert (x.bin_n > 0).all(), w


def test_the_mean_matches_an_independent_reduction():
    d = hourly()
    key = [str(np.datetime64(t, "D")) for t in d["time"]]
    ref = brute(d, key, np.mean)
    x = window_matrix(d, "id", "time", "value", window="day", stats="mean")
    for i, u in enumerate(x.units):
        for j, b in enumerate(x.bins):
            assert x.values[i, j, 0] == pytest.approx(ref[(u, b[:10])])


def test_an_extreme_day_is_not_an_extreme_reading():
    t = np.datetime64("2021-09-06T00:00:00", "s") + np.arange(24 * 7) * np.timedelta64(1, "h")
    temp = np.repeat([10.0, 5, 0, 5, 10, 10, 10], 24)
    temp[24 + 5] = -50
    d = {"id": ["a"] * len(t), "time": list(t), "value": list(temp)}
    x = window_matrix(d, "id", "time", "value", window="week",
                      stats=["min", "cold_day", "mean", "warm_day", "max"])
    assert x.channel("min")[0, 0] == -50
    assert x.channel("cold_day")[0, 0] == 0
    assert x.channel("warm_day")[0, 0] == 10
    assert x.channel("max")[0, 0] == 10


def test_the_average_daily_extremes_average_over_days():
    t = np.datetime64("2021-09-06T00:00:00", "s") + np.arange(48) * np.timedelta64(1, "h")
    temp = np.concatenate([np.repeat([-10.0, 10.0], 12), np.zeros(24)])
    d = {"id": ["a"] * len(t), "time": list(t), "value": list(temp)}
    x = window_matrix(d, "id", "time", "value", window="week",
                      stats=["min", "mean_daily_min", "mean", "mean_daily_max", "max"])
    assert x.channel("min")[0, 0] == -10
    assert x.channel("mean_daily_min")[0, 0] == -5
    assert x.channel("mean")[0, 0] == 0
    assert x.channel("mean_daily_max")[0, 0] == 5
    assert x.channel("max")[0, 0] == 10


def test_the_mean_of_the_daily_minima_is_not_the_coldest_day():
    t = np.datetime64("2021-09-06T00:00:00", "s") + np.arange(48) * np.timedelta64(1, "h")
    d = {"id": ["a"] * len(t), "time": list(t), "value": list(np.repeat([0.0, 10.0], 24))}
    x = window_matrix(d, "id", "time", "value", window="week",
                      stats=["cold_day", "mean_daily_min", "mean_daily_max", "warm_day"])
    assert x.channel("cold_day")[0, 0] == 0
    assert x.channel("mean_daily_min")[0, 0] == 5
    assert x.channel("warm_day")[0, 0] == 10


def test_coarse_bins_follow_the_calendar():
    d = hourly(units=("a",))
    x = window_matrix(d, "id", "time", "value", window="month")
    n = x.bin_n[0].tolist()
    assert n[0] == 30 * 24
    assert n[1] == 31 * 24
    assert 28 * 24 in n


def test_seasons_are_three_calendar_months_from_the_year_start():
    d = hourly(units=("a",))
    x = window_matrix(d, "id", "time", "value", window="season", year_start="09-01")
    assert [b[:10] for b in x.bins[:3]] == ["2021-09-01", "2021-12-01", "2022-03-01"]


def test_a_bin_the_record_does_not_fill_is_reported_and_can_be_dropped():
    # 1 September 2021 is a Wednesday, so three hydrological years from it fill every month, season
    # and year of the calendar and neither the first nor the last week of it.
    aligned = hourly(units=("a",), hours=26304, start="2021-09-01")
    for w in ("hour", "halfday", "day", "month", "season", "year"):
        x = window_matrix(aligned, "id", "time", "value", window=w)
        assert not x.bin_partial.any(), w
    week = window_matrix(aligned, "id", "time", "value", window="week")
    assert np.flatnonzero(week.bin_partial).tolist() == [0, 156]
    assert window_matrix(aligned, "id", "time", "value", window="week",
                         partial="drop").values.shape[1] == 155

    # A logger deployed on no boundary at all carries one at the start of every window that
    # aggregates, and the bin it starts is the one holding fewer readings than its neighbours.
    offset = hourly(units=("a",), hours=24 * 300, start="2021-10-17T05:00:00")
    for w in ("halfday", "day", "week", "month", "season"):
        p = window_matrix(offset, "id", "time", "value", window=w).bin_partial
        assert p[0], w
        assert not p[1:-1].any(), w
    m = window_matrix(offset, "id", "time", "value", window="month")
    assert m.bin_n[0, 0] < m.bin_n[0, 1]
    dropped = window_matrix(offset, "id", "time", "value", window="month", partial="drop")
    assert dropped.values.shape[1] == m.values.shape[1] - int(m.bin_partial.sum())
    assert not dropped.bin_partial.any()
    assert np.array_equal(dropped.values, m.values[:, ~m.bin_partial, :])


def test_a_caller_supplied_calendar_owns_its_own_bin_lengths():
    d = hourly(units=("a",), hours=24 * 200, start="2021-09-01")
    # Cut at the equinox rather than on the first of a month, with the first edge at the record's
    # own start: the leading bin is three weeks against a season's three months, and that is the
    # calendar the caller asked for rather than a bin the record failed to fill.
    edges = np.array(["2021-09-01", "2021-09-22", "2021-12-21", "2022-03-20"],
                     dtype="datetime64[s]")

    def astronomical(when):
        return edges[np.searchsorted(edges, when, side="right") - 1]

    x = window_matrix(d, "id", "time", "value", window=astronomical)
    assert x.values.shape[1] == 3
    assert not x.bin_partial.any()
    assert x.bin_n[0, 0] < x.bin_n[0, 1]

    # The same record on the named window counts three calendar months from the anniversary, so it
    # is a different rule and a different number of bins, not a different implementation of one.
    named = window_matrix(d, "id", "time", "value", window="season")
    assert named.values.shape[1] == 3
    assert [b[:10] for b in named.bins] == ["2021-09-01", "2021-12-01", "2022-03-01"]


def test_the_hydrological_year_boundary_moves_with_year_start():
    t = np.datetime64("2021-08-25T00:00:00", "s") + np.arange(24 * 20) * np.timedelta64(1, "h")
    d = {"id": ["a"] * len(t), "time": list(t), "value": [1.0] * len(t)}
    assert window_matrix(d, "id", "time", "value", window="year").values.shape[1] == 2
    assert window_matrix(d, "id", "time", "value", window="year",
                         year_start="01-01").values.shape[1] == 1


def test_naming_several_windows_returns_one_representation_per_window():
    d = hourly(hours=24 * 60)
    s = window_matrix(d, "id", "time", "value", window=["day", "week", "month"])
    assert list(s) == ["day", "week", "month"]
    one = window_matrix(d, "id", "time", "value", window="week")
    assert np.array_equal(s["week"].values, one.values)


def test_a_calendar_the_package_does_not_carry_can_be_passed_as_a_function():
    d = hourly(units=("a",), hours=24 * 120)
    edges = np.array(["2021-06-23", "2021-09-23", "2021-12-21", "2022-03-20"],
                     dtype="datetime64[s]")

    def astronomical(when):
        return edges[np.searchsorted(edges, when, side="right") - 1]

    x = window_matrix(d, "id", "time", "value", window=astronomical)
    assert x.window == "custom"
    assert [b[:10] for b in x.bins] == ["2021-06-23", "2021-09-23", "2021-12-21"]
    assert x.bin_n.sum() == 24 * 120


def test_the_representation_refuses_input_it_cannot_reduce_honestly():
    d = hourly(units=("a",), hours=48)
    gap = {k: v[24:] for k, v in d.items()}
    gap = {k: list(gap[k]) + list(d[k][:24]) for k in d}
    gap["id"] = ["a"] * 24 + ["b"] * 24
    with pytest.raises(ValueError, match="no readings"):
        window_matrix(gap, "id", "time", "value", window="day")

    dup = {k: list(v) + [v[0]] for k, v in d.items()}
    with pytest.raises(ValueError, match="duplicated"):
        window_matrix(dup, "id", "time", "value", window="day")

    with pytest.raises(ValueError, match="not defined"):
        window_matrix(d, "id", "time", "value", window="hour", stats="cold_day")
    with pytest.raises(ValueError, match="twice"):
        window_matrix(d, "id", "time", "value", window="day", stats=["mean", "mean"])
    with pytest.raises(ValueError, match="unknown statistic"):
        window_matrix(d, "id", "time", "value", window="day", stats="median")
    with pytest.raises(ValueError, match="MM-DD"):
        window_matrix(d, "id", "time", "value", window="day", year_start="9-1")


def test_the_calendar_channels_are_the_position_of_a_bin_in_the_year():
    d = hourly()
    x = window_matrix(d, "id", "time", "value", window="month")
    cc = calendar_channels(x)
    assert cc.stats == ("year_sin", "year_cos")
    assert np.allclose(cc.values[0], cc.values[1])
    assert np.allclose(cc.values[0, :, 0] ** 2 + cc.values[0, :, 1] ** 2, 1)


def test_channels_are_joined_in_the_order_they_are_given():
    d = hourly(hours=24 * 60)
    x = window_matrix(d, "id", "time", "value", window="week", stats=["cold_day", "mean"])
    b = bind_channels(x, calendar_channels(x))
    assert b.stats == ("cold_day", "mean", "year_sin", "year_cos")
    assert np.array_equal(b.channel("mean"), x.channel("mean"))
    with pytest.raises(ValueError, match="same name"):
        bind_channels(x, x)
