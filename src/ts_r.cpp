#include <cpp11.hpp>

#include <cmath>
#include <string>
#include <vector>

#include "ts_core.h"

namespace {

std::vector<timesift::seconds> as_seconds(const cpp11::doubles& x) {
  std::vector<timesift::seconds> out(x.size());
  for (R_xlen_t i = 0; i < x.size(); ++i) {
    out[static_cast<std::size_t>(i)] =
        static_cast<timesift::seconds>(std::floor(x[i]));
  }
  return out;
}

}  // namespace

[[cpp11::register]]
cpp11::list ts_reduce_(cpp11::integers unit, cpp11::doubles value, cpp11::doubles when,
                       cpp11::doubles local, cpp11::sexp custom, cpp11::strings unit_names,
                       std::string grain, int year_month, int year_day, cpp11::strings stats,
                       double sampling_step) {
  const std::size_t n = static_cast<std::size_t>(value.size());

  std::vector<std::int32_t> unit_index(n);
  for (std::size_t i = 0; i < n; ++i) unit_index[i] = unit[static_cast<R_xlen_t>(i)] - 1;

  std::vector<double> reading(n);
  for (std::size_t i = 0; i < n; ++i) reading[i] = value[static_cast<R_xlen_t>(i)];

  const std::vector<timesift::seconds> instant = as_seconds(when);
  const std::vector<timesift::seconds> naive = as_seconds(local);

  std::vector<timesift::seconds> supplied;
  if (custom != R_NilValue) supplied = as_seconds(cpp11::doubles(custom));

  std::vector<std::string> names;
  std::vector<const char*> name_ptr;
  names.reserve(static_cast<std::size_t>(unit_names.size()));
  for (R_xlen_t i = 0; i < unit_names.size(); ++i) {
    names.push_back(std::string(unit_names[i]));
  }
  name_ptr.reserve(names.size());
  for (const std::string& s : names) name_ptr.push_back(s.c_str());

  timesift::Request req;
  req.unit = unit_index.data();
  req.value = reading.data();
  req.when = instant.data();
  req.local = naive.data();
  req.custom = supplied.empty() ? nullptr : supplied.data();
  req.unit_name = name_ptr.empty() ? nullptr : name_ptr.data();
  req.n = n;
  req.n_unit = names.size();
  req.grain = timesift::grain_from_name(grain);
  req.year_start = timesift::YearStart{year_month, year_day};
  req.sampling_step = static_cast<timesift::seconds>(sampling_step);
  for (R_xlen_t i = 0; i < stats.size(); ++i) {
    req.stats.push_back(timesift::stat_from_name(std::string(stats[i])));
  }

  const timesift::Result result = timesift::reduce(req);
  const std::size_t n_bin = result.bin_start.size();

  cpp11::writable::doubles values(static_cast<R_xlen_t>(result.values.size()));
  for (std::size_t i = 0; i < result.values.size(); ++i) {
    values[static_cast<R_xlen_t>(i)] = result.values[i];
  }
  cpp11::writable::doubles bin_start(static_cast<R_xlen_t>(n_bin));
  cpp11::writable::doubles bin_end(static_cast<R_xlen_t>(n_bin));
  cpp11::writable::logicals bin_partial(static_cast<R_xlen_t>(n_bin));
  for (std::size_t k = 0; k < n_bin; ++k) {
    bin_start[static_cast<R_xlen_t>(k)] = static_cast<double>(result.bin_start[k]);
    bin_end[static_cast<R_xlen_t>(k)] = static_cast<double>(result.bin_end[k]);
    bin_partial[static_cast<R_xlen_t>(k)] =
        result.bin_partial[k] ? TRUE : FALSE;
  }
  cpp11::writable::integers bin_n(static_cast<R_xlen_t>(result.bin_n.size()));
  for (std::size_t i = 0; i < result.bin_n.size(); ++i) {
    bin_n[static_cast<R_xlen_t>(i)] = result.bin_n[i];
  }

  using namespace cpp11::literals;
  return cpp11::writable::list({
    "values"_nm = values,
    "bin_start"_nm = bin_start,
    "bin_end"_nm = bin_end,
    "bin_n"_nm = bin_n,
    "bin_partial"_nm = bin_partial
  });
}

[[cpp11::register]]
cpp11::list ts_reduce_lookbacks_(cpp11::integers unit, cpp11::doubles value, cpp11::doubles local,
                               cpp11::strings unit_names, cpp11::integers target_unit,
                               cpp11::doubles target_at, cpp11::strings target_names,
                               double span, double lag, int bins, cpp11::strings stats) {
  const std::size_t n = static_cast<std::size_t>(value.size());
  const std::size_t n_target = static_cast<std::size_t>(target_at.size());

  std::vector<std::int32_t> unit_index(n);
  for (std::size_t i = 0; i < n; ++i) unit_index[i] = unit[static_cast<R_xlen_t>(i)] - 1;

  std::vector<double> reading(n);
  for (std::size_t i = 0; i < n; ++i) reading[i] = value[static_cast<R_xlen_t>(i)];

  const std::vector<timesift::seconds> naive = as_seconds(local);
  const std::vector<timesift::seconds> anchor = as_seconds(target_at);

  std::vector<std::int32_t> holder(n_target);
  for (std::size_t i = 0; i < n_target; ++i) {
    holder[i] = target_unit[static_cast<R_xlen_t>(i)] - 1;
  }

  std::vector<std::string> units, targets;
  for (R_xlen_t i = 0; i < unit_names.size(); ++i) units.push_back(std::string(unit_names[i]));
  for (R_xlen_t i = 0; i < target_names.size(); ++i) {
    targets.push_back(std::string(target_names[i]));
  }
  std::vector<const char*> unit_ptr, target_ptr;
  for (const std::string& s : units) unit_ptr.push_back(s.c_str());
  for (const std::string& s : targets) target_ptr.push_back(s.c_str());

  timesift::LookbackRequest req;
  req.unit = unit_index.data();
  req.value = reading.data();
  req.local = naive.data();
  req.n = n;
  req.n_unit = units.size();
  req.target_unit = holder.data();
  req.target_at = anchor.data();
  req.target_name = target_ptr.empty() ? nullptr : target_ptr.data();
  req.n_target = n_target;
  req.span = static_cast<timesift::seconds>(span);
  req.lag = static_cast<timesift::seconds>(lag);
  req.n_bin = bins;
  for (R_xlen_t i = 0; i < stats.size(); ++i) {
    req.stats.push_back(timesift::stat_from_name(std::string(stats[i])));
  }

  const timesift::LookbackResult result = timesift::reduce_lookbacks(req);

  cpp11::writable::doubles values(static_cast<R_xlen_t>(result.values.size()));
  for (std::size_t i = 0; i < result.values.size(); ++i) {
    values[static_cast<R_xlen_t>(i)] = result.values[i];
  }
  cpp11::writable::integers bin_n(static_cast<R_xlen_t>(result.bin_n.size()));
  for (std::size_t i = 0; i < result.bin_n.size(); ++i) {
    bin_n[static_cast<R_xlen_t>(i)] = result.bin_n[i];
  }

  using namespace cpp11::literals;
  return cpp11::writable::list({"values"_nm = values, "bin_n"_nm = bin_n});
}

// The seven grains and the civil arithmetic under them, reachable from the suites so the oracle
// can be checked against the core rather than only through a whole reduction.
[[cpp11::register]]
cpp11::doubles ts_bin_starts_(cpp11::doubles local, std::string grain, int year_month,
                              int year_day) {
  const std::vector<timesift::seconds> naive = as_seconds(local);
  std::vector<timesift::seconds> out(naive.size());
  timesift::bin_starts(naive.data(), naive.size(), timesift::grain_from_name(grain),
                        timesift::YearStart{year_month, year_day}, out.data());
  cpp11::writable::doubles result(static_cast<R_xlen_t>(out.size()));
  for (std::size_t i = 0; i < out.size(); ++i) {
    result[static_cast<R_xlen_t>(i)] = static_cast<double>(out[i]);
  }
  return result;
}

[[cpp11::register]]
cpp11::doubles ts_bin_nexts_(cpp11::doubles bins, std::string grain, int year_month,
                             int year_day) {
  const std::vector<timesift::seconds> start = as_seconds(bins);
  std::vector<timesift::seconds> out(start.size());
  timesift::bin_nexts(start.data(), start.size(), timesift::grain_from_name(grain),
                       timesift::YearStart{year_month, year_day}, out.data());
  cpp11::writable::doubles result(static_cast<R_xlen_t>(out.size()));
  for (std::size_t i = 0; i < out.size(); ++i) {
    result[static_cast<R_xlen_t>(i)] = static_cast<double>(out[i]);
  }
  return result;
}
