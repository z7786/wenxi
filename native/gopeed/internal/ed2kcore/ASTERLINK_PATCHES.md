# Embedded Kelpie core

Source: https://github.com/XiaoYouChR/Kelpie
Commit: c3c475a917036900d6c6b4c5597f6b896e9ec2d6 (retrieved 2026-11-01).
License: MIT; see LICENSE and NOTICE, including upstream goed2k and BSD notices.

The engine is compiled into the existing Gopeed Android / Windows runtime.
No Python, separate process, hosted downloader, or third-party link resolver is used.
Production code is compatible with the project's Go 1.24.7 toolchain. Upstream
tests use Go 1.25 testing/synctest and are kept in the local research checkout.

Changes from upstream:

- Import paths relocated under internal/ed2kcore.
- Engine Config accepts caller-provided storage and disk interfaces so AsterLink
  can keep network identity, credits and transfer checkpoints in encrypted
  Gopeed storage and use process-local Android output descriptor bindings.
- AsterLink's Gopeed fetcher manages observed runs, waiting for every writer to
  stop before releasing a descriptor or deleting a task.
- Checkpoints are acknowledged through the single saver queue, preventing
  queued snapshots from overwriting a removal or a newer pause checkpoint.
- File-close failures propagate to the caller. Output bindings lock and drain
  writes before close, and reject late disk jobs.
- Explicit link sources may reach local IPv4 endpoints and connect while
  discovery is offline; discovered sources retain the public-address filter.
- Link parsing bounds length, validates file terminators, UTF-8 escaping and
  control characters. Resume state must match the file size and logical path.
- Progress includes a monotonic network-byte counter, separately from disk
  progress, so restored or rechecked bytes do not inflate Gopeed's speed.

The upstream server and Kad protocol behavior, MD4 / AICH verification, source
exchange, credits, upload queue and transfer algorithms are preserved.
