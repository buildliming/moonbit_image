#!/usr/bin/env python3
"""Compatibility entry point for independent photographic reference tests.

The former generator copied MoonBit's actual checksums into expected values,
which could silently preserve decoder bugs. Expected pixels now come solely
from Pillow and the embedded fixture bytes; no MoonBit output is consulted.
"""
from generate_photo_references import main

if __name__ == "__main__":
    main()
