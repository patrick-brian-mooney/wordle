#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Sequentially tries all possible Wordle words as starting guesses relative to
each possible "correct answer," then plays out the remainder of the round using
a variety of strategies, tracking how each starting word/strategy combination
performs across the whole problem set. Since each strategy needs to evaluate
each starting word relative to each answer, the strategies each need to try
5,331,481 (2309 * 2309 -- there are 2309 Wordle words) combinations.

Wordle is at https://www.powerlanguage.co.uk/wordle/.

This program comes with ABSOLUTELY NO WARRANTY. Use at your own risk. It is
copyright 2022 by Patrick Mooney. It is free software, and you are welcome to
redistribute it under certain conditions, according to the GNU general public
license, either version 3 or (at your own option) any later version. See the
file LICENSE.md for details.
"""


import abc
import bz2
import collections
import functools
import gc
import heapq
import json
import math
import numpy as np
import numbers
import pickle
import reprlib
import statistics
import time
import threading
import typing

from pathlib import Path

import pandas as pd
import pyximport; pyximport.install()       # http://cython.org

import wordle_utils as wu
import strategies


solutions_cache = Path(__file__).parent / 'solutions'
max_entries_in_shard = 25


class FairLimitedHeap(collections.abc.Iterable):
    """A heap implemented using the heapq module that has a limited size. The size
    limit is a "soft" or "fair" limit: it tries to keep SOFT_LIMIT items (if at
    least that many items have been added to the heap in the first place), but will
    keep more if the worst-scored items all score equally poorly. So, for instance,
    pushing a single new item onto a heap that has exactly SOFT_LIMIT items will not
    delete a single item from the bottom of the heap if multiple items at the bottom
    of the heap all have the same low score.

    For instance, if there is a heap of 100 items, and the soft limit is 100, and
    the four lowest-ranked items all have the same low score, then:

    * Pushing an item scoring above that low score will increase the size of the
      heap to 101, because none of the items with the low score has a score any
      lower than any of the others, so none of them is removed; and
    * pushing another item scoring above that low score will increase the size of
      the heap to 102, for that same reason; same with pushing another item with a
      score above that low score, which will increase the heap size to 103; and
    * pushing a fourth item above that low score will add the item to the heap,
      temporarily increasing the size of the heap to 104 before removing all four of
      the equally low-scoring items and taking the heap size down to 100.

    The score of items must be manually specified when adding an item to the heap.
    Items added to the heap must be orderable for this to work. Internally, the heap
    is a list of (score, item) tuples, and rely on Python's short-circuiting of
    tuple comparisons to keep the heap sorted. (The fact that items with identical
    scores will be ordered based on the ordering of the items being stored both
    implies that the heap does not preserve insertion order for same-scored items
    and is the reason why items scored must be orderable.)
    """
    def __init__(self, soft_limit: int = 100,
                 initial: typing.Iterable = ()) -> None:
        """If INITIAL is specified, it must be an iterable of (value, item) tuples.
        """
        if initial:
            for item, _ in initial:
                assert isinstance(item, numbers.Number)
        self._soft_limit = soft_limit
        self._data = [][:]
        for item, value in initial:
            self.push(value, item)

    def __str__(self) -> str:
        return f"< {self.__class__.__name__} object, with {len(self._data)} items having priorities from {self._data[0][0]} to {self._data[-1][0]} >"

    def __repr__(self) -> str:
        """Limit how many items are displayed in the __repr__ by using reprlib.
        """
        return f"{self.__class__.__name__} ({reprlib.repr(self._data)})"

    def __eq__(self, other) -> bool:
        if type(self) != type(other):
            return False
        return self._data == other._data

    def __bool__(self) -> bool:
        return bool(self._data)

    def __iter__(self) -> typing.Iterator:
        return iter(self._data)

    def __len__(self) -> int:
        return len(self._data)

    def __getitem__(self, item) -> typing.Any:
        return self._data[item][1]               # return only the item's VALUE, not its SCORE.

    def push(self, item: typing.Any,
              value: numbers.Number) -> None:
        heapq.heappush(self._data, (value, item))
        if len(self._data) <= self._soft_limit:
            return

        # Find the index of the item after last item in the heap with same VALUE as the item at the low end of the heap
        for index, item in enumerate(self._data):
            if index == 0:
                comp_value = item[0]
            elif item[0] != comp_value:     # exact equality good enough, even if difference is tiny.
                break

        if (len(self._data) - index) >= self._soft_limit:
             for i in range(index):
                 heapq.heappop(self._data)

    def pop(self, also_return_score: bool = False) -> typing.Any:
        if also_return_score:
            return heapq.heappop(self._data)
        else:
            return heapq.heappop(self._data[1])

    def as_sorted_list(self, include_values: bool = False) -> typing.List[typing.Tuple[numbers.Number, typing.Any]]:
        """Returns the contents of the heap in sorted-by-priority order. If
        INCLUDE_VALUES is True (not the default), returns a set of (value, item)
        tuples instead of just the items.
        """
        if include_values:
            return sorted(self._data)
        else:
            return [i[1] for i in sorted(self._data)]


def key_name(strategy: str, answer: str) -> str:
    """Convert this data pairing into a key that can be used to index a database in any
    of several forms that we've tried keeping the database in.
    """
    return str((strategy, answer))


def power_of_two_equal_to_or_greater_than(than_what: numbers.Number) -> int:
    """If THAN_WHAT is a power of two, returns it. Otherwise, return the next power of
    two greater than THAN_WHAT.
    """
    exp = int(math.log(than_what, 2))
    if float(2 ** exp) == float(than_what):
        return than_what
    else:
        return 2 ** (1 + exp)


@functools.lru_cache(maxsize=power_of_two_equal_to_or_greater_than(len(wu.known_five_letter_words)))
def strategy_name_from_key(key: str) -> str:
    """A key name is a stringified (strategy name, answer) tuple. Process that tuple
    to extract the strategy name and return it.
    """
    return key.strip().strip('()').strip().split(',')[0].strip().strip("'").strip()


@functools.lru_cache(maxsize=power_of_two_equal_to_or_greater_than(len(wu.known_five_letter_words)))
def answer_name_from_key(key: str) -> str:
    """A key name is a stringified (strategy name, answer) tuple. Process that tuple
    to extract the strategy name and return it.
    """
    return key.strip().strip('()').strip().split(',')[1].strip().strip("'").strip()


def was_already_analyzed(strategy: strategies.Strategy) -> bool:
    """Return True if this Strategy has already had an analysis performed on it that
    resulted in summary data.
    """
    allow_sloppy_detection = True  # debugging only!
    if allow_sloppy_detection:
        num_shards_needed = (len(wu.known_five_letter_words) // max_entries_in_shard) if ((len(wu.known_five_letter_words) % max_entries_in_shard) == 0) else 1 + (len(wu.known_five_letter_words) // max_entries_in_shard)
        if len(list(solutions_cache.glob(f"{strategy.__name__}.pkl.lrz"))) == num_shards_needed:
            return True
    return (solutions_cache / f"{strategy.__name__}_analysis.json.bz2").is_file()


def get_shard_data(shard_path: Path) -> typing.Dict[str, dict]:
    """Unpack a shard and do first-pass summarization on it, returning the dictionary
    that results from the summarizing activity and containing much of the
    """
    gc.collect()                # Big chunks of data involved here.
    ret = dict()
    t_start = time.monotonic()
    with bz2.open(shard_path, mode='rb') as shard_file:
        unpacked_shard = pickle.load(shard_file)
    print(f"    ... unpacked shard {shard_path.name}, containing {len(unpacked_shard)} items, in {time.monotonic() - t_start} seconds")
    t_after_unpacking = time.monotonic()
    for answer, data in unpacked_shard.items():
        ret[answer] = {
            'solutions': {k: [{
                'move': i.Move,
                'initial possible letters': i.InitialPossibleLetters,
                'known letters with unknown position before guess': i.KnownLettersWithUnknownPositionBeforeGuess,
                'possible letters after guess': i.PossibleLettersAfterGuess,
                'remaining possibilities': i.RemainingPossibilities,
                'exhausted erroneously': i.ExhaustedErroneously,
                'solved': i.Solved,
            } for i in v] for k, v in data['solutions'].items()},
            'average moves': data['average moves'] if ('average moves' in data) else None,
            'number solved': data['number solved'] if ('number solved' in data) else None,
            'number of errors': data['number of errors'] if ('number of errors' in data) else None,
        }

    # Try to avoid letting huge shards collect in memory
    del unpacked_shard
    gc.collect()
    print(f"      ... re-packed data in {time.monotonic() - t_after_unpacking} seconds")

    return ret


@functools.lru_cache(maxsize=power_of_two_equal_to_or_greater_than(len(wu.known_five_letter_words)))
def get_word_index(word: str) -> int:
    """Given WORD, a word in the list of known five-letter words that are Wordle
    solutions, return its position in the list, where the position is going to be in
    the range 0 <= pos < len(wu.known_five_letter_words).
    """
    assert word in wu.known_five_letter_words
    return sorted(wu.known_five_letter_words).index(word)


def summarize_analysis(strategy: strategies.Strategy) -> None:
    """Iterate back over the data we've generated, decompressing it and totalling up
    relevant stats, then saving the summary to disk and deleting the huge shards of
    compressed data.
    """
    print(f"  ... summarizing strategy {strategy.__name__} ...")
    relevant_shards = sorted(solutions_cache.glob(f"{strategy.__name__}*.pkl.bz2"))

    t_begin_whole_process = time.monotonic()
    output = {
        'strategy': strategy.__name__,
        'total errors': 0,
        'total moves': 0,
    }
    solution_length_matrix = pd.DataFrame(np.empty((len(wu.known_five_letter_words), len(wu.known_five_letter_words)),
                                                   dtype=np.float64),       # Need a float type to get real NaN values
                                          index = sorted(wu.known_five_letter_words),
                                          columns = sorted(wu.known_five_letter_words))
    solution_length_matrix[:] = np.nan

    for current_shard_path in relevant_shards:
        current_shard = get_shard_data(current_shard_path)
        output['total errors'] += sum([i['number of errors'] for i in current_shard.values()])
        output['total moves'] += sum([sum([len(m) for m in sol['solutions'].values()]) for sol in current_shard.values()])
        for answer in current_shard:
            for first_guess in current_shard[answer]['solutions']:
                if current_shard[answer]['solutions'][first_guess][-1]['solved']:
                    # Indexing a Pandas DataFrame is, counterintuitively perhaps, ['column']['row'], not the reverse.
                    # Columns are initial guesses, rows are the solution to a set.
                    # So the number at ['agape']['liver'] is the number of moves it took to get to 'liver', starting at 'agape'.
                    solution_length_matrix[first_guess][answer_name_from_key(answer)] = len(current_shard[answer]['solutions'][first_guess])
    print(f"  ... unpacked and summarized all shards in {time.monotonic() - t_begin_whole_process} seconds!")

    solution_matrix_filename = solutions_cache / f"{strategy.__name__}_solution_matrix.csv.bz2"
    print(f"  ... saving solution length matrix {solution_matrix_filename} ...")
    solution_length_matrix.to_csv(solution_matrix_filename, na_rep='NULL')

    output.update({'total solved': solution_length_matrix.count().sum(),
                   'total unsolved': (len(wu.known_five_letter_words) ** 2) - solution_length_matrix.count().sum(),
                   'median moves': solution_length_matrix.stack().median(),
                   'mean moves': solution_length_matrix.stack().mean(),
                   })

    # All right, now compute the best and worst starting guesses, overall. Starting guesses are in columns.
    # "Worst" guesses are computed with an arithmetic inverse of the average score because the heap keeps "high" values.
    worst_initial_guesses, best_initial_guesses = FairLimitedHeap(100), FairLimitedHeap(100)
    non_solutions = list()

    for col in solution_length_matrix:
        avg = solution_length_matrix[col].mean()
        worst_initial_guesses.push(col, avg)
        best_initial_guesses.push(col, -avg)

        non_sols = len(solution_length_matrix) - solution_length_matrix[col].count()
        if non_sols:
            non_solutions.append((col, non_sols))
    output.update({
        'best starting words': [(-v, i) for v, i in best_initial_guesses.as_sorted_list(include_values=True)],
        'worst starting words': worst_initial_guesses.as_sorted_list(include_values=True)[:-1],
        "starting words that end in non-solutions sometimes": non_solutions or None
    })

    with bz2.open(solutions_cache / f"{strategy.__name__}_analysis.json.bz2", mode='wt') as summary_file:
        json.dump(output, summary_file, ensure_ascii=False, indent=2, sort_keys=True, default=str)

    for current_shard_path in relevant_shards:
        try:
            current_shard_path.unlink()
        except (IOError,) as errrr:
            print(f"      Warning! Unable to delete shard {current_shard_path.name}! The system said: {errrr}.")

    print(f"  ... finished summarizing, writing to disk, and cleaning up!\n")


def save_shard(output, strat_name, shard_count, last_solution_processed) -> None:
    """Meant to be spun off into a thread to allow the main process to continue. Can
    be run directly if convenient, though.
    """
    t_start = time.monotonic()
    output_name = solutions_cache / f"{strat_name}_{shard_count:05d}.pkl.bz2"
    with bz2.open(output_name, mode='wb') as output_file:
        output_file.write(pickle.dumps(output, protocol=-1))
    print(f"  ... took {time.monotonic() - t_start} seconds to compress and write {output_name} after processing {last_solution_processed.upper()}")


def exhaustively_analyze() -> None:
    """Go through each known strategy, collecting data while using the strategy to
    attempt to derive each possibly solution from each possible starting word,
    keeping data along the way.
    """
    for strat in set(strategies.Strategy.all_strategies()):
        if strat.is_abstract:
            print(f"Skipping abstract strategy {strat.__name__.upper()}!")
            continue

        if was_already_analyzed(strat):
            print(f"Skipping already-analyzed strategy {strat.__name__.upper()}!")
            continue

        already_done = list(solutions_cache.glob(f"{strat.__name__}_*.pkl.bz2"))
        print(f"\nNow trying strategy {strat.__name__}")

        shard_number, output, save_thread = 0, dict(), None     # Basic parameters controlling how sharded data is saved.
        for (i, solution) in enumerate(sorted(wu.known_five_letter_words), 1):
            if (i <= (len(already_done) * max_entries_in_shard)):
                shard_number = len(already_done)
                continue        # If we're resuming a previous run, skip the starting points we've already analyzed.
            print(f"  Analyzing starting word success for solution #{i}: {solution.upper()} ...")
            key = key_name(strat.__name__, solution)
            output[key] = strat.solve(solution)

            if (len(output) >= max_entries_in_shard) or (i == len(wu.known_five_letter_words)):
                # Have we accumulated enough data to save another shard? Do so.                if save_thread:             # If we've already got a saved thread, wait for it to finish.
                if save_thread and (save_thread.is_alive()):
                    print("    ... waiting for previous save to finish ...")
                    save_thread.join()      # Otherwise, reap any zombie threads that may be occurring.
                save_thread = threading.Thread(target=save_shard, args=(output, strat.__name__, shard_number, solution))
                save_thread.start()
                output = dict()
                shard_number += 1
        if save_thread:
            save_thread.join()
        summarize_analysis(strat)

if __name__ == "__main__":
    if False:                       # Harness for testing FairLimitedHeap
        import sys, string

        items = list(zip(range(23, 100), string.ascii_lowercase))
        h = FairLimitedHeap(10, items)
        print(h)

        sys.exit()

    if False:                        # test harness; in this case, for timing
        import sys

        data = strategies.GetMaximumInfoHardMode.solve('ninja')
        dump_path = Path('output.json').resolve()
        print(f"Dumping JSON data to {dump_path} ...")
        with open(dump_path, 'wt') as json_file:
            json.dump(data, json_file, ensure_ascii=False, default=str, indent=2)
        print("Finished!\n\n")

        sys.exit()

    if False:                        # only do summarizing for a particular strategy
        import sys
        summarize_analysis(strategies.GetMaximumInfoHardMode)

        sys.exit()

    print("Starting up ...")
    exhaustively_analyze()
