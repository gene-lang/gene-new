# Pre-Cordis Harness workspace

This fixture was created with the standalone Harness kernel at commit
`6558a8f`, before the migration changed its public import paths or core
fingerprints. `manifest.json` records the exact interface hashes, file hashes,
baseline binary hash, and observations from a separate-process reopen.

It contains enabled session/workspace counters, a disabled desired entry,
content-addressed module blobs, authorship, and independently persisted state.
The counters have value 1; simply restoring registrations must not increment
them. Always test using a copy of `home/`. Never regenerate the golden fixture
with the migrated kernel or edit its CURRENT pointers or blobs.

To reproduce the old execution environment, check out the recorded commit in
an isolated checkout, build `src/gene.nim`, and run the fixture's public
seed/inspection program against a copied home. Recovery uses that verified
source/binary pair; migration publishes new compatibility metadata through CAS.
