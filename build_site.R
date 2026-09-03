source("~/.R/build_pkgdown.R")

system2("python", c("tools/python_reference.py"))
build_pkgdown_site()
