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
| `mean_daily_min` | mean over the bin's days of each day's smallest reading | `day` and coarser |
| `mean_daily_max` | mean over the bin's days of each day's largest reading | `day` and coarser |

The four day-level statistics reduce each calendar day first and then reduce again over the days of
the bin. `cold_day` and `warm_day` take the extreme of the daily means; `mean_daily_min` and
`mean_daily_max` take the mean of the daily extremes. They are not `min` and `max`, which act on
single readings, and the difference is the point: an extreme day is a state the site was in, an
extreme reading can be one hour, and an average daily extreme is the exposure a typical day of the
bin brought.

Two orderings follow from the definitions and are asserted:
`min <= mean_daily_min <= mean <= mean_daily_max <= max` and
`min <= cold_day <= mean <= warm_day <= max`. The two day-level pairs are not ordered against each
other, and a bin whose days differ widely in level is where they part: a bin of one day at 0 and
one at 10 has `cold_day` 0 and `mean_daily_min` 5.

At the `day` window `cold_day`, `warm_day` and `mean` coincide by construction, as do
`mean_daily_min` with `min` and `mean_daily_max` with `max`. Requesting them there is allowed and
returns the identical channels.

## Custom bins

A caller may supply the binning instead of naming a window, as a function of the reading instants
returning the start of each reading's bin. Everything downstream is unchanged: the bins are still
required to tile the record, and the output still carries the bin starts as its second dimension's
names. This is how a calendar the package does not carry is used, such as seasons cut at the
equinoxes and solstices rather than on the first of a month.

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
| `bin_end` | the last reading instant assigned to each bin |
| `bin_n` | a `[id, bin]` matrix of how many readings fell in each cell |

No standardisation, centring or scaling happens here. Scaling is a property of a fit and belongs
to the fold it is computed on, never to the representation, because computing it over all ids
would leak the held-out units into the training input.

## What crosses the language boundary, and what does not

The representation is normative and is checked byte-exactly. Three things beside it are artifacts
that both sides read rather than each side computing: the response matrix, the fold map, and the
mask of scorable cells that follows from those two. A fold map built from a seed in R and a fold
map built from the same seed in Python are different maps, because the two languages draw on
different random streams; the fix is not to align the streams but to build the map once and read
it in the other language.

A model fitted in one language and a model fitted in the other cannot be byte-identical and are
not required to be.

## Fixtures

`spec/fixtures/series.csv` is a synthetic three-unit, 400-day hourly series. `digests.csv` holds,
for every window-by-statistic combination and for each of the three-channel schemes
(`min+mean+max`, `mean_daily_min+mean+mean_daily_max`, `cold_day+mean+warm_day`), the digest of
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
