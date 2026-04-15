#!/usr/bin/env python3
"""
# [Is there a way of reading the last element of an array with bash?](https://unix.stackexchange.com/a/198788)
# [How to find the last field using 'cut'](https://stackoverflow.com/a/22727211)
╰─ echo $(timeout 10 \
yt-dlp \
    --force-overwrites \
    -f bestvideo+bestaudio \
    -N 1 \
    --newline \
    --no-warnings \
    -o /tmp/speedtest_youtube \
    https://youtu.be/8cOJhLM66D4 \
| python compute_average_download_biterate.py) \
| rev | cut -d' ' -f 1 | rev
20.51820512820514
"""
import re
import sys
from humanfriendly import parse_size

REGEX = r"\[download\][ ]{1,}(?P<percent>\d+(?:\.\d+)?)%[ ]{1,}of[ ]{1,}(?P<total_size>[.0-9]+.iB)[ ]{1,}at[ ]{1,}(?P<dl_rate>[.0-9]+.iB)\/s"

number_of_samples = 1
old_average = 0

# https://stackoverflow.com/questions/17658512/how-to-pipe-input-to-python-line-by-line-from-linux-program
for line in sys.stdin:
    # sys.stdout.write(f"[python] {line}")
    matches = re.finditer(REGEX, line, re.MULTILINE)
    for match in matches:
        percent = float(match.group("percent"))
        total_size = match.group("total_size")
        # https://humanfriendly.readthedocs.io/en/latest/api.html?highlight=format_size#humanfriendly.parse_size
        dl_rate = round(parse_size(match.group("dl_rate")) / 1024 / 1024, 2)

        # https://en.wikipedia.org/wiki/Moving_average
        # https://stackoverflow.com/questions/12636613/how-to-calculate-moving-average-without-keeping-the-count-and-data-total
        new_average = old_average * \
            (number_of_samples - 1) / number_of_samples + \
            dl_rate / number_of_samples
        old_average = new_average
        number_of_samples += 1

        # sys.stdout.write(f"{percent=} {total_size=} {dl_rate=}\n")
        sys.stdout.write(f"{new_average}\n")
    sys.stdout.flush()
