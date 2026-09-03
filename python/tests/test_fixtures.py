"""The cross-language contract: the same input reduced the same way gives the same numbers.

A digest mismatch here is a bug in whichever implementation moved, never a fixture to regenerate.
Fixtures are regenerated on the R side, deliberately, in their own commit, and only when
``inst/spec/representation.md`` changed with them.
"""

from __future__ import annotations

import csv
from pathlib import Path

import numpy as np
import pytest

from timegrain import digest_array, window_matrix

FIXTURES = Path(__file__).resolve().parents[2] / "inst" / "spec" / "fixtures"

SERIES_FILE = {"aligned": "series.csv", "offset": "series_offset.csv"}


def read_series(name):
    with (FIXTURES / SERIES_FILE[name]).open(newline="") as fh:
        rows = list(csv.DictReader(fh))
    return {"id": [r["id"] for r in rows],
            "time": [r["time"].replace("Z", "") for r in rows],
            "value": [float(r["value"]) for r in rows]}


def read_digests():
    with (FIXTURES / "digests.csv").open(newline="") as fh:
        return list(csv.DictReader(fh))


def read_edges(name):
    with (FIXTURES / "seasons.csv").open(newline="") as fh:
        rows = [r["edge"].replace("Z", "") for r in csv.DictReader(fh) if r["series"] == name]
    return np.asarray(rows, dtype="datetime64[s]")


def binning(name, window):
    if window != "astronomical":
        return window
    edges = read_edges(name)

    def astronomical(when):
        return edges[np.searchsorted(edges, when, side="right") - 1]

    return astronomical


@pytest.fixture(scope="module")
def series():
    return {name: read_series(name) for name in SERIES_FILE}


@pytest.mark.parametrize(
    "row", read_digests(),
    ids=lambda r: f"{r['series']}-{r['window']}-{r['year_start']}-{r['partial']}-{r['stat']}")
def test_digest_matches_the_r_side(series, row):
    x = window_matrix(series[row["series"]], "id", "time", "value",
                      window=binning(row["series"], row["window"]),
                      stats=row["stat"].split("+"), year_start=row["year_start"],
                      partial=row["partial"])
    # The shape is asserted before the digest, so a binning that puts the record into a different
    # number of bins is reported as that rather than as an unexplained hash mismatch.
    assert x.values.shape[0] == int(row["n_unit"])
    assert x.values.shape[1] == int(row["n_bin"])
    assert x.bins[0] == row["first_bin"]
    assert x.bins[-1] == row["last_bin"]
    assert int(x.bin_partial.sum()) == int(row["n_partial"])
    assert digest_array(x) == row["digest"]


def test_the_fixtures_cover_a_record_that_starts_on_no_bin_boundary():
    # A record beginning at midnight on the year_start anniversary puts every window in phase with
    # it, which is the one input on which a rule that keeps a partial leading bin and a rule that
    # never makes one agree. The contract is only a contract if it also carries the other case.
    rows = read_digests()
    assert {r["series"] for r in rows} == {"aligned", "offset"}
    offset = [r for r in rows if r["series"] == "offset"]
    assert {r["window"] for r in offset} == {"hour", "halfday", "day", "week", "month", "season",
                                             "year", "astronomical"}
    assert sum(int(r["n_partial"]) for r in offset) > 0
    assert {r["partial"] for r in rows} == {"keep", "drop"}
    assert len({r["year_start"] for r in rows}) > 1


def test_dropping_every_bin_is_an_error_rather_than_an_empty_representation(series):
    with pytest.raises(ValueError, match="no whole year"):
        window_matrix(series["offset"], "id", "time", "value", window="year", partial="drop")
    with pytest.raises(ValueError, match="must be"):
        window_matrix(series["offset"], "id", "time", "value", window="day", partial="sometimes")


def test_the_digest_is_the_lf_terminated_twelve_place_form_and_nothing_else():
    import hashlib
    values = np.array([1.0, -0.5]).reshape(2, 1, 1)
    expected = hashlib.md5(b"1.000000000000\n-0.500000000000\n").hexdigest()
    assert digest_array(values) == expected


def test_the_traversal_is_unit_fastest_then_bin_then_channel():
    values = np.arange(2 * 3 * 2, dtype=float).reshape(2, 3, 2)
    flat = values.flatten(order="F")
    assert list(flat[:2]) == [values[0, 0, 0], values[1, 0, 0]]
    assert flat[2] == values[0, 1, 0]
