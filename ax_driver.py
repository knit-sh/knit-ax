#!/usr/bin/env python3
"""
ax_driver.py — Ax BO driver for knit-ax (stub; implemented in MB3).

The driver speaks a newline-delimited JSON protocol over stdin/stdout:
  init    — initialize the Ax experiment from a search-space JSON
  resume  — reload persisted state from a file
  ask     — return n trial proposals {index, params}
  tell    — record a result {index, objective, status}
  best    — return the best {index, params, objective}
  save    — persist full state to a path
  shutdown — exit cleanly
"""
import sys

if __name__ == "__main__":
    print('{"error": "ax_driver not yet implemented (MB3)"}', flush=True)
    sys.exit(1)
