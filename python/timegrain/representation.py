"""Reduce sensor series to a temporal grain.

Implements ``inst/spec/representation.md``. Where this file and that document disagree, the document is
right: it is also what the R side answers to, and the two are held together by the digests in
``inst/spec/fixtures/``.
"""

from __future__ import annotations

from dataclasses import dataclass, field, replace

import numpy as np

WINDOWS = ("hour", "halfday", "day", "week", "month", "season", "year")
DAY_LEVEL_STATS = ("cold_day", "warm_day", "mean_daily_min", "mean_daily_max")
STATS = ("mean", "min", "max") + DAY_LEVEL_STATS

_HOUR = np.timedelta64(1, "h")
_DAY = np.timedelta64(1, "D")


@dataclass(frozen=True)
class WindowMatrix:
    """A ``[unit, bin, channel]`` representation and the binning that produced it."""

    values: np.ndarray
    units: tuple[str, ...]
    bins: tuple[str, ...]
    stats: tuple[str, ...]
    window: str
    year_start: str
    bin_start: np.ndarray
    bin_end: np.ndarray
    bin_n: np.ndarray = field(repr=False)

    @property
    def shape(self) -> tuple[int, int, int]:
        return self.values.shape

    def channel(self, name: str) -> np.ndarray:
        return self.values[:, :, self.stats.index(name)]

    def take_units(self, index) -> "WindowMatrix":
        index = np.asarray(index)
        return replace(self, values=self.values[index], bin_n=self.bin_n[index],
                       units=tuple(np.asarray(self.units)[index]))

    def __repr__(self) -> str:  # pragma: no cover - display only
        n_u, n_b, n_c = self.values.shape
        return (f"<timegrain matrix> {n_u} units x {n_b} bins x {n_c} channels\n"
                f"window: {self.window}  stats: {', '.join(self.stats)}\n"
                f"from  : {self.bins[0]} to {self.bins[-1]}")


def window_matrix(data=None, id=None, time=None, value=None, *, window="day", stats=("mean",),
                  year_start="09-01"):
    """Bin readings by the calendar and summarise every bin.

    ``data`` is a mapping of column name to sequence, or any object with ``__getitem__`` over the
    three column names given by ``id``, ``time`` and ``value``. Naming several windows returns a
    dict of one representation per window. ``window`` may also be a callable, which is handed the
    reading instants and must return the start of each reading's bin.
    """
    unit, when, reading = _columns(data, id, time, value)

    if not callable(window) and not isinstance(window, str):
        return {w: window_matrix(data, id, time, value, window=w, stats=stats,
                                 year_start=year_start)
                for w in _check_windows(window)}

    stats = _check_stats(stats, window)
    ys = _parse_year_start(year_start)
    _check_readings(unit, when, reading)

    bin_start = _bin_start(when, window, ys)
    units, unit_ix = np.unique(unit, return_inverse=True)
    bins, bin_ix = np.unique(bin_start, return_inverse=True)
    n_u, n_b = len(units), len(bins)

    cell = bin_ix * n_u + unit_ix
    count = np.bincount(cell, minlength=n_u * n_b)
    _check_grid(count, units, bins, n_u)

    order = np.argsort(cell, kind="stable")
    reading_sorted = reading[order]
    starts = np.searchsorted(cell[order], np.arange(n_u * n_b), side="left")

    day = _day_level(reading, unit_ix, when, bins, n_u, ys) \
        if any(s in DAY_LEVEL_STATS for s in stats) else None

    out = np.empty((n_u, n_b, len(stats)), dtype=np.float64)
    for k, s in enumerate(stats):
        if s == "mean":
            flat = np.bincount(cell, weights=reading, minlength=n_u * n_b) / count
        elif s == "min":
            flat = np.minimum.reduceat(reading_sorted, starts)
        elif s == "max":
            flat = np.maximum.reduceat(reading_sorted, starts)
        elif s == "cold_day":
            flat = _reduce(day["mean"], day["cell"], n_u * n_b, "min")
        elif s == "warm_day":
            flat = _reduce(day["mean"], day["cell"], n_u * n_b, "max")
        elif s == "mean_daily_min":
            flat = _reduce(day["min"], day["cell"], n_u * n_b, "mean")
        else:
            flat = _reduce(day["max"], day["cell"], n_u * n_b, "mean")
        out[:, :, k] = flat.reshape(n_b, n_u).T

    bin_end = _bin_extent(when, bin_ix, n_b)
    return WindowMatrix(
        values=out, units=tuple(str(u) for u in units), bins=tuple(_iso(b) for b in bins),
        stats=tuple(stats), window="custom" if callable(window) else window,
        year_start=year_start, bin_start=bins, bin_end=bin_end,
        bin_n=count.reshape(n_b, n_u).T,
    )


def calendar_channels(x: WindowMatrix) -> WindowMatrix:
    """Where in the year each bin sits, as the sine and cosine of its fractional position."""
    mid = x.bin_start + (x.bin_end - x.bin_start) / 2
    year = mid.astype("datetime64[Y]")
    length = (year + 1).astype("datetime64[s]").astype(np.int64) \
        - year.astype("datetime64[s]").astype(np.int64)
    frac = (mid.astype("datetime64[s]").astype(np.int64)
            - year.astype("datetime64[s]").astype(np.int64)) / length

    n_u = x.values.shape[0]
    out = np.empty((n_u, len(frac), 2), dtype=np.float64)
    out[:, :, 0] = np.sin(2 * np.pi * frac)
    out[:, :, 1] = np.cos(2 * np.pi * frac)
    return replace(x, values=out, stats=("year_sin", "year_cos"))


def bind_channels(*parts: WindowMatrix) -> WindowMatrix:
    """Put the channels of several representations of the same units and bins side by side."""
    if len(parts) < 2:
        raise ValueError("bind_channels() needs at least two representations")
    first = parts[0]
    for k, p in enumerate(parts[1:], start=1):
        if p.units != first.units or p.bins != first.bins:
            raise ValueError(f"argument {k} covers different units or bins from the first")
    names = tuple(s for p in parts for s in p.stats)
    if len(set(names)) != len(names):
        raise ValueError("two representations carry a channel of the same name")
    return replace(first, values=np.concatenate([p.values for p in parts], axis=2), stats=names)


# ---- binning ---------------------------------------------------------------------------------

def _bin_start(when: np.ndarray, window, ys) -> np.ndarray:
    if callable(window):
        out = np.asarray(window(when), dtype="datetime64[s]")
        if out.shape != when.shape:
            raise ValueError("a window function must return one bin start per reading")
        return out
    if window == "hour":
        return when
    day = when.astype("datetime64[D]").astype("datetime64[s]")
    if window == "halfday":
        hour = (when.astype("datetime64[h]") - when.astype("datetime64[D]")).astype(np.int64)
        return day + np.where(hour >= 12, 12, 0) * _HOUR
    if window == "day":
        return day
    if window == "week":
        days = when.astype("datetime64[D]")
        # 1970-01-01 was a Thursday, so (days since the epoch + 3) is zero on a Monday.
        weekday = (days.astype(np.int64) + 3) % 7
        return (days - weekday * _DAY).astype("datetime64[s]")
    if window == "month":
        return when.astype("datetime64[M]").astype("datetime64[s]")
    step = 3 if window == "season" else 12
    return _anniversary(_offset_months(when, ys) // step * step, ys)


def _offset_months(when: np.ndarray, ys) -> np.ndarray:
    months = when.astype("datetime64[M]")
    year = months.astype("datetime64[Y]").astype(int) + 1970
    month = months.astype(int) % 12 + 1
    day = (when.astype("datetime64[D]") - months).astype(np.int64) + 1
    return year * 12 + (month - 1) - (ys[0] - 1) - (day < ys[1]).astype(np.int64)


def _anniversary(offset: np.ndarray, ys) -> np.ndarray:
    absolute = offset + (ys[0] - 1)
    month = (absolute - 1970 * 12).astype("datetime64[M]")
    return (month.astype("datetime64[D]") + (ys[1] - 1) * _DAY).astype("datetime64[s]")


def _day_level(reading, unit_ix, when, bins, n_u, ys):
    """Reduce every (unit, calendar day) to its own mean, minimum and maximum, and say which bin
    cell each of those days falls in. The four day-level statistics are a second reduction over
    those days, which is what keeps an extreme day distinct from an extreme reading."""
    day_start = _bin_start(when, "day", ys)
    days, day_ix = np.unique(day_start, return_inverse=True)
    dcell = day_ix * n_u + unit_ix
    n_dcell = n_u * len(days)

    count = np.bincount(dcell, minlength=n_dcell)
    present = np.flatnonzero(count)
    order = np.argsort(dcell, kind="stable")
    starts = np.searchsorted(dcell[order], np.arange(n_dcell), side="left")
    reading_sorted = reading[order]

    mean = (np.bincount(dcell, weights=reading, minlength=n_dcell)[present]
            / count[present])
    low = np.minimum.reduceat(reading_sorted, starts)[present]
    high = np.maximum.reduceat(reading_sorted, starts)[present]

    day_unit = present % n_u
    bin_of = np.searchsorted(bins, days[present // n_u], side="right") - 1
    return {"cell": bin_of * n_u + day_unit, "mean": mean, "min": low, "max": high}


def _reduce(values, cell, n_cell, how):
    order = np.argsort(cell, kind="stable")
    starts = np.searchsorted(cell[order], np.arange(n_cell), side="left")
    if how == "mean":
        count = np.bincount(cell, minlength=n_cell)
        return np.bincount(cell, weights=values, minlength=n_cell) / count
    ufunc = np.minimum if how == "min" else np.maximum
    return ufunc.reduceat(values[order], starts)


def _bin_extent(when, bin_ix, n_b):
    order = np.argsort(bin_ix, kind="stable")
    starts = np.searchsorted(bin_ix[order], np.arange(n_b), side="left")
    seconds = when.astype("datetime64[s]").astype(np.int64)
    return np.maximum.reduceat(seconds[order], starts).astype("datetime64[s]")


# ---- checks ----------------------------------------------------------------------------------

def _columns(data, id, time, value):
    unit = np.asarray([str(v) for v in data[id]])
    when = np.asarray(data[time], dtype="datetime64[s]")
    reading = np.asarray(data[value], dtype=np.float64)
    if not (len(unit) == len(when) == len(reading)):
        raise ValueError("the three columns must be the same length")
    return unit, when, reading


def _check_windows(window):
    window = list(window)
    bad = [w for w in window if w not in WINDOWS]
    if bad:
        raise ValueError(f"unknown window: {', '.join(bad)}. Available: {', '.join(WINDOWS)}")
    if len(set(window)) != len(window):
        raise ValueError("`window` names a window twice")
    return window


def _check_stats(stats, window):
    stats = [stats] if isinstance(stats, str) else list(stats)
    bad = [s for s in stats if s not in STATS]
    if bad:
        raise ValueError(f"unknown statistic: {', '.join(bad)}. Available: {', '.join(STATS)}")
    if len(set(stats)) != len(stats):
        raise ValueError("`stats` names a statistic twice")
    if isinstance(window, str) and window in ("hour", "halfday"):
        day_level = [s for s in stats if s in DAY_LEVEL_STATS]
        if day_level:
            raise ValueError(f"`{window}` bins are shorter than a day, so "
                             f"{' and '.join(day_level)} is not defined there. "
                             "Use a window of `day` or coarser.")
    return stats


def _parse_year_start(year_start: str):
    parts = year_start.split("-")
    if len(parts) != 2 or not all(len(p) == 2 and p.isdigit() for p in parts):
        raise ValueError(f'`year_start` must look like "MM-DD", got "{year_start}"')
    month, day = int(parts[0]), int(parts[1])
    if not (1 <= month <= 12 and 1 <= day <= 28):
        raise ValueError(f'`year_start` must be a month 01-12 and a day 01-28, got "{year_start}"')
    return month, day


def _check_readings(unit, when, reading):
    if np.isnat(when).any() or np.isnan(reading).any() or (unit == "nan").any():
        raise ValueError("missing values in the readings. "
                         "Fill or drop them before building a representation.")
    key = np.char.add(np.char.add(unit, "\r"), when.astype(str))
    values, counts = np.unique(key, return_counts=True)
    if (counts > 1).any():
        first = values[counts > 1][0].replace("\r", " at ")
        raise ValueError(f"{int((counts > 1).sum())} duplicated (unit, time) pairs, "
                         f"first: {first}")


def _check_grid(count, units, bins, n_u):
    empty = np.flatnonzero(count == 0)
    if not len(empty):
        return
    i = int(empty[0])
    raise ValueError(f"{len(empty)} (unit, bin) cells hold no readings, first: unit "
                     f"{units[i % n_u]} at {_iso(bins[i // n_u])}. "
                     "Every unit must span every bin; gaps are not padded.")


def _iso(t: np.datetime64) -> str:
    return np.datetime_as_string(t.astype("datetime64[s]"), unit="s") + "Z"
