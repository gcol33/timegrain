"""Which columns of a table an argument names.

R takes tidyselect expressions for ``y``, ``x`` and ``static``. Python has no non-standard
evaluation, so a selection here is a column name, a list of names, a glob such as ``"sp_*"``, or a
predicate taking a name and returning a bool. The four forms are resolved in one place, so the
three arguments cannot drift apart from each other.

A glob or a predicate matching nothing selects nothing rather than raising, which is what
``starts_with()`` does on the R side; a name given in full must exist, which is what ``all_of()``
does. Whoever asked for the selection decides whether an empty one is an error, because ``y``
needs a column and ``static`` is allowed none.
"""

from __future__ import annotations

from fnmatch import fnmatchcase

__all__ = ["column_names", "select_columns"]

GLOB = "*?["


def column_names(data) -> list[str]:
    """The column names of a table, whether it is a mapping of arrays or a data frame."""
    columns = getattr(data, "columns", None)
    return [str(c) for c in (data.keys() if columns is None else columns)]


def select_columns(columns, spec, arg: str, exclude=()) -> list[str]:
    """The columns a selection names, in the order the selection names them.

    An explicit list is taken in the caller's order, because naming the response columns in an
    order is a decision; a glob and a predicate are taken in the table's own order, because
    matching is not an ordering.

    ``exclude`` names columns that exist but cannot be selected here, so naming one is refused
    with the reason rather than reported as a column that does not exist.
    """
    columns = [str(c) for c in columns]
    exclude = [str(c) for c in exclude]
    if spec is None:
        raise ValueError(f"{arg} names no column")
    if isinstance(spec, str) or callable(spec):
        spec = [spec]
    if not isinstance(spec, (list, tuple)):
        raise ValueError(f"{arg} is a column name, a list of names, a glob such as \"sp_*\", or "
                         f"a function of a name, got {type(spec).__name__}")

    out: list[str] = []
    for one in spec:
        for name in _one(columns, exclude, one, arg):
            if name in out:
                raise ValueError(f"{arg} names {name} twice")
            out.append(name)
    return out


def _one(columns, exclude, spec, arg) -> list[str]:
    if callable(spec):
        return [c for c in columns if spec(c)]
    if not isinstance(spec, str):
        raise ValueError(f"{arg} is a column name, a glob such as \"sp_*\", or a function of a "
                         f"name, got {type(spec).__name__}")
    if any(ch in spec for ch in GLOB):
        return [c for c in columns if fnmatchcase(c, spec)]
    if spec in columns:
        return [spec]
    if spec in exclude:
        raise ValueError(f"{arg} names {spec}, which is already read as something else and "
                         f"cannot be a predictor as well")
    raise ValueError(f"{arg} names {spec}, which is not a column of the table. "
                     f"Available: {', '.join(columns)}")
