#!/usr/bin/env python3
# -*- coding: utf-8 -*-
#cython: language_level=3
"""Utility functions used by the other Wordle code.

Wordle is at https://www.powerlanguage.co.uk/wordle/.

This program comes with ABSOLUTELY NO WARRANTY. Use at your own risk. It is
copyright 2022 by Patrick Mooney. It is free software, and you are welcome to
redistribute it under certain conditions, according to the GNU general public
license, either version 3 or (at your own option) any later version. See the
file LICENSE.md for details.
"""


import collections
import heapq
import numbers
import re
import reprlib
import string
import typing
import unicodedata

from pathlib import Path


# word_list_file = Path('/home/patrick/Documents/programming/resources/word-lists/wordle.list')
word_list_file = Path('/home/patrick/Documents/programming/resources/word-lists/dwyl/words_alpha.txt')
non_words_file = Path('non-words.txt')  # List of words from the large word list we want to exclude from consideration.
addl_words_file = Path('addl-words.txt')    # Words added manually, in addition to the main word list.

if not non_words_file.exists():
    non_words_file.write_text("", encoding='utf-8')
if not addl_words_file.exists():
    addl_words_file.write_text("", encoding='utf-8')

non_words = [w.strip().casefold() for w in non_words_file.read_text(encoding='utf-8').split('\n')]
addl_words = [w.strip().casefold() for w in addl_words_file.read_text(encoding='utf-8').split('\n') if w.strip()]

main_english_words = [w.strip().casefold() for w in word_list_file.read_text(encoding='utf-8').split('\n') if w.strip()]
known_five_letter_words = {w for w in (main_english_words + addl_words) if ((len(w) == 5) and (w not in non_words))}
word_list_text = '\n'.join(sorted(known_five_letter_words))     # these are the only words we're ever interested in


SolutionData = collections.namedtuple('SolutionData', ('Move',
                                                       'InitialPossibleLetters',
                                                       'KnownLettersWithUnknownPositionBeforeGuess',
                                                       'PossibleLettersAfterGuess',
                                                       'KnownLettersWithUnknownPositionAfterGuess',
                                                       'RemainingPossibilities',
                                                       'ExhaustedErroneously',
                                                       'Solved'),  module=__name__)     # Must specify module name to make NamedTuple pickleable: https://stackoverflow.com/questions/55224383/pickling-of-a-namedtuple-instance-succeeds-normally-but-fails-when-module-is-cy


# Some functions to help with normalization of text.
def strip_accents(s: str) -> str:
    return ''.join(c for c in unicodedata.normalize('NFD', s) if unicodedata.category(c) != 'Mn')


def normalize_char_string(s: str) -> str:
    return strip_accents(''.join([c for c in s.lower().strip() if c.isalpha()]))


# Helper functions for the Javier Frias functions, below.
def positional_population_counts(words: typing.Iterable[str]) -> typing.Dict[int, collections.Counter]:
    """Given WORDS, a list of five-letter words, return a dictionary mapping the
    position numbers 1 ... 5 to a Counter showing counts of letters in that
    position.

    For instance, given ['arose', 'until'], the result is (some not-necessarily-same-
    ordered version of):
        { 1: Counter({'a': 1, 'u': 1}),
          2: Counter({'r': 1, 'n': 1}),
          3: Counter({'o': 1, 't': 1}),
          4: Counter({'s': 1, 'i': 1}),
          5: Counter({'e': 1, 'l': 1}) }
    """
    for i in words: assert len(i) == 5
    return {i+1: collections.Counter([w[i] for w in words]) for i in range(5)}


# Two functions that are used to help evaluate criteria picked out by Javier Frias as part of his evaluative criteria.
# See "FLOWS" at https://betterprogramming.pub/forget-luck-optimized-wordle-strategy-using-bigquery-c676771e316f
# As of this writing (19 May 2022), nothing yet uses these functions.
def positional_letter_weight(letter: str,
                             position_in_word: int,
                             sample_population: typing.Dict[int, collections.Counter] = positional_population_counts(known_five_letter_words),
                             ) -> int:
    """The positional letter weight of a letter, LETTER, is how often that letter
    appears as the POSITION_IN_WORDth letter in the words collected together in
    SAMPLE_POPULATION.

    Really this is just a gateway for indexing SAMPLE_POPULATION by position and
    letter, doing some basic sanity checks along the way.

    Frias really only discusses this in relation to picking initial words, which is
    why the SAMPLE_POPULATION defaults to "all known words," but it may be useful to
    help score later guesses, too.
    """
    assert len(letter) == 1
    assert letter in string.ascii_lowercase
    assert isinstance(position_in_word, int)
    assert 1 <= position_in_word <= 5
    return sample_population[position_in_word][letter]


def word_weight(word: str,
                sample_population: typing.Dict[int, collections.Counter] = positional_population_counts(known_five_letter_words),
                ) -> int:
    """The WORD_WEIGHT of a word, WORD, is the sum of the positional letter weights of
    each letter in the word in their respective positions, relative to the
    SAMPLE_POPULATION of words being considered. As with positional_letter_weight,
    above, it defaults to considering a population of "all Wordle words" because
    that's the context in which Frias gives it the most attention.
    """
    assert len(word) == 5
    for c in word: assert c in string.ascii_lowercase


# Functions that are used directly by other code to help manage the changing set of parameters as guesses are tried by
# various strategies.
def enumerate_solutions(possible: typing.Dict[int, str],
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
    """
    regex = ''.join([f"[{''.join(sorted(i))}]" for i in possible.values()]) + "\n"
    possible_answers = [ans.strip() for ans in re.findall(regex, word_list_text) if all(c in ans for c in ambiguous_pos)]
    letter_frequencies = collections.Counter(''.join(possible_answers))
    return letter_frequencies, possible_answers


def untried_word_score(letter_frequencies: collections.Counter,
                       untried_letters: str,
                       w: str) -> int:
    """Produce a score for W, a word that has not yet been attempted. The score depends
    on how often each letter in W that hasn't yet been tried appears in the sample
    of five-letter words. This count is pre-computed and stored in the
    LETTER_FREQUENCIES variable. Letters that have already been tried and are known
    to occur in the word we're trying to guess contribute nothing to the calculated
    score: the score is designed to favor getting more information from the next
    guess, not to increase the likelihood of making the next guess the correct one.
    (We're trying to minimize the overall number of guesses, not to win on the next
    guess.) Repeated letters, after the first occurrence, also do not count toward
    the word's overall score: they don't elicit new information, either. "As many
    new letters as possible" is further incentivized by multiplying the derived
    score-sum by the number of unique letters in the word to derive the final score.
    """
    return sum([letter_frequencies[c] for i, c in enumerate(w) if ((c in untried_letters) and (c not in w[:i]))]) * len(set(w))


def ranked_answers(possible_answers: typing.List[str],
                   letter_frequencies: collections.Counter,
                   untried_letters: str):
    def ranker(w) -> int:
        return untried_word_score(letter_frequencies, untried_letters, w)
    return sorted(possible_answers, key=ranker, reverse=True)


def evaluate_guess(guess: str,
                   answer: str,
                   possibilities: typing.Dict[int, set],
                   unknown_pos: str) -> typing.Tuple[bool, str, typing.Dict[int, str]]:
    """Given a guess, evaluate whether that guess is correct, and update the known
    constraints based on the information that the guess reveals.

    GUESS is of course the current guess, and ANSWER is the answer. POSSIBILITIES is
    a dictionary mapping position number ( [1, 6) ) to a set of letters that might
    be in that position. UNKNOWN_POS is a string containing characters that are
    known to be in the answer, though we don't yet know where.

    POSSIBILITIES is immediately duplicated and the duplicate is modified and
    returned to avoid modifying the original. Currently (16 May 2022), nothing
    depends on the original being unmodified, but that may not stay true forever.

    The return value is a 3-tuple: the first value is True iff GUESS is the correct
    ANSWER, or False otherwise. The second value is the revised list of characters
    that are known to be in the answer but whose position there is unknown. The
    third value is the revised POSSIBILITIES dict, mapping (1-based) position
    numbers onto a set of chars that might be in that position.
    """
    revised_poss = dict(possibilities)
    assert len(guess) == len(answer) == 5, f"ERROR! Somehow, we're dealing with a word ({guess.upper()} / {answer.upper()}) that doesn't have 5 letters!"
    for pos, (guess_c, ans_c) in enumerate(zip(guess, answer)):
        if guess_c == ans_c:        # green tile: this is the correct letter for this position
            revised_poss[1+pos] = set(guess_c)
            unknown_pos = ''.join([c for c in unknown_pos if c != guess_c])
        elif guess_c in answer:     # yellow tile: letter appears in word, but not in this position
            unknown_pos += guess_c
            revised_poss[1+pos].discard(guess_c)
        else:                       # gray tile: letter does not appear in word at all
            revised_poss = {key: value - {guess_c} for key, value in revised_poss.items()}
            unknown_pos = ''.join([c for c in unknown_pos if c != guess_c])
    unknown_pos = ''.join(sorted(set(unknown_pos)))
    return ((guess == answer), unknown_pos, revised_poss)


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

    def __setitem__(self, key, newvalue):
        raise TypeError(f"Cannot directly set individual items in a {self.__class__.__name__}! Use .push() to add a value to the heap instead.")

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
