# BlitzClean

For changes to visible UI, interactions, or product copy, read [docs/DESIGN.md](docs/DESIGN.md).
Verify changed screens in the running macOS app as well as compiling them.

When you delete files on this Mac by hand, write a report to
`~/Library/Application Support/BlitzClean/reports/storage-cleanup-YYYYMMDD-HHMMSS.json` with
`{"started": {"at": <unix>}, "removed": [{"path", "allocatedBytes", "freeBefore", "freeAfter", "time"}]}`.
BlitzClean imports it into its removal log and offers Remove again when the folder regrows.
