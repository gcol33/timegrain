#include "ts_core.h"

#include <algorithm>
#include <cmath>
#include <limits>

namespace timesift {

namespace {

constexpr seconds kDay = 86400;

// Beyond this the slot table stops being the cheap way round and the readings are binned one by
// one instead. A record has to span some 1,900 years hourly, or 45,000 years daily, to reach it.
constexpr std::int64_t kMaxSlots = 1 << 24;

struct Grouping {
  std::vector<seconds> bins;          // sorted distinct bin starts
  std::vector<std::int32_t> bin_of;   // one per reading
};

std::string name_of(const Request& req, std::size_t unit) {
  if (req.unit_name != nullptr && req.unit_name[unit] != nullptr) {
    return std::string(req.unit_name[unit]);
  }
  return std::to_string(unit + 1);
}

std::string plural(std::size_t n, const char* word) {
  return std::to_string(n) + " " + word + (n == 1 ? "" : "s");
}

// Bins whose starts the caller supplied, or whose slots span more of the calendar than a table can
// hold: sort the distinct starts and look each reading up in them.
Grouping group_by_search(const seconds* start, std::size_t n) {
  Grouping out;
  out.bins.assign(start, start + n);
  std::sort(out.bins.begin(), out.bins.end());
  out.bins.erase(std::unique(out.bins.begin(), out.bins.end()), out.bins.end());
  out.bin_of.resize(n);
  for (std::size_t i = 0; i < n; ++i) {
    out.bin_of[i] = static_cast<std::int32_t>(
        std::lower_bound(out.bins.begin(), out.bins.end(), start[i]) - out.bins.begin());
  }
  return out;
}

// Bin membership is a function of the slot alone, so the calendar is read once per slot the record
// touches and every reading is then an array lookup.
Grouping group_by_grain(const seconds* local, std::size_t n, Grain w, YearStart ys) {
  const seconds g = grain_granularity(w);
  std::int64_t lo = floor_div(local[0], g);
  std::int64_t hi = lo;
  for (std::size_t i = 1; i < n; ++i) {
    const std::int64_t s = floor_div(local[i], g);
    if (s < lo) lo = s;
    if (s > hi) hi = s;
  }
  const std::int64_t span = hi - lo + 1;
  if (span > kMaxSlots) {
    std::vector<seconds> start(n);
    bin_starts(local, n, w, ys, start.data());
    return group_by_search(start.data(), n);
  }

  std::vector<std::int32_t> slot_bin(static_cast<std::size_t>(span), -1);
  for (std::size_t i = 0; i < n; ++i) {
    slot_bin[static_cast<std::size_t>(floor_div(local[i], g) - lo)] = -2;
  }

  Grouping out;
  seconds last = 0;
  std::int32_t index = -1;
  for (std::int64_t s = 0; s < span; ++s) {
    if (slot_bin[static_cast<std::size_t>(s)] != -2) continue;
    const seconds bs = slot_bin_start(lo + s, w, ys);
    if (index < 0 || bs != last) {
      out.bins.push_back(bs);
      last = bs;
      ++index;
    }
    slot_bin[static_cast<std::size_t>(s)] = index;
  }

  out.bin_of.resize(n);
  for (std::size_t i = 0; i < n; ++i) {
    out.bin_of[i] = slot_bin[static_cast<std::size_t>(floor_div(local[i], g) - lo)];
  }
  return out;
}

// Every unit must reach every bin. A cell that no reading falls in is a record that stops early or
// starts late, and padding it would put an invented value in front of a model.
void check_full_grid(const std::vector<std::int32_t>& count, const std::vector<seconds>& bins,
                     const Request& req) {
  const std::size_t n_unit = req.n_unit;
  std::size_t empty = 0;
  std::size_t first = 0;
  for (std::size_t c = 0; c < count.size(); ++c) {
    if (count[c] == 0) {
      if (empty == 0) first = c;
      ++empty;
    }
  }
  if (empty == 0) return;
  throw Error(plural(empty, "(unit, bin) cell") + " hold no readings, first: unit " +
              name_of(req, first % n_unit) + " at " + iso8601(bins[first / n_unit]) +
              ". Every unit must span every bin; gaps are not padded.");
}

// The bins have to tile the record. What the empty-cell guard cannot see is a bin the whole record
// skips, because a bin no unit reaches is never built: a February missing from every logger gives
// four "adjacent" monthly bins with February simply gone, and a convolution then reads January and
// March as neighbours.
void check_contiguous(const std::vector<seconds>& bins, const Request& req) {
  if (bins.size() < 2) return;
  std::vector<seconds> next(bins.size());
  bin_nexts(bins.data(), bins.size(), req.grain, req.year_start, next.data());
  for (std::size_t k = 0; k + 1 < bins.size(); ++k) {
    if (next[k] == bins[k + 1]) continue;
    throw Error(std::string("the ") + grain_name(req.grain) +
                " bins are not contiguous: nothing falls in the one beginning " +
                iso8601(next[k]) + ", between " + iso8601(bins[k]) + " and " +
                iso8601(bins[k + 1]) + ". Bins must tile the record; a gap is not closed up.");
  }
}

}  // namespace

Result reduce(const Request& req) {
  const std::size_t n = req.n;
  const std::size_t n_unit = req.n_unit;
  if (n == 0) throw Error("no readings to reduce.");
  if (n_unit == 0) throw Error("no units to reduce.");
  if (req.stats.empty()) throw Error("no statistic to compute.");
  if (req.grain == Grain::custom && req.custom == nullptr) {
    throw Error("a supplied calendar must give a bin start for every reading.");
  }

  // A supplied calendar declares its bins, and the `native` grain is the record unreduced, so in
  // both the bin start is already in hand and the distinct ones are read off it directly. Every
  // other grain is a function of the slot an instant falls in.
  const Grouping grid =
      req.grain == Grain::custom ? group_by_search(req.custom, n)
      : req.grain == Grain::native ? group_by_search(req.local, n)
                                   : group_by_grain(req.local, n, req.grain, req.year_start);
  const std::vector<seconds>& bins = grid.bins;
  const std::vector<std::int32_t>& bin_of = grid.bin_of;
  const std::size_t n_bin = bins.size();
  const std::size_t n_cell = n_unit * n_bin;

  std::vector<std::int32_t> count(n_cell, 0);
  for (std::size_t i = 0; i < n; ++i) {
    const std::int32_t u = req.unit[i];
    if (u < 0 || static_cast<std::size_t>(u) >= n_unit) {
      throw Error("a reading carries a unit index outside the units given.");
    }
    count[static_cast<std::size_t>(bin_of[i]) * n_unit + static_cast<std::size_t>(u)] += 1;
  }
  check_full_grid(count, bins, req);

  // A supplied calendar owns its own bin lengths, and the `native` grain's bin is the reading
  // itself, so in neither case can the calendar say what a bin between two others would have been.
  if (req.grain != Grain::custom && req.grain != Grain::native) {
    check_contiguous(bins, req);
  }

  bool need_day = false;
  bool need_sum = false, need_min = false, need_max = false;
  bool need_day_mean = false, need_day_min = false, need_day_max = false;
  for (Stat s : req.stats) {
    switch (s) {
      case Stat::mean: need_sum = true; break;
      case Stat::min: need_min = true; break;
      case Stat::max: need_max = true; break;
      case Stat::cold_day: case Stat::warm_day: need_day_mean = true; break;
      case Stat::mean_daily_min: need_day_min = true; break;
      case Stat::mean_daily_max: need_day_max = true; break;
    }
    need_day = need_day || is_day_level(s);
  }

  const double inf = std::numeric_limits<double>::infinity();
  std::vector<double> sum, low, high;
  if (need_sum) sum.assign(n_cell, 0.0);
  if (need_min) low.assign(n_cell, inf);
  if (need_max) high.assign(n_cell, -inf);

  for (std::size_t i = 0; i < n; ++i) {
    const std::size_t c = static_cast<std::size_t>(bin_of[i]) * n_unit +
                          static_cast<std::size_t>(req.unit[i]);
    const double v = req.value[i];
    if (need_sum) sum[c] += v;
    if (need_min && v < low[c]) low[c] = v;
    if (need_max && v > high[c]) high[c] = v;
  }

  // The day-level stage: reduce every (unit, calendar day) to its own mean, minimum and maximum,
  // then reduce again over the days of a bin. That second reduction is what keeps an extreme day
  // distinct from an extreme reading.
  std::vector<double> day_low, day_high, day_min_sum, day_max_sum;
  std::vector<std::int32_t> n_day;
  if (need_day) {
    const Grouping calendar = group_by_grain(req.local, n, Grain::day, req.year_start);
    const std::size_t n_days = calendar.bins.size();

    std::vector<std::int32_t> day_bin(n_days, -1);
    const std::size_t n_dcell = n_unit * n_days;
    std::vector<std::int32_t> dcount(n_dcell, 0);
    std::vector<double> dsum(n_dcell, 0.0);
    std::vector<double> dlow(need_day_min ? n_dcell : 0, inf);
    std::vector<double> dhigh(need_day_max ? n_dcell : 0, -inf);

    for (std::size_t i = 0; i < n; ++i) {
      const std::int32_t d = calendar.bin_of[i];
      if (day_bin[d] < 0) {
        day_bin[d] = bin_of[i];
      } else if (day_bin[d] != bin_of[i]) {
        std::string which;
        std::size_t named = 0;
        for (Stat s : req.stats) {
          if (!is_day_level(s)) continue;
          if (!which.empty()) which += " and ";
          which += stat_name(s);
          ++named;
        }
        which += named == 1 ? " needs" : " need";
        throw Error(which + " bins of a calendar day or coarser: the day beginning " +
                    iso8601(calendar.bins[d]) + " is split between the bins beginning " +
                    iso8601(bins[day_bin[d]]) + " and " + iso8601(bins[bin_of[i]]) + ".");
      }
      const std::size_t c = static_cast<std::size_t>(d) * n_unit +
                            static_cast<std::size_t>(req.unit[i]);
      const double v = req.value[i];
      dcount[c] += 1;
      dsum[c] += v;
      if (need_day_min && v < dlow[c]) dlow[c] = v;
      if (need_day_max && v > dhigh[c]) dhigh[c] = v;
    }

    // Walked in day-cell order, so the days of a bin are summed oldest first and the mean of the
    // daily extremes accumulates in the same order in both languages.
    n_day.assign(n_cell, 0);
    if (need_day_mean) {
      day_low.assign(n_cell, inf);
      day_high.assign(n_cell, -inf);
    }
    if (need_day_min) day_min_sum.assign(n_cell, 0.0);
    if (need_day_max) day_max_sum.assign(n_cell, 0.0);

    for (std::size_t c = 0; c < n_dcell; ++c) {
      if (dcount[c] == 0) continue;
      const std::size_t cell = static_cast<std::size_t>(day_bin[c / n_unit]) * n_unit +
                               (c % n_unit);
      n_day[cell] += 1;
      if (need_day_mean) {
        const double m = dsum[c] / dcount[c];
        if (m < day_low[cell]) day_low[cell] = m;
        if (m > day_high[cell]) day_high[cell] = m;
      }
      if (need_day_min) day_min_sum[cell] += dlow[c];
      if (need_day_max) day_max_sum[cell] += dhigh[c];
    }
  }

  Result out;
  out.values.assign(n_cell * req.stats.size(), 0.0);
  for (std::size_t k = 0; k < req.stats.size(); ++k) {
    double* channel = out.values.data() + k * n_cell;
    switch (req.stats[k]) {
      case Stat::mean:
        for (std::size_t c = 0; c < n_cell; ++c) channel[c] = sum[c] / count[c];
        break;
      case Stat::min:
        for (std::size_t c = 0; c < n_cell; ++c) channel[c] = low[c];
        break;
      case Stat::max:
        for (std::size_t c = 0; c < n_cell; ++c) channel[c] = high[c];
        break;
      case Stat::cold_day:
        for (std::size_t c = 0; c < n_cell; ++c) channel[c] = day_low[c];
        break;
      case Stat::warm_day:
        for (std::size_t c = 0; c < n_cell; ++c) channel[c] = day_high[c];
        break;
      case Stat::mean_daily_min:
        for (std::size_t c = 0; c < n_cell; ++c) channel[c] = day_min_sum[c] / n_day[c];
        break;
      case Stat::mean_daily_max:
        for (std::size_t c = 0; c < n_cell; ++c) channel[c] = day_max_sum[c] / n_day[c];
        break;
    }
  }

  out.bin_start = bins;
  out.bin_n.assign(count.begin(), count.end());
  out.bin_end.assign(n_bin, std::numeric_limits<seconds>::min());
  for (std::size_t i = 0; i < n; ++i) {
    const std::size_t b = static_cast<std::size_t>(bin_of[i]);
    if (req.when[i] > out.bin_end[b]) out.bin_end[b] = req.when[i];
  }

  // Which bins the record does not cover for their whole calendar span. The record covers from its
  // first reading to its last plus one sampling interval, and a bin is partial when its own span
  // reaches outside that. Only a bin at an end of the record can, because every unit has already
  // been required to hold readings in every bin between them. A supplied calendar declares where
  // its bins begin but not where the last one was meant to end, so that one is taken to end with
  // the record and is never partial.
  seconds covered_start = req.local[0];
  seconds covered_end = req.local[0];
  for (std::size_t i = 1; i < n; ++i) {
    if (req.local[i] < covered_start) covered_start = req.local[i];
    if (req.local[i] > covered_end) covered_end = req.local[i];
  }
  covered_end += req.sampling_step;

  std::vector<seconds> next(n_bin);
  if (req.grain == Grain::custom || req.grain == Grain::native) {
    for (std::size_t k = 0; k + 1 < n_bin; ++k) next[k] = bins[k + 1];
    if (n_bin > 0) next[n_bin - 1] = covered_end;
  } else {
    bin_nexts(bins.data(), n_bin, req.grain, req.year_start, next.data());
  }
  out.bin_partial.assign(n_bin, 0);
  for (std::size_t k = 0; k < n_bin; ++k) {
    out.bin_partial[k] = (bins[k] < covered_start || next[k] > covered_end) ? 1 : 0;
  }

#ifndef NDEBUG
  // min <= mean_daily_min <= mean <= mean_daily_max <= max, and min <= cold_day <= mean <=
  // warm_day <= max, both of which follow from the definitions.
  if (need_min && need_sum) {
    for (std::size_t c = 0; c < n_cell; ++c) {
      const double m = sum[c] / count[c];
      if (low[c] > m + 1e-9) throw Error("min above the mean at cell " + std::to_string(c) + ".");
      if (need_day_min && day_min_sum[c] / n_day[c] < low[c] - 1e-9) {
        throw Error("mean_daily_min below the min at cell " + std::to_string(c) + ".");
      }
      if (need_day_mean && day_low[c] < low[c] - 1e-9) {
        throw Error("cold_day below the min at cell " + std::to_string(c) + ".");
      }
    }
  }
#endif

  return out;
}

}  // namespace timesift
