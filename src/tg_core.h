#ifndef TIMEGRAIN_TG_CORE_H
#define TIMEGRAIN_TG_CORE_H

#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <string>
#include <vector>

// The binning and the reduction, once, for both languages.
//
// Everything below works in naive local seconds: the count of seconds from 1970-01-01T00:00:00 in
// the calendar the caller wants binned, with the zone already resolved away. A day is 86400 of
// them whatever the zone did that night, a month is what the Gregorian calendar says, and no
// tzdata, no locale and no parse is reachable from here. The caller resolves the zone on the way
// in and puts it back on the way out.
namespace timegrain {

using seconds = std::int64_t;

enum class Window { hour, halfday, day, week, month, season, year, custom };
enum class Stat { mean, min, max, cold_day, warm_day, mean_daily_min, mean_daily_max };

struct YearStart {
  int month;
  int day;
};

struct Error : std::runtime_error {
  using std::runtime_error::runtime_error;
};

Window window_from_name(const std::string& name);
Stat stat_from_name(const std::string& name);
const char* window_name(Window w);
const char* stat_name(Stat s);
bool is_day_level(Stat s);

inline std::int64_t floor_div(std::int64_t a, std::int64_t b) noexcept {
  std::int64_t q = a / b;
  if ((a % b != 0) && ((a < 0) != (b < 0))) --q;
  return q;
}

inline std::int64_t floor_mod(std::int64_t a, std::int64_t b) noexcept {
  return a - floor_div(a, b) * b;
}

// Proleptic Gregorian civil arithmetic, exact over the whole int64 range and free of any parse.
// This is what replaces as.POSIXct(paste0(monday, " 00:00:00"), tz).
std::int64_t days_from_civil(std::int64_t y, unsigned m, unsigned d) noexcept;
void civil_from_days(std::int64_t z, std::int64_t& y, unsigned& m, unsigned& d) noexcept;

// "YYYY-MM-DDTHH:MM:SS", for the messages the guards raise.
std::string iso8601(seconds t);

// The start of the bin each instant falls in, and the start of the bin that follows a given one on
// the same calendar. Neither is defined for Window::custom, whose bins the caller declares.
void bin_starts(const seconds* when, std::size_t n, Window w, YearStart ys, seconds* out);
void bin_nexts(const seconds* bin_start, std::size_t n, Window w, YearStart ys, seconds* out);

// Bin membership is a function of the slot an instant falls in at the window's own granularity:
// the hour for `hour`, the half day for `halfday`, the calendar day for everything coarser. The
// reduction reads the calendar once per slot of the record rather than once per reading.
seconds window_granularity(Window w);
seconds slot_bin_start(std::int64_t slot, Window w, YearStart ys) noexcept;

struct Request {
  const std::int32_t* unit = nullptr;   // 0-based unit index, one per reading
  const double* value = nullptr;        // one per reading
  const seconds* when = nullptr;        // the true instant, one per reading; only bin_end reads it
  const seconds* local = nullptr;       // naive local seconds, one per reading
  const seconds* custom = nullptr;      // a supplied calendar's bin start per reading, else null
  const char* const* unit_name = nullptr;  // n_unit names, for the guards; may be null
  std::size_t n = 0;
  std::size_t n_unit = 0;
  Window window = Window::day;
  YearStart year_start{9, 1};
  seconds sampling_step = 0;
  std::vector<Stat> stats;
};

struct Result {
  std::vector<double> values;            // [unit, bin, channel], unit fastest, as the digest reads it
  std::vector<seconds> bin_start;        // naive local seconds, sorted distinct
  std::vector<seconds> bin_end;          // the last reading instant assigned to each bin
  std::vector<std::int32_t> bin_n;       // [unit, bin], unit fastest
  std::vector<std::uint8_t> bin_partial; // one per bin
};

// Throws Error for a (unit, bin) cell holding no readings, for a bin sequence with a hole in it,
// and for a bin shorter than a calendar day under a day-level statistic.
Result reduce(const Request& req);

}  // namespace timegrain

#endif  // TIMEGRAIN_TG_CORE_H
