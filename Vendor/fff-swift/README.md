# Vendored FFFKit wrapper

This directory contains the Swift wrapper sources from `fff-swift` 0.2.1.
Floodlight vendors the wrapper so it can explicitly allow its documented
home-directory search scope while continuing to use the unchanged, checksummed
`CFFF.xcframework` binary published with that release.

The local change is intentionally limited to the
`enableHomeDirectoryScanning` initializer option and its regression test.
