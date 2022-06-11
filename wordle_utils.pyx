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
import re
import string
import typing
import unicodedata

from pathlib import Path


# word_list_file = Path('/home/patrick/Documents/programming/resources/word-lists/dwyl/words_alpha.txt')
word_list_file = Path('/home/patrick/Documents/programming/resources/word-lists/wordle.list')


word_list_text = word_list_file.read_text()
known_english_words = [w.strip() for w in word_list_text.split('\n') if w.strip()]
known_five_letter_words = {w for w in known_english_words if len(w) == 5}


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


# Functions that are used directly by other code to help amanage the changing set of parameters as guesses are tried by
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
