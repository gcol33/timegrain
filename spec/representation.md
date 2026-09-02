# The representation contract

Normative for both implementations. R and Python must produce the same numbers from the same
input; where this document and either implementation disagree, this document is right.

## Input

A long table of readings with three columns of interest:

| column | type | meaning |
|---|---|---|
| id | character or factor | the unit carrying the sensor (a plot, a site, a device) |
| time | POSIXct, UTC | the instant of the reading |
| value | numeric | the reading |

Requirements, each checked and each an error rather than a warning:

- No missing `id`, `time` or `value`.
- No duplicate `(id, time)` pair.
- Every id spans the same set of bins once binned. A record that stops early is not silently
  padded; it is reported with the ids and the bins concerned.

Ordering of the input rows carries no meaning and is not relied on. The output is ordered by
sorted unique id and by bin start.

## Windows

Bin membership is decided from the calendar in the series' own time zone, not from a running count
of hours, so a bin is a real week or a real month rather than a drifting block of 168 or 730 hours.

| window | bin |
|---|---|
| `hour` | the reading itself, no reduction |
| `halfday` | 00:00-11:59 and 12:00-23:59 of each calendar day |
| `day` | the calendar day |
| `week` | ISO week, Monday to Sunday |
| `month` | the calendar month |
| `season` | three calendar months, counted from `year_start` |
| `year` | the year running from `year_start` |

`year_start` is a `"MM-DD"` string, default `"09-01"`. It sets the boundary of the hydrological
year and therefore also the phase of the seasonal bins.

Bins are contiguous and cover the record with no gap and no overlap. The implementation asserts
this: the summed bin lengths must equal the number of readings per id.

## Statistics

Each named statistic becomes one channel of the output. A window may carry any subset, and the
channel order in the output is the order given by the caller.

| name | definition | defined for |
|---|---|---|
| `mean` | arithmetic mean of the readings in the bin | every window |
| `min` | smallest single reading in the bin | every window |
| `max` | largest single reading in the bin | every window |
| `cold_day` | smallest daily mean among the days in the bin | `day` and coarser |
| `warm_day` | largest daily mean among the days in the bin | `day` and coarser |

`cold_day` and `warm_day` reduce each calendar day to its own mean first and then take the extreme
over days. They are not `min` and `max`, which act on single readings, and the difference is the
point: an extreme day is a state the site was in, an extreme reading can be one hour.

At the `day` window `cold_day`, `warm_day` and `mean` coincide by construction. Requesting them
there is allowed and returns three identical channels.

## Output

A numeric array of shape `[n_id, n_bin, n_channel]`.

- Dimension 1 is named by the sorted unique ids.
- Dimension 2 is named by the ISO-8601 timestamp of each bin's start, in UTC.
- Dimension 3 is named by the statistic.

Attributes carried on the array:

| attribute | content |
|---|---|
| `window` | the window name |
| `stats` | the statistic names, in channel order |
| `year_start` | the `"MM-DD"` boundary used |
| `bin_start` | the bin start instants |
| `bin_n` | a `[id, bin]` matrix of how many readings fell in each cell |

No standardisation, centring or scaling happens here. Scaling is a property of a fit and belongs
to the fold it is computed on, never to the representation, because computing it over all ids
would leak the held-out units into the training input.

## Fixtures

`spec/fixtures/series.csv` is a synthetic three-unit, 400-day hourly series. `digests.csv` holds,
for every window-by-statistic combination and for the reported three-channel form, the digest of
the resulting array. Both test suites read the series, rebuild every combination and assert the
digests.

The digest is defined byte-exactly, because a scheme that varies by platform pins nothing:

1. Traverse the array in its own order: unit fastest, then bin, then channel.
2. Format each value with `%.12f`.
3. Join with a line feed, terminate with one, encode UTF-8.
4. MD5 of those bytes.

The line ending is LF on every platform. R's `writeLines()` emits CRLF on Windows, so the bytes
are written explicitly; a digest generated on Windows and checked on Linux must agree.

Twelve places is far below any difference that could change a fitted model and far above the
noise from the two languages accumulating a mean in different orders. Should a combination ever
straddle a rounding boundary at the twelfth place, the fix is to record that combination's
tolerance in this document, not to loosen the scheme for everything.

A digest that moves without a matching change to this document is a bug in whichever
implementation moved. Regenerating the fixtures is a deliberate act with its own commit.
