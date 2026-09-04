source("~/.R/build_pkgdown.R")

system2("python", c("tools/python_reference.py"))
pkgdown::clean_site(quiet = TRUE)
build_pkgdown_site()
