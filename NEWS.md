# timegrain 0.0.0.9000

Development version. Nothing is released yet.

## Representation

* `window_matrix()`: reduces a long table of sensor readings to a `[unit, bin, channel]` array at
  one of seven temporal grains, from the unreduced record to a single value per hydrological year.
* Bins follow the calendar, so a month is 28, 30 or 31 days and a week starts on a Monday, and the
  bins are asserted to tile the record with no gap and no overlap.
* Five statistics: `mean`, `min`, `max`, and the day-level `cold_day` and `warm_day`, which reduce
  each day to its own mean before taking the extreme over days.
* Gaps, duplicated `(unit, time)` pairs and missing values are errors rather than silent padding.

## The cross-language contract

* `spec/representation.md` is normative for both the R and the Python implementation.
* `spec/fixtures/` carries a synthetic series and the digest of every window-by-statistic
  combination; both test suites assert against the same digests.
