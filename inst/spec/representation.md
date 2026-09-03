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

## Ordering identifiers

Every place an identifier decides a position -- the ids naming the first dimension of the
representation, and the variable names naming the cells of the scorable mask -- they are sorted by
**C collation**: the byte order of the UTF-8 encoding, which for every code point is also the code
point order. It does not depend on the session's locale, on the machine, or on the language.

That has to be stated because the two languages' defaults disagree and so do two R sessions in
different locales. R's `sort()` follows `LC_COLLATE`, which in an English locale orders `_z` before
`a` before `A`, and NumPy's `np.unique()` orders by code point, which puts `A` first. Both
implementations therefore name the rule rather than take a default: R passes
`method = "radix"`, which sorts characters in the C locale whatever `LC_COLLATE` says, and NumPy
already sorts this way.

The failure this prevents is silent rather than loud. Two orderings hold the same numbers in
different rows, so a response matrix built in one language and a representation built in the other
line up row for row while naming different units, and nothing errors. `series_order.csv` carries
ids the two rules order differently, so the fixtures fail rather than the user.

The channel names are never sorted: the channel order is the order the caller named the statistics
in.

## The time zone

Bin membership is decided from the calendar the series is carried in, so the zone has to be named
before anything is binned. It is named once, at the edge of each implementation, and nothing below
that edge knows a zone exists: the binning and the reduction see only *naive local seconds*, the
count of seconds from 1970-01-01T00:00:00 on that calendar. A day there is 86400 of them whatever
the night did, and a month is what the proleptic Gregorian calendar says.

| | how the zone is named |
|---|---|
| R | the `tzone` attribute of the `POSIXct` column; unset means UTC |
| Python | the `tz` argument; `None`, the default, means the instants already read as the calendar to bin by, which is what a zone-free `datetime64` says |

The same instants and the same zone give the same answer in both languages, and the fixtures pin
that rather than leaving it assumed.

Reading an instant as a clock is defined for every instant in every zone. The reverse is not: on
the night a zone moves its clock forward a local time exists on no instant, and on the night it
moves back a local time exists on two. A bin start is a local time, so reporting it as an instant
needs a rule, and the rule is that **a local time the clock skipped resolves to the instant the
clock jumped to, and a local time the clock repeated resolves to the first of the two**. In
`America/Sao_Paulo`, whose clock moved at midnight until 2019, the day beginning 4 November 2018
therefore opens at 01:00 local rather than at a midnight that never happened, and holds 23 readings
rather than 24.

Instants are read at whole seconds. Two readings a fraction of a second apart are the same reading
twice, and are reported as a duplicated `(id, time)` pair.

## Windows

Bin membership is read from the calendar rather than from a running count of hours, so a bin is a
real week or a real month rather than a drifting block of 168 or 730 hours.

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

Bins are contiguous and cover the record with no gap and no overlap, and both halves of that are
asserted:

- every `(id, bin)` cell holds at least one reading, which is what makes a bin the same span for
  every id and a record that stops early an error rather than a padded row;
- consecutive bin starts are one bin apart on the window's own calendar. A bin no id reaches is
  never built, so a February missing from every logger would otherwise give four "adjacent" monthly
  bins with February simply gone, and a convolution would read January and March as neighbours.

The second is not asserted for `hour`, where the bin is the reading itself and the bin sequence is
the record's own sampling grid rather than a calendar, nor for a supplied calendar, which declares
its own bin lengths and is contiguous by construction. It is asserted in local time, so a sequence
stepping across a clock change is contiguous: the civil day a zone shortened is still one bin of
one calendar day.

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

"A day or coarser" is decided from the bins rather than from the window's name: a day-level
statistic requires every calendar day of the record to lie entirely inside one bin. Naming `hour`
or `halfday` is refused before any data is read; a supplied calendar that cuts inside a day is
refused once the bins are in hand, naming the day it splits and the two bins it splits it between.

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
| `bin_start` | the bin start instants, resolved from local time as **The time zone** describes |
| `bin_end` | the last reading instant assigned to each bin |
| `bin_n` | a `[id, bin]` matrix of how many readings fell in each cell |
| `bin_partial` | a logical vector marking the bins the record does not cover for their whole calendar span |

No standardisation, centring or scaling happens here. Scaling is a property of a fit and belongs
to the fold it is computed on, never to the representation, because computing it over all ids
would leak the held-out units into the training input.

## What crosses the language boundary, and what does not

The binning and the reduction are one implementation: `src/cg_core.cpp` and `src/cg_calendar.cpp`,
compiled into the R package by R itself and into the Python extension by CMake. What each language
holds above it is the boundary, which resolves the columns, resolves the zone and wraps the result.
The two agree by construction rather than by two implementations being checked against each other
after the fact.

The digests did not stop meaning anything when that happened. The implementations they used to
compare are kept as test oracles, `tests/testthat/helper-oracle.R` and `python/tests/oracle.py`,
reachable from neither package at runtime and exercised only against the core on the fixtures and
on random series. The NumPy one was written from this document rather than from the R source, which
is what makes it evidence that the document is complete. One implementation in production, two in
evidence.

The representation is normative and is checked byte-exactly. Three things beside it are artifacts
that both sides read rather than each side computing: the response matrix, the fold map, and the
mask of scorable cells that follows from those two. A fold map built from a seed in R and a fold
map built from the same seed in Python are different maps, because the two languages draw on
different random streams; the fix is not to align the streams but to build the map once and read
it in the other language. **The file format below is what makes that possible**, and both sides
carry the reader and the writer for all three.

A model fitted in one language and a model fitted in the other cannot be byte-identical and are
not required to be.

## The file format of the three artifacts

One format for all three: CSV, UTF-8, a header row, `,` as the separator, no quoting, and LF line
endings on every platform. Written the same way in either language, the same artifact gives the
same bytes, so a round trip through a file is checkable and is checked.

A number is written with `%.12g`: twelve significant digits, which renders `0` and `1` as `0` and
`1` and carries any measurement a response holds. A logical is written `TRUE` or `FALSE`, and is
read from either that or `1`/`0`.

### The fold map: `id,fold`

| column | type | |
|---|---|---|
| `id` | character | the unit |
| `fold` | integer | the fold it is held out in, from 1 |

One row per unit, ordered by the id under **Ordering identifiers**. A unit may appear once.

### The response matrix: `id` and one column per variable

| column | type | |
|---|---|---|
| `id` | character | the unit |
| each remaining column | numeric | that variable's value at that unit |

The columns after `id` are the variables, **in the file's own order**, which is the order the
response carries them in; they are not sorted, because a response's column order is the caller's.
Rows are ordered by the id. A presence-absence response holds `0` and `1` and nothing else, and is
checked for that when it is prepared rather than when it is read.

### The scorable mask: `variable,fold,n_occ,pres_train,abs_train,pres_test,abs_test,scorable`

One row per `(variable, fold)` cell, ordered by variable under **Ordering identifiers** and then
by fold ascending. The seven columns after `variable` are integers except `scorable`, which is a
logical. The mask is a pure function of the response and the fold map, so it can be recomputed
rather than carried; it is written because reading it is how a language that did not build it gets
the exact cells the other one scored on.

### A unit the file does not carry

Aligning any of the three to a representation's units is by name, never by position. A unit in the
representation that the file has no row for is an error, reporting how many are missing and naming
the first of them in the representation's own order. A unit the file carries that the
representation does not is dropped without comment: a fold map covering a whole study is a normal
thing to read a subset of.

## Fixtures

Three series, because a record that starts on a bin boundary cannot tell two binning rules apart
and a record in UTC cannot tell two readings of a zone apart.
`spec/fixtures/series.csv` is a synthetic three-unit, 400-day hourly series beginning at midnight
on the default anniversary, so every coarse window is in phase with it from the first reading.
`series_offset.csv` is a two-unit, 200-day series beginning at 05:00 on 17 October, which is what
a logger deployed when someone could walk to it gives, and puts every window out of phase.
`series_zoned.csv` is a two-unit, 10-day series across 4 November 2018, the night
`America/Sao_Paulo` moved its clock at midnight, which is the record that tells a calendar read by
arithmetic apart from one read by writing a local midnight and parsing it back. `seasons.csv` holds
the equinox and solstice boundaries that make each series a caller-supplied calendar, which is the
only path the manuscript's seasonal rung ever took.

`digests.csv` holds one row per series, window, time zone, `year_start`, `partial` setting and
statistic, covering every window-by-statistic combination, each of the three-channel schemes
(`min+mean+max`, `mean_daily_min+mean+mean_daily_max`, `cold_day+mean+warm_day`), the coarse
windows at anniversaries other than the default, both `partial` settings, the supplied calendar,
and the zone: every window of the aligned series read as a `Europe/Vienna` clock, which moves twice
inside that record, and the short series read as an `America/Sao_Paulo` clock, which moves at
midnight inside it, including a `year_start` landing on the night it moves. Each row carries `n_unit`, `n_bin`, the first and last bin start, how many bins are
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

## What else is pinned

The representation is not the only deterministic thing the two languages share, and a contract
that pinned it alone would let everything above it drift. Four more fixtures, generated by the same
script and read by both suites:

`response.csv`, `folds.csv` and `cells.csv` hold one response of 40 units by 6 variables, a fold
map of five folds over it, and the mask that follows. The variable names order differently under
C collation and under an English locale, and the prevalences are chosen so the mask is not all
`TRUE`: one variable is present nowhere and one everywhere, so neither has a scorable cell at all,
and a rare one is scorable in some folds and not others. Both suites read the response and the
fold map, recompute the mask, and assert it cell by cell. Both also write all three back and
assert the bytes, which is what makes the file format a contract rather than a convention.

`metric_cases.csv` and `metrics.csv` hold ten `(y, p)` cases and the value of every threshold
metric on each: `tss`, `roc_auc`, `kappa` under both rules, and `decision_threshold` under all
three. The cases are where the tie rule is the whole answer -- every prediction tied, ties within
a class, ties across the classes, one presence, one absence, all presences, all absences, a
perfect separation and a reversed one. A metric a case defines no value on is written `NA` rather
than left out, so a suite that quietly skipped it fails rather than passes.

`contrast_cells.csv` and `contrast.csv` hold a fixed table of per-cell scores for two arms, with
cells one arm scored and the other did not, and the paired contrast read off it. No model is
involved: the pairing, the per-variable mean and the signed-rank p-value are what the two
languages own, and a fitted model is what they are not required to share.

### How exactly

Everything named above is **byte-exact**, at the twelve significant digits the format writes. It
is arithmetic on the same finite inputs in both languages, so anything less would be a difference
worth finding rather than a tolerance worth allowing. The one exception is the signed-rank
p-value: it is exact where the exact distribution applies, which is fewer than fifty values with
no tie, and the Python side reaches the normal approximation beyond that through a Chebyshev fit
to the complementary error function accurate to about 1.2e-7 relative. The fixture stays on the
exact branch; where a caller lands on the other, the two agree to 1e-6 and no closer.

`tss_inflation()` cannot be pinned as a digest, because it draws replicates from each language's
own random stream, and aligning those streams would be the wrong fix for the same reason it is the
wrong fix for a fold map. Its inflation figure is a headline claim of the package, so what is
required of it is stated rather than left to a hand check: **at 200 replicates the two
implementations agree on the inflation to within 0.02 at each planted skill**, which is well
inside the Monte Carlo error of either one alone and far below the +0.110 the claim rests on. A
disagreement beyond that is a bug in one of them, not sampling.

## What each language carries

The representation and the three artifacts are the contract. Everything built over them is meant to
match too, and where the two sides differ the difference is recorded here rather than found at a
call site.

### One name per concept

| concept | the name, on both sides |
|---|---|
| the penalised learner | `elasticnet_learner()` |
| the forward selector | `stepwise_learner()` |
| a set of representations | `climgrain_set()`, which reads as a mapping of window name to representation |
| folds of the inner cross-validation | `n_inner` |
| the digest | `digest_array()`, exported |
| the three registries | `register_learner()` and `learners()`, `register_metric()` and `metrics()`, `register_response()` and `responses()` |

### The same call does the same thing

- Naming one window returns the representation and naming two or more returns a set, whether the
  one is named as a string or as a sequence of one.
- `window_ladder()` and `select_grain()` left without a fold map build one with the defaults of
  `fold_map()`. The two languages draw different maps from the same seed, so where both must see
  one split, write it and read it back as the section above describes.
- Held-out predictions are placed by unit and by variable, never by position.
- A setting given at fit time overrides the one the learner carries, and a setting the learner does
  not have is refused rather than ignored.
- The response head and the metric are registry entries. `metric` takes a registered name or a
  function of `(y, p)`, and left unset it is the one the response head carries.
- The encoders take `swa` and `swa_start`: the schedule anneals until the averaging begins and is
  then held flat, the averaged weights get their own pass to rebuild the batch-normalisation
  statistics, and the default is off, so a default recipe is the same recipe on both sides.
- `select_grain()` searches the candidates in the order the windows and the learners were declared
  in, so which candidate an exact tie on the inner score falls to does not depend on how the names
  sort.

### Present in one language only

| in R only | why |
|---|---|
| `window_contrasts()` | fits a mixed model over the whole ladder and reads Dunnett's comparisons off it, on lme4, lmerTest and emmeans. The Python twin would need a mixed-model fitter of its own or a scientific stack the wheel does not depend on, and nothing in the contract reads it. |
| `simulate_records()` | generates a record with a planted grain, for the vignette and the recovery tests. The Python suite builds its records in its own fixtures. |
| `plot()` on a ladder and on a selection | the wheel depends on numpy alone, and every number a plot draws is on the object it is called on. |

| in Python only | what it is |
|---|---|
| `flatten`, `align_folds`, `as_response`, `get_learner`, `cohen_kappa` | the helpers R keeps unexported, as `.flatten()`, `.as_folds()`, `.as_response()`, `.as_learner()` and `.kappa_table()`. A Python module namespace is flat, and anyone writing a learner or reading an artifact against this side reaches them. |

Models are the one thing neither side promises. A fit in torch and a fit in libtorch cannot be
byte-identical, and the encoders match module for module rather than number for number.
