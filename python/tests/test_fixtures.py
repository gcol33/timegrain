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


def read_series():
    with (FIXTURES / "series.csv").open(newline="") as fh:
        rows = list(csv.DictReader(fh))
    return {"id": [r["id"] for r in rows],
            "time": [r["time"].replace("Z", "") for r in rows],
            "value": [float(r["value"]) for r in rows]}


def read_digests():
    with (FIXTURES / "digests.csv").open(newline="") as fh:
        return list(csv.DictReader(fh))


@pytest.fixture(scope="module")
def series():
    return read_series()


@pytest.mark.parametrize("row", read_digests(),
                         ids=lambda r: f"{r['window']}-{r['stat']}")
def test_digest_matches_the_r_side(series, row):
    x = window_matrix(series, "id", "time", "value", window=row["window"],
                      stats=row["stat"].split("+"))
    assert x.values.shape[0] == int(row["n_unit"])
    assert x.values.shape[1] == int(row["n_bin"])
    assert digest_array(x) == row["digest"]


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
