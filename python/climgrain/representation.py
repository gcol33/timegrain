"""Reduce sensor series to a temporal grain.

Implements ``inst/spec/representation.md``. Where this file and that document disagree, the document is
right: it is also what the R side answers to, and the two are held together by the digests in
``inst/spec/fixtures/``.

The binning and the reduction are not written here. They are ``src/cg_core.cpp``, compiled into
``climgrain._core`` and into the R package alike, so the two languages agree by construction rather
than by two implementations being checked against each other after the fact. What is written here
is the boundary: resolving the columns, resolving the zone, and putting the result into a
``WindowMatrix``.
"""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass, field, replace
from datetime import datetime

import numpy as np

from . import _core

WINDOWS = ("hour", "halfday", "day", "week", "month", "season", "year")
DAY_LEVEL_STATS = ("cold_day", "warm_day", "mean_daily_min", "mean_daily_max")
STATS = ("mean", "min", "max") + DAY_LEVEL_STATS


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
    bin_partial: np.ndarray = field(repr=False)

    @property
    def shape(self) -> tuple[int, int, int]:
        """Units, bins and channels."""
        return self.values.shape

    def channel(self, name: str) -> np.ndarray:
        """One statistic as a `[unit, bin]` matrix."""
        return self.values[:, :, self.stats.index(name)]

    def take_units(self, index) -> "WindowMatrix":
        """The representation restricted to a subset of its units, in the order given."""
        index = np.asarray(index)
        return replace(self, values=self.values[index], bin_n=self.bin_n[index],
                       units=tuple(np.asarray(self.units)[index]))

    def __repr__(self) -> str:  # pragma: no cover - display only
        n_u, n_b, n_c = self.values.shape
        return (f"<climgrain matrix> {n_u} units x {n_b} bins x {n_c} channels\n"
                f"window: {self.window}  stats: {', '.join(self.stats)}\n"
                f"from  : {self.bins[0]} to {self.bins[-1]}")


class ClimgrainSet(Mapping):
    """A ladder of representations, one per window.

    Naming several windows in :func:`window_matrix` returns one of these: representations of the
    same units, differing only in how coarsely the record was read. It is what
    :func:`window_ladder` fits across, and it reads as a mapping of window name to representation.
    """

    def __init__(self, parts):
        if isinstance(parts, WindowMatrix):
            parts = {parts.window: parts}
        parts = dict(parts)
        if not parts:
            raise ValueError("a climgrain set is a non-empty mapping of window_matrix() results")
        bad = [k for k, v in parts.items() if not isinstance(v, WindowMatrix)]
        if bad:
            raise ValueError(f"{', '.join(bad)} "
                             f"{'are' if len(bad) > 1 else 'is'} not a window_matrix() result")
        units = next(iter(parts.values())).units
        differ = [k for k, v in parts.items() if v.units != units]
        if differ:
            raise ValueError(f"every window in a set must cover the same units; "
                             f"{', '.join(differ)} does not")
        self._parts = parts

    def __getitem__(self, key):
        if isinstance(key, (list, tuple)):
            return ClimgrainSet({k: self._parts[k] for k in key})
        return self._parts[key]

    def __iter__(self):
        return iter(self._parts)

    def __len__(self) -> int:
        return len(self._parts)

    @property
    def units(self) -> tuple[str, ...]:
        """The units the set covers, which every window in it shares."""
        return next(iter(self._parts.values())).units

    def __repr__(self) -> str:  # pragma: no cover - display only
        lines = [f"<climgrain set> {len(self._parts)} windows over {len(self.units)} units"]
        for name, m in self._parts.items():
            lines.append(f"  {name:<10} {m.values.shape[1]:5d} bins x {m.values.shape[2]} "
                         f"channels ({', '.join(m.stats)})")
        return "\n".join(lines)


def climgrain_set(x) -> ClimgrainSet:
    """Every entry point that fits across windows takes a representation, a set, or a bare mapping,
    and works on a set. One coercion, so no caller repeats the three cases."""
    return x if isinstance(x, ClimgrainSet) else ClimgrainSet(x)


def window_matrix(data=None, id=None, time=None, value=None, *, window="day", stats=("mean",),
                  year_start="09-01", partial="keep", tz=None):
    """Bin readings by the calendar and summarise every bin.

    ``data`` is a mapping of column name to sequence, or any object with ``__getitem__`` over the
    three column names given by ``id``, ``time`` and ``value``. Naming two or more windows returns
    a :class:`ClimgrainSet`; naming one, whether as a string or as a sequence of one, returns the
    representation itself. ``window`` may also be a callable, which is handed the reading instants
    and must return the start of each reading's bin.

    ``tz`` names the calendar to bin by. Left at ``None`` the instants are taken as already
    expressed in that calendar, which is what a zone-free ``datetime64`` says and what the R side
    does for a series carried in UTC. Given a zone name, the instants are read as UTC and binned by
    that zone's clock, which is what the R side does for a series carrying a ``tzone``: the same
    instants and the same zone give the same answer in both languages.

    ``partial`` says what becomes of a bin the record does not cover for its whole calendar span,
    which is what a record beginning or ending away from a bin boundary produces. ``"keep"``, the
    default, returns it alongside the full bins; ``"drop"`` removes it. Either way the verdict is
    carried on ``bin_partial``, so a kept partial bin is labelled rather than silent. A
    caller-supplied binning declares its own bins, so the package cannot know where the last one
    was meant to end and takes the record's end as its end.
    """
    unit, when, reading = _columns(data, id, time, value)
    partial = _check_partial(partial)

    if not callable(window) and not isinstance(window, str):
        named = _check_windows(window)
        parts = {w: window_matrix(data, id, time, value, window=w, stats=stats,
                                  year_start=year_start, partial=partial, tz=tz)
                 for w in named}
        # One window is one representation, as it is when it is named as a string: a set of one is
        # a shape the caller then has to unwrap for no reason, and the R side does not make one.
        return parts[named[0]] if len(named) == 1 else ClimgrainSet(parts)

    stats = _check_stats(stats, window)
    ys = _parse_year_start(year_start)
    zone = _zone(tz)

    instant = np.ascontiguousarray(when.astype("datetime64[s]").astype(np.int64))
    units, unit_ix = np.unique(unit, return_inverse=True)
    unit_ix = np.ascontiguousarray(unit_ix.astype(np.int32))
    _check_readings(units, unit_ix, instant, when, reading)
    local = _naive_seconds(instant, zone)

    supplied = None
    if callable(window):
        given = np.asarray(window(when), dtype="datetime64[s]")
        if given.shape != when.shape:
            raise ValueError("a window function must return one bin start per reading")
        supplied = _naive_seconds(np.ascontiguousarray(given.astype(np.int64)), zone)

    name = "custom" if callable(window) else window
    values, bin_start, bin_end, bin_n, bin_partial = _core.reduce(
        unit_ix, reading, instant, local, supplied, [str(u) for u in units],
        name, ys[0], ys[1], list(stats), _sampling_step(instant))

    n_u, n_b, n_c = len(units), len(bin_start), len(stats)
    starts = _local_to_instant(bin_start, zone).astype("datetime64[s]")
    x = WindowMatrix(
        values=np.ascontiguousarray(values.reshape(n_c, n_b, n_u).transpose(2, 1, 0)),
        units=tuple(str(u) for u in units), bins=tuple(_iso(b) for b in starts),
        stats=tuple(stats), window=name, year_start=year_start,
        bin_start=starts, bin_end=bin_end.astype("datetime64[s]"),
        bin_n=bin_n.reshape(n_b, n_u).T, bin_partial=bin_partial.astype(bool),
    )
    return _drop_partial(x) if partial == "drop" else x


def _drop_partial(x: WindowMatrix) -> WindowMatrix:
    """Keeping or dropping a partial bin is the caller's choice, so the array is built over every
    bin the calendar produced and the unwanted ones are removed afterwards, which keeps one binning
    path rather than one per setting."""
    keep = np.flatnonzero(~x.bin_partial)
    if not len(keep):
        raise ValueError(f"dropping the partial bins leaves no bin: the record covers no whole "
                         f"{x.window}. Use partial='keep' or a finer window.")
    if len(keep) == len(x.bin_partial):
        return x
    return replace(x, values=x.values[:, keep, :], bins=tuple(x.bins[i] for i in keep),
                   bin_start=x.bin_start[keep], bin_end=x.bin_end[keep],
                   bin_n=x.bin_n[:, keep], bin_partial=x.bin_partial[keep])


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


# ---- the zone ---------------------------------------------------------------------------------

def _zone(tz):
    """The zone lives at this boundary and nowhere else; the core bins a calendar with no zone in
    it. ``None``, and UTC, mean the instants already read as the calendar to bin by."""
    if tz is None:
        return None
    if isinstance(tz, str):
        if tz in ("UTC", "GMT"):
            return None
        from zoneinfo import ZoneInfo
        return ZoneInfo(tz)
    return tz


def _naive_seconds(instant: np.ndarray, zone) -> np.ndarray:
    """The clock each instant reads in ``zone``, as seconds. Defined for every instant in every
    zone; it is the reverse direction that is not."""
    if zone is None:
        return instant
    u, inverse = np.unique(instant, return_inverse=True)
    offset = np.fromiter((_offset_at(int(t), zone) for t in u), dtype=np.int64, count=len(u))
    return np.ascontiguousarray((u + offset)[inverse])


def _local_to_instant(local: np.ndarray, zone) -> np.ndarray:
    """The instant whose clock in ``zone`` reads each given local time. The offsets in force a day
    either side bracket any transition, so one of the three candidates is it. A local time the
    clock skipped has no instant at all, and the answer is then the instant the clock jumped to; a
    local time the clock repeated has two, and the answer is the first of them."""
    if zone is None:
        return local
    out = np.empty(len(local), dtype=np.int64)
    for i, value in enumerate(local):
        target = int(value)
        candidate = [target - _offset_at(target + shift, zone) for shift in (-86400, 0, 86400)]
        valid = [c for c in candidate if c + _offset_at(c, zone) == target]
        out[i] = min(valid) if valid else max(candidate)
    return out


def _offset_at(instant: int, zone) -> int:
    return int(datetime.fromtimestamp(instant, zone).utcoffset().total_seconds())


def _sampling_step(instant: np.ndarray) -> int:
    u = np.unique(instant)
    return int(np.diff(u).min()) if len(u) > 1 else 0


# ---- checks ----------------------------------------------------------------------------------

def _columns(data, id, time, value):
    raw = list(data[id])
    if any(v is None or (isinstance(v, float) and v != v) for v in raw):
        raise ValueError("missing values in the readings. "
                         "Fill or drop them before building a representation.")
    unit = np.asarray([str(v) for v in raw])
    when = np.asarray(data[time], dtype="datetime64[s]")
    reading = np.ascontiguousarray(np.asarray(data[value], dtype=np.float64))
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


def _check_partial(partial):
    if partial not in ("keep", "drop"):
        raise ValueError(f'`partial` must be "keep" or "drop", got "{partial}"')
    return partial


def _parse_year_start(year_start: str):
    parts = year_start.split("-")
    if len(parts) != 2 or not all(len(p) == 2 and p.isdigit() for p in parts):
        raise ValueError(f'`year_start` must look like "MM-DD", got "{year_start}"')
    month, day = int(parts[0]), int(parts[1])
    if not (1 <= month <= 12 and 1 <= day <= 28):
        raise ValueError(f'`year_start` must be a month 01-12 and a day 01-28, got "{year_start}"')
    return month, day


def _check_readings(units, unit_ix, instant, when, reading):
    """The instants are the whole seconds the calendar is read at, so two readings a fraction of a
    second apart are the same reading twice here. Sorting by (unit, time) and looking at neighbours
    costs no string per reading, which on a record of tens of millions matters."""
    if np.isnat(when).any() or np.isnan(reading).any():
        raise ValueError("missing values in the readings. "
                         "Fill or drop them before building a representation.")
    if len(instant) < 2:
        return
    order = np.lexsort((instant, unit_ix))
    same = ((unit_ix[order][1:] == unit_ix[order][:-1])
            & (instant[order][1:] == instant[order][:-1]))
    if same.any():
        first = order[int(np.flatnonzero(same)[0]) + 1]
        raise ValueError(f"{int(same.sum())} duplicated (unit, time) pairs, "
                         f"first: {units[unit_ix[first]]} at {_iso(when[first])}")


def _iso(t: np.datetime64) -> str:
    return np.datetime_as_string(t.astype("datetime64[s]"), unit="s") + "Z"
