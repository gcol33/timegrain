"""The cross-language digest of a representation, defined in ``inst/spec/representation.md``.

Values are traversed in the array's own order, unit fastest, then bin, then channel; each is
formatted to twelve decimal places, joined with a line feed and terminated with one, and the UTF-8
bytes of that are hashed. The line ending is a line feed on every platform, so a digest produced on
one machine and checked on another has to agree.
"""

from __future__ import annotations

import hashlib

import numpy as np


def digest_array(values) -> str:
    """MD5 of the representation, byte-exactly as the spec defines it."""
    if hasattr(values, "values"):
        values = values.values
    flat = np.asarray(values, dtype=np.float64).flatten(order="F")
    body = "".join(f"{v:.12f}\n" for v in flat)
    return hashlib.md5(body.encode("utf-8")).hexdigest()
