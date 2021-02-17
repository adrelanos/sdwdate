#!/usr/bin/python3 -u

# Copyright (C) 2017 - 2020 ENCRYPTED SUPPORT LP <adrelanos@riseup.net>
# See the file COPYING for copying conditions.

import sys
sys.dont_write_bytecode = True

import re


def strip_html(message):
    # New line for log.
    tmp_message = re.sub("<br>", "\n", message)
    # Strip remaining HTML.
    return re.sub("<[^<]+?>", "", tmp_message)