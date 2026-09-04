#include <nanobind/nanobind.h>
#include <nanobind/ndarray.h>
#include <nanobind/stl/optional.h>
#include <nanobind/stl/string.h>
#include <nanobind/stl/vector.h>

#include <cstdint>
#include <exception>
#include <optional>
#include <string>
#include <vector>

#include "ts_core.h"

namespace nb = nanobind;

namespace {

using ConstI32 = nb::ndarray<const std::int32_t, nb::ndim<1>, nb::c_contig, nb::device::cpu>;
using ConstI64 = nb::ndarray<const std::int64_t, nb::ndim<1>, nb::c_contig, nb::device::cpu>;
using ConstF64 = nb::ndarray<const double, nb::ndim<1>, nb::c_contig, nb::device::cpu>;

// Hands a vector to NumPy and lets the capsule free it when the array goes.
template <typename T>
nb::ndarray<nb::numpy, T> give(std::vector<T>&& from) {
  auto* held = new std::vector<T>(std::move(from));
  nb::capsule owner(held, [](void* p) noexcept { delete static_cast<std::vector<T>*>(p); });
  const std::size_t shape[1] = {held->size()};
  return nb::ndarray<nb::numpy, T>(held->data(), 1, shape, owner);
}

std::vector<timesift::Stat> parse_stats(const std::vector<std::string>& names) {
  std::vector<timesift::Stat> out;
  out.reserve(names.size());
  for (const std::string& name : names) out.push_back(timesift::stat_from_name(name));
  return out;
}

}  // namespace

NB_MODULE(_core, m) {
  m.doc() = "The binning and the reduction, shared with the R package as src/ts_core.cpp.";

  nb::register_exception_translator(
      [](const std::exception_ptr& p, void*) {
        try {
          std::rethrow_exception(p);
        } catch (const timesift::Error& e) {
          PyErr_SetString(PyExc_ValueError, e.what());
        }
      });

  m.def("reduce",
        [](ConstI32 unit, ConstF64 value, ConstI64 when, ConstI64 local,
           std::optional<ConstI64> custom, const std::vector<std::string>& unit_names,
           const std::string& grain, int year_month, int year_day,
           const std::vector<std::string>& stats, std::int64_t sampling_step) {
          std::vector<const char*> names;
          names.reserve(unit_names.size());
          for (const std::string& s : unit_names) names.push_back(s.c_str());

          timesift::Request req;
          req.unit = unit.data();
          req.value = value.data();
          req.when = when.data();
          req.local = local.data();
          req.custom = custom.has_value() ? custom->data() : nullptr;
          req.unit_name = names.empty() ? nullptr : names.data();
          req.n = value.size();
          req.n_unit = unit_names.size();
          req.grain = timesift::grain_from_name(grain);
          req.year_start = timesift::YearStart{year_month, year_day};
          req.sampling_step = sampling_step;
          req.stats = parse_stats(stats);

          timesift::Result out = timesift::reduce(req);
          std::vector<std::uint8_t> partial = std::move(out.bin_partial);
          return nb::make_tuple(give(std::move(out.values)), give(std::move(out.bin_start)),
                                give(std::move(out.bin_end)), give(std::move(out.bin_n)),
                                give(std::move(partial)));
        },
        nb::arg("unit"), nb::arg("value"), nb::arg("when"), nb::arg("local"), nb::arg("custom"),
        nb::arg("unit_names"), nb::arg("grain"), nb::arg("year_month"), nb::arg("year_day"),
        nb::arg("stats"), nb::arg("sampling_step"));

  m.def("reduce_windows",
        [](ConstI32 unit, ConstF64 value, ConstI64 local,
           const std::vector<std::string>& unit_names, ConstI32 target_unit, ConstI64 target_at,
           const std::vector<std::string>& target_names, std::int64_t span, std::int64_t lag,
           std::int32_t bins, const std::vector<std::string>& stats) {
          std::vector<const char*> units, targets;
          units.reserve(unit_names.size());
          for (const std::string& s : unit_names) units.push_back(s.c_str());
          targets.reserve(target_names.size());
          for (const std::string& s : target_names) targets.push_back(s.c_str());

          timesift::WindowRequest req;
          req.unit = unit.data();
          req.value = value.data();
          req.local = local.data();
          req.n = value.size();
          req.n_unit = unit_names.size();
          req.target_unit = target_unit.data();
          req.target_at = target_at.data();
          req.target_name = targets.empty() ? nullptr : targets.data();
          req.n_target = target_at.size();
          req.span = span;
          req.lag = lag;
          req.n_bin = bins;
          req.stats = parse_stats(stats);

          timesift::WindowResult out = timesift::reduce_windows(req);
          return nb::make_tuple(give(std::move(out.values)), give(std::move(out.bin_n)));
        },
        nb::arg("unit"), nb::arg("value"), nb::arg("local"), nb::arg("unit_names"),
        nb::arg("target_unit"), nb::arg("target_at"), nb::arg("target_names"), nb::arg("span"),
        nb::arg("lag"), nb::arg("bins"), nb::arg("stats"));

  m.def("bin_starts",
        [](ConstI64 local, const std::string& grain, int year_month, int year_day) {
          std::vector<timesift::seconds> out(local.size());
          timesift::bin_starts(local.data(), local.size(), timesift::grain_from_name(grain),
                                timesift::YearStart{year_month, year_day}, out.data());
          return give(std::move(out));
        },
        nb::arg("local"), nb::arg("grain"), nb::arg("year_month"), nb::arg("year_day"));

  m.def("bin_nexts",
        [](ConstI64 bins, const std::string& grain, int year_month, int year_day) {
          std::vector<timesift::seconds> out(bins.size());
          timesift::bin_nexts(bins.data(), bins.size(), timesift::grain_from_name(grain),
                               timesift::YearStart{year_month, year_day}, out.data());
          return give(std::move(out));
        },
        nb::arg("bins"), nb::arg("grain"), nb::arg("year_month"), nb::arg("year_day"));
}
