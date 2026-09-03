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

#include "cg_core.h"

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

std::vector<climgrain::Stat> parse_stats(const std::vector<std::string>& names) {
  std::vector<climgrain::Stat> out;
  out.reserve(names.size());
  for (const std::string& name : names) out.push_back(climgrain::stat_from_name(name));
  return out;
}

}  // namespace

NB_MODULE(_core, m) {
  m.doc() = "The binning and the reduction, shared with the R package as src/cg_core.cpp.";

  nb::register_exception_translator(
      [](const std::exception_ptr& p, void*) {
        try {
          std::rethrow_exception(p);
        } catch (const climgrain::Error& e) {
          PyErr_SetString(PyExc_ValueError, e.what());
        }
      });

  m.def("reduce",
        [](ConstI32 unit, ConstF64 value, ConstI64 when, ConstI64 local,
           std::optional<ConstI64> custom, const std::vector<std::string>& unit_names,
           const std::string& window, int year_month, int year_day,
           const std::vector<std::string>& stats, std::int64_t sampling_step) {
          std::vector<const char*> names;
          names.reserve(unit_names.size());
          for (const std::string& s : unit_names) names.push_back(s.c_str());

          climgrain::Request req;
          req.unit = unit.data();
          req.value = value.data();
          req.when = when.data();
          req.local = local.data();
          req.custom = custom.has_value() ? custom->data() : nullptr;
          req.unit_name = names.empty() ? nullptr : names.data();
          req.n = value.size();
          req.n_unit = unit_names.size();
          req.window = climgrain::window_from_name(window);
          req.year_start = climgrain::YearStart{year_month, year_day};
          req.sampling_step = sampling_step;
          req.stats = parse_stats(stats);

          climgrain::Result out = climgrain::reduce(req);
          std::vector<std::uint8_t> partial = std::move(out.bin_partial);
          return nb::make_tuple(give(std::move(out.values)), give(std::move(out.bin_start)),
                                give(std::move(out.bin_end)), give(std::move(out.bin_n)),
                                give(std::move(partial)));
        },
        nb::arg("unit"), nb::arg("value"), nb::arg("when"), nb::arg("local"), nb::arg("custom"),
        nb::arg("unit_names"), nb::arg("window"), nb::arg("year_month"), nb::arg("year_day"),
        nb::arg("stats"), nb::arg("sampling_step"));

  m.def("bin_starts",
        [](ConstI64 local, const std::string& window, int year_month, int year_day) {
          std::vector<climgrain::seconds> out(local.size());
          climgrain::bin_starts(local.data(), local.size(), climgrain::window_from_name(window),
                                climgrain::YearStart{year_month, year_day}, out.data());
          return give(std::move(out));
        },
        nb::arg("local"), nb::arg("window"), nb::arg("year_month"), nb::arg("year_day"));

  m.def("bin_nexts",
        [](ConstI64 bins, const std::string& window, int year_month, int year_day) {
          std::vector<climgrain::seconds> out(bins.size());
          climgrain::bin_nexts(bins.data(), bins.size(), climgrain::window_from_name(window),
                               climgrain::YearStart{year_month, year_day}, out.data());
          return give(std::move(out));
        },
        nb::arg("bins"), nb::arg("window"), nb::arg("year_month"), nb::arg("year_day"));
}
