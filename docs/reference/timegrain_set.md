# A ladder of representations, one per window

Naming several windows in
[`window_matrix()`](https://gillescolling.com/timegrain/reference/window_matrix.md)
returns one of these: a named list of representations of the same units,
differing only in how coarsely the record was read. It is what
[`window_ladder()`](https://gillescolling.com/timegrain/reference/window_ladder.md)
fits across.

## Usage

``` r
timegrain_set(x)
```

## Arguments

- x:

  A named list of
  [`window_matrix()`](https://gillescolling.com/timegrain/reference/window_matrix.md)
  results, or a single one.

## Value

A `timegrain_set`: the list, with the names as window labels.

## Examples

``` r
t <- seq(as.POSIXct("2021-09-01", tz = "UTC"), by = "hour", length.out = 24 * 60)
d <- data.frame(plot = rep(c("a", "b"), each = length(t)), t = rep(t, 2),
                temp = rnorm(2 * length(t)))
s <- window_matrix(d, plot, t, temp, window = c("day", "week", "month"))
s
names(s)
```
