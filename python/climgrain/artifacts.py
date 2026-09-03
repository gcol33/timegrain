"""The three artifacts that cross the language boundary.

The representation is built twice, once per language, from one shared core. The response matrix,
the fold map and the mask of scorable cells are not: they are built once and read wherever they are
needed, because a fold map drawn from a seed here and one drawn from the same seed in R are
different maps, and aligning the two random streams would be the wrong fix.

These six functions are the handover. The R package carries ``write_folds()`` and its siblings
under the same names; they write the same bytes from the same artifact and read the same files, so
a fold map built in either language is usable in the other without the caller knowing the format.

The format is normative and is given in ``inst/spec/representation.md``: CSV, UTF-8, a header row,
no quoting, LF line endings on every platform, numbers at twelve significant digits, and rows
ordered by the identifier under C collation.
"""

from __future__ import annotations

import csv
from pathlib import Path

import numpy as np

from .response import Cells, Folds, Response

CELL_COLUMNS = ("variable", "fold", "n_occ", "pres_train", "abs_train", "pres_test", "abs_test",
                "scorable")

TRUE = ("TRUE", "true", "True", "1")
FALSE = ("FALSE", "false", "False", "0")


def write_folds(x, file) -> Path:
    """Write a fold map as ``id,fold``, ordered by unit."""
    x = Folds.coerce(x)
    order = _by_id(x.units)
    return _write(file, ("id", "fold"),
                  [(x.units[i], _num(x.fold[i])) for i in order])


def read_folds(file, units=None) -> Folds:
    """Read a fold map somebody else built, optionally aligned to a representation's units."""
    rows = _read(file, ("id", "fold"))
    ids = [r["id"] for r in rows]
    if len(set(ids)) != len(ids):
        seen = set()
        first = next(i for i in ids if i in seen or seen.add(i))
        raise ValueError(f"the fold map names {first} more than once")
    out = Folds(fold=np.asarray([_int(r["fold"], file, "fold") for r in rows], dtype=np.int64),
                units=tuple(ids))
    return out if units is None else out.align(units)


def write_response(y: Response, file) -> Path:
    """Write a response as ``id`` and one column per variable, ordered by unit."""
    order = _by_id(y.units)
    return _write(file, ("id",) + tuple(y.variables),
                  [(y.units[i], *(_num(v) for v in y.values[i])) for i in order])


def read_response(file, units=None) -> Response:
    """Read a response matrix. The columns after ``id`` are the variables, in the file's order."""
    rows = _read(file, ("id",))
    variables = tuple(k for k in rows[0] if k != "id") if rows else ()
    if not variables:
        raise ValueError(f"{Path(file).name} holds an id column and no variable")
    values = np.asarray([[_float(r[v], file) for v in variables] for r in rows], dtype=np.float64)
    out = Response(values=values.reshape(len(rows), len(variables)),
                   units=tuple(r["id"] for r in rows), variables=variables)
    return out if units is None else out.align(units)


def write_cells(cells: Cells, file) -> Path:
    """Write a scorable mask, ordered by variable and then by fold."""
    order = np.lexsort((cells.fold, _codepoints(cells.variable)))
    body = []
    for i in order:
        body.append((str(cells.variable[i]), _num(cells.fold[i]), _num(cells.n_occ[i]),
                     _num(cells.pres_train[i]), _num(cells.abs_train[i]), _num(cells.pres_test[i]),
                     _num(cells.abs_test[i]), "TRUE" if cells.scorable[i] else "FALSE"))
    return _write(file, CELL_COLUMNS, body)


def read_cells(file) -> Cells:
    """Read a scorable mask the other language computed."""
    rows = _read(file, CELL_COLUMNS)
    column = {nm: np.asarray([_int(r[nm], file, nm) for r in rows], dtype=np.int64)
              for nm in CELL_COLUMNS[1:7]}
    return Cells(variable=np.asarray([r["variable"] for r in rows]),
                 scorable=np.asarray([_bool(r["scorable"], file) for r in rows]), **column)


# ---- the format itself -------------------------------------------------------------------------

def _num(v) -> str:
    """Twelve significant digits, which renders 0 and 1 as 0 and 1 and carries any measurement a
    response holds. R's sprintf() hands %.12g to the same C library this does."""
    return f"{float(v):.12g}"


def _by_id(units):
    """C collation, which for every code point is also the code point order."""
    return np.argsort(_codepoints(units), kind="stable")


def _codepoints(values):
    return np.asarray([str(v) for v in values], dtype=object).astype(str)


def _write(file, header, rows) -> Path:
    """csv.writer would do most of this, and would also need newline='' to keep from emitting CRLF
    on Windows, which makes the bytes of an artifact depend on the machine that wrote it. The bytes
    are the point, so they are written."""
    body = ",".join(header) + "\n" + "".join(",".join(map(str, r)) + "\n" for r in rows)
    path = Path(file)
    path.write_bytes(body.encode("utf-8"))
    return path


def _read(file, need):
    path = Path(file)
    if not path.exists():
        raise FileNotFoundError(f"no file at {file}")
    with path.open(newline="", encoding="utf-8") as fh:
        rows = list(csv.DictReader(fh))
    have = set(rows[0]) if rows else set()
    missing = [nm for nm in need if nm not in have]
    if missing:
        raise ValueError(f"{path.name} has no {' and '.join(missing)} column")
    return rows


def _int(value, file, column) -> int:
    try:
        return int(float(value))
    except (TypeError, ValueError):
        raise ValueError(f"the {column} column of {Path(file).name} holds a value that is not a "
                         f"whole number") from None


def _float(value, file) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        raise ValueError(f"{Path(file).name} holds a value that is not a number") from None


def _bool(value, file) -> bool:
    if value in TRUE:
        return True
    if value in FALSE:
        return False
    raise ValueError(f"{Path(file).name} holds {value} where a logical was expected")
