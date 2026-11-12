#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
"""Reject missing or placeholder catalog verification keys before publication."""
import base64
import sys


def validate(value):
    items = value.split(',')
    if not 1 <= len(items) <= 8: raise ValueError('expected one to eight catalog keys')
    keys = [base64.b64decode(item.strip(), validate=True) for item in items]
    if any(len(key) != 32 or not any(key) for key in keys) or len(set(keys)) != len(keys):
        raise ValueError('invalid or placeholder catalog key')
    return keys


if __name__ == '__main__': validate(sys.argv[1])
