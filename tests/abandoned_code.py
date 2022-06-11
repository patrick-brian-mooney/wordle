#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Graveyard collecting abandoned code for the Wordle exploration project.

Make it correct, then make it fast; and after it's been correctly sped up, it
winds up here, largely to document the stupid decisions so they don't get made
again, and because it contains notes explaining why the decisions didn't pan
out.

Wordle is at https://www.powerlanguage.co.uk/wordle/.

This program comes with ABSOLUTELY NO WARRANTY. Use at your own risk. It is
copyright 2022 by Patrick Mooney. It is free software, and you are welcome to
redistribute it under certain conditions, according to the GNU general public
license, either version 3 or (at your own option) any later version. See the
file LICENSE.md for details.
"""


import collections
import shelve
import time
import typing

import wordle.wordle_utils as wu
import wordle.strategies as strategies
import wordle.wordle_explorer as we


def exhaustively_analyze_with_shelve_extremely_slow() -> None:
    """For each strategy, evaluate each word that could possibly be an answer by
    starting from each possible starting word and using the strategy to solve from
    that starting word, keeping notes on moves made and how the parameters shift
    along the way.

    This is a rather slow version because dereferencing dictionaries multiple times
    inside a shelve-backed hashable is necessarily slow. Use the faster, similarly
    named exhaustively_analyze() function below, instead.

    This gets slower as the analysis of a specific strategy progresses.
    """
    for strat in strategies.Strategy.all_strategies():
        print(f'\nNow trying strategy {strat.__name__}')
        for i, solution in enumerate(wu.known_five_letter_words, 1):
            print(f"  Analyzing starting word success for solution #{i}: {solution.upper()} ...")
            with shelve.open('solutions_cache', protocol=-1, writeback=True) as db:
                if strat.__name__ not in db:
                    db[strat.__name__] = dict()
                t_start = time.monotonic()
                if solution not in db[strat.__name__]:
                    db[strat.__name__][solution] = strat.solve(solution)
                    t_done = time.monotonic()
                    print(f"    ... analyzed in {t_done - t_start} seconds!")
            try:
                t_update, _ = time.monotonic(), t_done
            except (NameError,):
                pass
            else:
                print(f"    ... database update took {t_update - t_done} seconds!")
                del t_done, t_update


def exhaustively_analyze_storing_data_with_shelve() -> None:
    """Does the same thing as exhaustively_analyze_very_slow(), above, but is much
    faster.
    
    However, getting the data back OUT of the shelve into a useful format is time-
    consuming, and takes an awful lot of memory.
    """
    def key_name(strategy: str, answer: str) -> str:
        return str((strategy, answer))

    for strat in strategies.Strategy.all_strategies():
        print(f"\nNow trying strategy {strat.__name__}")
        for i, solution in enumerate(sorted(wu.known_five_letter_words), 1):
            print(f"  Analyzing starting word success for solution #{i}: {solution.upper()} ...")
            t_open = time.monotonic()
            with shelve.open('solutions_cache', protocol=-1, writeback=True) as db:
                t_start = time.monotonic()
                print(f"    ... initializing database connection took {t_start - t_open} seconds!")
                key = key_name(strat.__name__, solution)
                if key not in db:
                    analysis, t_done = strat.solve(solution), time.monotonic()
                    print(f"    ... analyzed in {t_done - t_start} seconds!")
                    db[key], t_stash = analysis, time.monotonic()
                    print(f"    ... analysis stashed in database in {t_stash - t_done} seconds!")
            try:
                t_update, _ = time.monotonic(), t_stash
            except (NameError, ):
                pass
            else:
                print(f"    ... database update took {t_update - t_stash} seconds!")
                del t_stash, t_done, t_update


def export_shelve_db_to_bzip_files() -> None:
    # export shelved data to lrzip-compressed JSON files. Fails: needs too much memory.
    import json, sys
    import bz2

    shard_count, output = 0, dict()
    with shelve.open('solutions_cache', protocol=-1) as db:
        print("\n\nOpened database! Beginning run ...")
        for i in sorted(db):
            strategy, answer = eval(i)  # i is a stringified tuple of these two items
            if len(output) > 50:
                output_name = we.solutions_cache / f"{strategy}_{shard_count}.json.bz2"
                with bz2.open(output_name, mode="wt", encoding='utf-8') as output_file:
                    output_file.write(json.dumps(output, ensure_ascii=False, indent=None, separators=(',', ':'), sort_keys=True))
                print(f"  ... wrote {output_name} after re-packing {answer.upper()}")
                output = dict()
                shard_count += 1
            output[i] = db[i]

    sys.exit()


def export_shelve_db_to_lrzip_files() -> None:
    import json, sys
    import lrzip

    count, output = 0, dict()
    with shelve.open('solutions_cache', protocol=-1) as db:
        print("\n\nOpened database! Beginning run ...")
        for i in sorted(db):
            strategy, answer = eval(i)  # i is a stringified tuple of these two items
            if len(output) > 50:
                text_data = json.dumps(output, ensure_ascii=False, indent=None, separators=(',', ':'), sort_keys=True)
                compressed_data = lrzip.compress(text_data.encode(encoding='utf-8'), compressMode=lrzip.LRZIP_MODE_COMPRESS_ZPAQ)
                output_name = we.solutions_cache / f"{strategy}_{count}.json.lrz"
                (output_name).write_bytes(compressed_data)
                print(f"  ... wrote {output_name} after re-packing {answer.upper()}")
                count += 1

                del text_data, compressed_data
                output = dict()
            output[i] = db[i]

    sys.exit()


def enumerate_solutions_slow(possible: typing.Dict[int, str],
                             ambiguous_pos: str) -> typing.Tuple[collections.Counter, typing.Set[str]]:
    """Given POSSIBLE and AMBIGUOUS_POS, generate a list of words in the known words
    list that might be the word we're looking for, i.e. don't violate the currently
    known constraints.

    POSSIBLE is a dictionary mapping positions 1, 2, 3, 4, 5 to a string containing
    letters that might be in that position, AMBIGUOUS_POS is a string containing
    letters we know to be in the word but for which we haven't yet finalized the
    placement.

    Does not make any effort to rank the possible answers yet.

    Along the way, generates a Counter that maps letters in the words that might be
    the answer we're looking for to how often those letters occur in the possibility
    set.

    Returns a Set of maybe-words and the Counter mapping the letters in those words
    to their frequency in the maybe-words.

    #FIXME: there's a good chance this would be faster if we used regex-based
    matching instead of nested loops.

    #YEP: This takes 400 times longer, on average, than the regex-based solution
    actually used. That's where it got its present name.
    """
    possible_answers = set()

    num_found = 0
    for c1 in possible[1]:
        for c2 in possible[2]:
            for c3 in possible[3]:
                for c4 in possible[4]:
                    for c5 in possible[5]:
                        word = c1 + c2 + c3 + c4 + c5
                        if word not in wu.known_five_letter_words:
                            continue
                        if any([c not in word for c in ambiguous_pos]):
                            continue

                        num_found += 1
                        possible_answers.add(word)

    letter_frequencies = collections.Counter(''.join(possible_answers))
    return letter_frequencies, possible_answers
