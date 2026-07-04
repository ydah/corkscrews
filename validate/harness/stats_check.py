#!/usr/bin/env python3
"""Independent smoke checks for validation statistics."""

from __future__ import annotations

import statistics


def percentile(values: list[float], pct: float) -> float:
    ordered = sorted(values)
    index = round(pct * (len(ordered) - 1))
    return ordered[index]


def main() -> int:
    values = [9.7, 10.1, 10.4, 9.9, 10.2, 10.0, 10.3, 9.8]
    mean = statistics.fmean(values)
    lo = percentile(values, 0.025)
    hi = percentile(values, 0.975)
    if not lo <= mean <= hi:
        raise SystemExit("mean is outside percentile interval")
    print({"mean": mean, "interval": [lo, hi]})
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
