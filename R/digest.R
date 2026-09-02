# The cross-language digest of a representation, defined in inst/spec/representation.md.
#
# Values are traversed in the array's own order (unit fastest, then bin, then channel), each
# formatted to twelve decimal places, one per line, LF-terminated. The LF is written explicitly
# because writeLines() emits CRLF on Windows, which would make a digest depend on the machine
# that produced it.
.digest_array <- function(x) {
  body <- paste0(paste(sprintf("%.12f", as.numeric(x)), collapse = "\n"), "\n")
  f <- tempfile()
  on.exit(unlink(f), add = TRUE)
  con <- file(f, open = "wb")
  writeBin(charToRaw(body), con)
  close(con)
  unname(tools::md5sum(f))
}
