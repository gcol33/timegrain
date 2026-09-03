#include <cpp11.hpp>

#include <cmath>
#include <string>
#include <vector>

#include "tg_core.h"

namespace {

std::vector<timegrain::seconds> as_seconds(const cpp11::doubles& x) {
  std::vector<timegrain::seconds> out(x.size());
  for (R_xlen_t i = 0; i < x.size(); ++i) {
    out[static_cast<std::size_t>(i)] =
        static_cast<timegrain::seconds>(std::floor(x[i]));
  }
  return out;
}

}  // namespace

[[cpp11::register]]
cpp11::list tg_reduce_(cpp11::integers unit, cpp11::doubles value, cpp11::doubles when,
                       cpp11::doubles local, cpp11::sexp custom, cpp11::strings unit_names,
                       std::string window, int year_month, int year_day, cpp11::strings stats,
                       double sampling_step) {
  const std::size_t n = static_cast<std::size_t>(value.size());

  std::vector<std::int32_t> unit_index(n);
  for (std::size_t i = 0; i < n; ++i) unit_index[i] = unit[static_cast<R_xlen_t>(i)] - 1;

  std::vector<double> reading(n);
  for (std::size_t i = 0; i < n; ++i) reading[i] = value[static_cast<R_xlen_t>(i)];

  const std::vector<timegrain::seconds> instant = as_seconds(when);
  const std::vector<timegrain::seconds> naive = as_seconds(local);

  std::vector<timegrain::seconds> supplied;
  if (custom != R_NilValue) supplied = as_seconds(cpp11::doubles(custom));

  std::vector<std::string> names;
  std::vector<const char*> name_ptr;
  names.reserve(static_cast<std::size_t>(unit_names.size()));
  for (R_xlen_t i = 0; i < unit_names.size(); ++i) {
    names.push_back(std::string(unit_names[i]));
  }
  name_ptr.reserve(names.size());
  for (const std::string& s : names) name_ptr.push_back(s.c_str());

  timegrain::Request req;
  req.unit = unit_index.data();
  req.value = reading.data();
  req.when = instant.data();
  req.local = naive.data();
  req.custom = supplied.empty() ? nullptr : supplied.data();
  req.unit_name = name_ptr.empty() ? nullptr : name_ptr.data();
  req.n = n;
  req.n_unit = names.size();
  req.window = timegrain::window_from_name(window);
  req.year_start = timegrain::YearStart{year_month, year_day};
  req.sampling_step = static_cast<timegrain::seconds>(sampling_step);
  for (R_xlen_t i = 0; i < stats.size(); ++i) {
    req.stats.push_back(timegrain::stat_from_name(std::string(stats[i])));
  }

  const timegrain::Result result = timegrain::reduce(req);
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

// The seven windows and the civil arithmetic under them, reachable from the suites so the oracle
// can be checked against the core rather than only through a whole reduction.
[[cpp11::register]]
cpp11::doubles tg_bin_starts_(cpp11::doubles local, std::string window, int year_month,
                              int year_day) {
  const std::vector<timegrain::seconds> naive = as_seconds(local);
  std::vector<timegrain::seconds> out(naive.size());
  timegrain::bin_starts(naive.data(), naive.size(), timegrain::window_from_name(window),
                        timegrain::YearStart{year_month, year_day}, out.data());
  cpp11::writable::doubles result(static_cast<R_xlen_t>(out.size()));
  for (std::size_t i = 0; i < out.size(); ++i) {
    result[static_cast<R_xlen_t>(i)] = static_cast<double>(out[i]);
  }
  return result;
}

[[cpp11::register]]
cpp11::doubles tg_bin_nexts_(cpp11::doubles bins, std::string window, int year_month,
                             int year_day) {
  const std::vector<timegrain::seconds> start = as_seconds(bins);
  std::vector<timegrain::seconds> out(start.size());
  timegrain::bin_nexts(start.data(), start.size(), timegrain::window_from_name(window),
                       timegrain::YearStart{year_month, year_day}, out.data());
  cpp11::writable::doubles result(static_cast<R_xlen_t>(out.size()));
  for (std::size_t i = 0; i < out.size(); ++i) {
    result[static_cast<R_xlen_t>(i)] = static_cast<double>(out[i]);
  }
  return result;
}
