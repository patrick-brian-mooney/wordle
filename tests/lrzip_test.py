#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""A quick test that plays with the lrzip liprary in pip.

This program comes with ABSOLUTELY NO WARRANTY. Use at your own risk. It is
copyright 2022 by Patrick Mooney. It is free software, and you are welcome to
redistribute it under certain conditions, according to the GNU general public
license, either version 3 or (at your own option) any later version. See the
file LICENSE.md for details.
"""


import json
import shelve

from pathlib import Path

import lrzip                        # https://pypi.org/project/lrzip/

import text_generator as tg         # https://github.com/patrick-brian-mooney/markov-sentence-generator

if __name__ == "__main__":
    out_dir = Path(__file__).parent

    genny = tg.TextGenerator(training_texts=[Path("/lovecraft/corpora/In the Vault.txt"), Path("/lovecraft/corpora/previous/The Alchemist.txt")], markov_length=3)
    text = genny.gen_text(sentences_desired=300)
    (out_dir / 'text_output.txt').write_text(text, encoding='utf-8')

    data = lrzip.compress(text.encode(encoding='utf-8'), compressMode=lrzip.LRZIP_MODE_COMPRESS_ZPAQ)
    (out_dir / 'compressed_output.lrz').write_bytes(data)

    print('\n\nDone!')
