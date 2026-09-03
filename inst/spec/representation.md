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
year and therefore also the phase of the seasonal bins. A seasonal bin is three calendar months
counted from that anniversary, so a record of three hydrological years beginning on it holds
twelve of them and no partial one. Cutting seasons anywhere else, at the equinoxes and solstices
for instance, is a different calendar and is passed as a function; see Custom bins.

Bins are contiguous and cover the record with no gap and no overlap. What is asserted is that
every `(id, bin)` cell holds at least one reading, which is what makes a bin the same span for
every id and a record that stops early an error rather than a padded row.

## Partial bins

A bin is **partial** when the record does not cover its whole calendar span. The record covers
from its first reading to its last plus one sampling interval, taken as the smallest gap between
consecutive distinct reading instants, and a bin is partial when its own span reaches outside
that. Only a bin at an end of the record can, because every id is required to hold readings in
every bin between them.

Which bins those are follows from where the record starts and stops against the calendar, not from
the window alone. Three years of hourly readings from 1 September on a `"09-01"` boundary carry no
partial month, season or year, and a partial week at each end, because 1 September 2021 is a
Wednesday. A record from an arbitrary deployment date carries one at each end of almost every
window.

`window_matrix()` reports the verdict as `bin_partial` and takes a `partial` argument saying what
becomes of such a bin: `"keep"`, the default, returns it alongside the full bins; `"drop"` removes
it, and errors rather than returning an empty representation if that leaves no bin. Dropping is a
choice about the record, not about the implementation: it discards up to three months of readings
at each end of a seasonal window, while keeping gives a bin whose mean is taken over fewer readings
and whose `cold_day` and `warm_day` are drawn from fewer days, so they sit closer to that bin's
mean than a full bin's would. `bin_n` gives the count each bin was reduced from.

Both implementations obey the same rule and the fixtures pin both settings.

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

Such a calendar owns its own bin lengths. A record beginning inside one of its seasons gives a
leading bin of a few weeks beside neighbours of three months, and that is the calendar the caller
asked for rather than a bin the record failed to fill: it is what makes three years cut at the
equinoxes thirteen bins where three calendar months from `"09-01"` are twelve. The function
declares where its bins begin, so the package cannot know where the last one was meant to end and
takes the record's end as its end; that final bin is never reported partial, and a leading bin is
judged as any other.

The function must return a bin start for every reading, including any that precede its first
boundary. Deciding that with an interval lookup is the natural way to write one and the two
languages disagree below the first boundary, where R's `findInterval()` gives 0 and NumPy's
`searchsorted() - 1` gives -1: the first silently shortens the result, which is an error, and the
second silently wraps to the last boundary, which is not. Either put the first boundary at or
before the record's first reading, as the fixtures do, or handle the readings below it explicitly.

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
| `bin_partial` | a logical vector marking the bins the record does not cover for their whole calendar span |

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

Two series, because a record that starts on a bin boundary cannot tell two binning rules apart.
`spec/fixtures/series.csv` is a synthetic three-unit, 400-day hourly series beginning at midnight
on the default anniversary, so every coarse window is in phase with it from the first reading.
`series_offset.csv` is a two-unit, 200-day series beginning at 05:00 on 17 October, which is what
a logger deployed when someone could walk to it gives, and puts every window out of phase.
`seasons.csv` holds the equinox and solstice boundaries that make each series a caller-supplied
calendar, which is the only path the manuscript's seasonal rung ever took.

`digests.csv` holds one row per series, window, `year_start`, `partial` setting and statistic,
covering every window-by-statistic combination, each of the three-channel schemes
(`min+mean+max`, `mean_daily_min+mean+mean_daily_max`, `cold_day+mean+warm_day`), the coarse
windows at anniversaries other than the default, both `partial` settings, and the supplied
calendar. Each row carries `n_unit`, `n_bin`, the first and last bin start, how many bins are
partial, and the digest.

Both test suites read the series, rebuild every row and assert all of it. The shape is asserted
before the digest, so two implementations that put the record into a different number of bins are
reported as that rather than as an unexplained hash mismatch. A contract that carried one series
starting on the anniversary, at the default anniversary, with no supplied calendar and no bin
count beside the hash would pass while the two sides disagreed on how many seasons three years
hold, which is the whole thing it exists to prevent.

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
