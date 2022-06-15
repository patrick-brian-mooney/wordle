#!/usr/bin/env python3
# -*- coding: utf-8 -*-
#cython: language_level=3

"""Collection of Strategy classes used by the Wordle-analyzing code.

Wordle is at https://www.powerlanguage.co.uk/wordle/.

This program comes with ABSOLUTELY NO WARRANTY. Use at your own risk. It is
copyright 2022 by Patrick Mooney. It is free software, and you are welcome to
redistribute it under certain conditions, according to the GNU general public
license, either version 3 or (at your own option) any later version. See the
file LICENSE.md for details.
"""


import collections
import numbers
import random
import string
import typing

import wordle_utils as wu


class Strategy:
    """An abstract strategy, specifying what parameters are necessary. All
    Strategies MUST be subclasses of this class.

    Strategies are "degenerate" classes -- mere packages of functions. They need not
    even be instantiated to do their work: none of their methods takes a SELF
    parameter! (All their methods are static or class methods.) They are mini-
    modules that keep their related functions in bundles, nothing more. All that
    instantiating them achieves is checking that all of a Strategy's abstract
    methods have been filled in.

    (Even that's not true any more! Moving to Cython has mandated that Strategy no
    longer be a Python ABC with abstract methods, because that can't be combined
    with static methods when compiling via Cython. So there is no benefit
    whatsoever to instantiating a Strategy! It's just a package of functions that
    benefits from inheritance to facilitate decomposition.)
    """
    is_abstract = True      # Can't use @abstractmethod or metaclass=abc.ABC when compiling with Cython and also using
                            # @classmethod. This must be manually and properly set on subclasses: if this is True, the
                            # Stategy is taken to be an abstract superclass, and it won't be tried.

    @classmethod
    def all_strategies(cls) -> typing.Generator[type, None, None]:
        """Returns a list of all known strategies.
        """
        for t in cls.__subclasses__():
            yield t
            yield from t.all_strategies()           #FIXME! Check to see whether this works?

    @staticmethod
    # @abc.abstractmethod
    def rank(possible_words: typing.List[str]) -> typing.List[str]:
        """Given POSSIBLE_WORDS, rank them so that (what the strategy thinks is the)
        most-likely word comes first, followed by the next-most-likely, etc.
        """

    @staticmethod
    # @abc.abstractmethod
    def score(letter_frequencies: collections.Counter,
              untried_letters: str,
              w: str) -> typing.Type[numbers.Number]:
        """Assign a score to an individual guess. A guess that the Strategy thinks is
        "better" should get a higher score. Strategies need not worry about how their
        rankings compare to the rankings of other Strategies; that comparison is never
        made.
        """
        raise NotImplementedError

    @classmethod
    def solve(cls, answer: str) -> typing.Dict:          #FIXME! More specific return type.
        """Given ANSWER, the answer to the Wordle in question, try to derive that answer by
        starting from each possible starting word and applying the particular strategy,
        tracking how successful it is in each instance, and returning a dictionary that
        both summarizes the overall performance of the strategy and includes
        move-by-move details about how each starting word played out.
        """
        solutions = {w: cls.solve_from(answer, w) for w in wu.known_five_letter_words}
        solutions = {k: v for k, v in solutions.items() if v}           # Filter out any non-answers, as in ShadePointCurly-type strategies
        ret = {
            'solutions': solutions,
            'number solved': len([i for i in solutions.values() if i[-1].Solved]),
        }
        if [i for i in solutions.values() if i[-1].Solved]:
            ret.update({
            'average moves': (sum([len(i) for i in solutions.values() if i[-1].Solved]) / len([i for i in solutions.values() if i[-1].Solved])),
            'number of errors': len([i for i in solutions.values() if i[-1].ExhaustedErroneously])
            })
        return ret

    @classmethod
    def solve_from(cls, answer: str,
                   start_from: typing.Union[str, None],
                   moves_made: typing.Optional[typing.List[typing.Dict]] = None,
                   discovered_but_unknown_pos: typing.Optional[str] = None,
                   constraints: typing.Optional[typing.Dict[int, str]] = None,
                   ) -> typing.Union[None, typing.Tuple[wu.SolutionData]]:
        """Given ANSWER, the answer to the Wordle, derive it from START_FROM using the
        current Strategy, tracking moves made and how that changes the parameters of
        what answers are remaining.

        START_FROM may be None to force the inidividual Strategy to choose its own
        starting move. This really only makes sense of the "starting move" is a "next
        move" because a subclass has already made some choices and is delegating the
        rest of the choices to a superclass. This happens, for instance, with
        descendants of SpecifyInitialGuessesMixIn.

        Subclasses may refuse to analyze for certain sets of parameters and return None
        instead of returning an appropriate analysis dictionary.
        """
        possibilities = constraints or {i: set(string.ascii_lowercase) for i in range(1, 6)}
        ret, done = moves_made or list(), False
        guess, unknown_pos = start_from, discovered_but_unknown_pos or ''

        while not done:
            if guess:
                done, new_unknown_pos, new_possibilities = wu.evaluate_guess(guess, answer, possibilities, unknown_pos)
            else:
                new_unknown_pos, new_possibilities = unknown_pos, possibilities
            untried_letters = ''.join([c for c in string.ascii_lowercase if c not in ''.join(i.Move for i in ret)])
            letter_frequencies, remaining_possibilities = wu.enumerate_solutions(new_possibilities, new_unknown_pos)
            possible_answers = {sol: cls.score(letter_frequencies, untried_letters, sol) for sol in remaining_possibilities}
            possible_answers = dict(sorted(possible_answers.items(), key=lambda kv: kv[1], reverse=True))
            if guess:
                if len(ret) > 5:
                    done = True
                ret.append(wu.SolutionData(Move=guess,
                                           InitialPossibleLetters=tuple((key, value) for key, value in possibilities.items()),
                                           KnownLettersWithUnknownPositionBeforeGuess=unknown_pos,
                                           PossibleLettersAfterGuess=tuple((key, value) for key, value in new_possibilities.items()),
                                           KnownLettersWithUnknownPositionAfterGuess=new_unknown_pos,
                                           RemainingPossibilities=len(possible_answers),
                                           ExhaustedErroneously=any([not len(v) for v in possibilities.values()]),
                                           Solved=done))
            if not done:
                guess = list(possible_answers.keys())[0]
                possibilities, unknown_pos = new_possibilities, new_unknown_pos
        return tuple(ret)


class GetMaximumInfoHardMode(Strategy):
    """A Strategy that effectively "plays in hard mode," i.e. chooses a guess on every
    round that COULD, based on all revealed information so far, be the answer. Of
    those remaining possibilities, the ones that receive the highest score are those
    that pick the largest number of letters that are frequently used among the
    remaining possibilities that haven't yet been tried.
    """
    is_abstract = False

    @staticmethod
    def score(letter_frequencies: collections.Counter,
              untried_letters: str,
              w: str) -> int:
        return wu.untried_word_score(letter_frequencies, untried_letters, w)


class RandomChoiceOnEachTurn(Strategy):
    """A Strategy that scores each possibility entirely randomly. It does not PICK
    A RANDOM WORD, nor even PICK A RANDOM WORDLE WORD; it limits itself to words
    that haven't been eliminated already by the information given. It just scores
    each of them randomly.
    """
    is_abstract = False

    @staticmethod
    def score(letter_frequencies: collections.Counter,
              untried_letters: str,
              w: str) -> typing.Type[numbers.Number]:
        return random.random()


class SpecifyInitialGuessesMixIn(Strategy):
    """A Strategy that tries a specific series of initial guesses before falling back
    on its (other) parent Strategy from there. The set of initial tries is specified
    as the class attribute _INITIAL_TRIES, which needs to be overridden in a
    subclass. If it isn't, the derived Strategy just immediately falls back on its other
    superclass.

    This is a mix-in class, and needs to by specified first in the superclass list.
    """
    is_abstract = True
    _initial_tries = ()

    @classmethod
    def _delegation_class(cls) -> type:
        """Examine the superclass list and get the first class other than this one from
        the list of superclasses, and return that class.

        Can be overridden by subclasses to choose a different class to delegate to.
        """
        assert len(cls.__bases__) > 1   # This is a mix-in class only!
        assert (cls.__bases__[0] == SpecifyInitialGuessesMixIn) or issubclass(cls.__bases__[0], SpecifyInitialGuessesMixIn)
        for c in cls.__bases__:         # This would fail if we were going all the way up the __mro__, but we're not.
            assert issubclass(c, Strategy)
        assert len([c for c in cls.__bases__ if (not issubclass(c, SpecifyInitialGuessesMixIn) and (not c == SpecifyInitialGuessesMixIn))]) > 0
        return [c for c in cls.__bases__ if (not issubclass(c, SpecifyInitialGuessesMixIn) and (not c == SpecifyInitialGuessesMixIn))][0]

    @classmethod
    def _abort_early(cls, moves: typing.List[dict],
                     known_letters_with_unknown_pos: str,
                     possibilities: typing.Iterable[str],
                     ) -> bool:
        """Decide whether to abort before all initial guesses have been tried, even if
        a solution hasn't been found. By default, in this class, this never ever
        happens; but this can be changed by subclassing.
        """
        return False

    @classmethod
    def solve_from(cls, answer: str,
                   start_from: typing.Union[str, None],
                   moves_made: typing.Optional[typing.List[typing.Dict]] = None,
                   discovered_but_unknown_pos: typing.Optional[str] = None,
                   constraints: typing.Optional[typing.Dict[int, str]] = None,
                   ) -> typing.Union[None, typing.Tuple[wu.SolutionData]]:
        """Given ANSWER, the answer to the Wordle, derive it from START_FROM using the
        current Strategy, tracking moves made and how that changes the parameters of
        what answers are remaining.

        START_FROM should not be None, but the possibility needs to be written into the
        meathod header because Cython requires that descendant classes have the same
        method headers as the headers for the methods they're overriding.

        If __INITIAL_GUESSES are specified (by subclassing) and START_FROM is not
        the correct starting word, returns None instead of analyzing.
        """
        assert start_from is not None
        if cls._initial_tries and (cls._initial_tries[0] != start_from):
            return None

        possibilities = constraints or {i: set(string.ascii_lowercase) for i in range(1, 6)}
        ret, done = moves_made or list(), False
        guesses = list(cls._initial_tries)
        guess, unknown_pos = start_from, discovered_but_unknown_pos or ''

        while guesses and not done:
            guess = guesses.pop(0)
            if not guesses:
                return tuple(cls._delegation_class().solve_from(answer, guess, ret, unknown_pos))
            done, new_unknown_pos, new_possibilities = wu.evaluate_guess(guess, answer, possibilities, unknown_pos)
            untried_letters = ''.join([c for c in string.ascii_lowercase if c not in ''.join(i.Move for i in ret)])
            letter_frequencies, remaining_possibilities = wu.enumerate_solutions(new_possibilities, new_unknown_pos)
            possible_answers = {sol: cls.score(letter_frequencies, untried_letters, sol) for sol in remaining_possibilities}
            possible_answers = dict(sorted(possible_answers.items(), key=lambda kv: kv[1], reverse=True))
            if len(ret) > 5:
                done = True
            ret.append(wu.SolutionData(Move=guess,
                                       InitialPossibleLetters=tuple((key, value) for key, value in possibilities.items()),
                                       KnownLettersWithUnknownPositionBeforeGuess=unknown_pos,
                                       PossibleLettersAfterGuess=tuple((key, value) for key, value in new_possibilities.items()),
                                       KnownLettersWithUnknownPositionAfterGuess=new_unknown_pos,
                                       RemainingPossibilities=len(possible_answers),
                                       ExhaustedErroneously=any([not len(v) for v in possibilities.values()]),
                                       Solved=done))
            if not done:
                possibilities, unknown_pos = new_possibilities, new_unknown_pos
            if (len(ret) < len(cls._initial_tries)) and cls._abort_early(ret, unknown_pos, remaining_possibilities):
                # Wait a minute: what should we do when this happens?
                # Answer: restructure code above to guess earlier, once we have a Strategy that requires it.
                return tuple(cls._delegation_class().solve_from(answer, None, ret, unknown_pos, possibilities))


class ShadePointCurlyMixIn(SpecifyInitialGuessesMixIn):
    """A Strategy based on the "optimized strategy" of Javier Frias, in "Forget Luck:
    Optimized Wordle Strategy using BigQuery" (hereafter FLOWS). This is not an
    exact implementation of the Strategy, which requires human judgment to be
    applied; it just mechanically tries the three words he recommends sequentially
    (unless one of the first two is a winner), then falls back on its (other) parent
    Strategy from there.

    This is a mix-in class, and needs to by specified first in the superclass list.

    FLOWS is available on the web at:
    https://betterprogramming.pub/forget-luck-optimized-wordle-strategy-using-bigquery-c676771e316f
    """
    is_abstract = True
    _initial_tries = ('shade', 'point', 'curly')


class ShadePointCurlyThenGetMaximumInfoHardMode(ShadePointCurlyMixIn, GetMaximumInfoHardMode):
    """Uses the SHADE, POINT, CURLY trio first, then falls back on using
    GetMaximumInfoHardMode for the rest of its guesses. This is not quite what Frias
    suggests, but it's not all that far off, either.
    """
    is_abstract = False


class BailEarlyByPercentageReductionMixIn(SpecifyInitialGuessesMixIn):
    """A mix-in Strategy to be used in combination with subclasses of
    SpecifyInitialGuessesMixIn. It bails early on using the initial guesses if the
    number of remaining possibilities is sufficiently reduced to make it worthwhile
    to just move along to the other parent strategy. "Sufficiently" is specified as
    a percentage reduction relative to the number of total possibilities that each
    strategy begins with. Without this, a SpecifyInitialGuessesMixIn descendant will
    mechanically go through all of its initial guesses, stopping only if one of
    those guesses happens to be the answer.
    """
    is_abstract = True
    reduction_needed_to_abort = None

    @classmethod
    def _abort_early(cls, moves: typing.List[dict],
                     known_letters_with_unknown_pos: str,
                     possibilities: typing.Iterable[str],  # FIXME: More specific annotation
                     ) -> bool:
        assert cls.reduction_needed_to_abort is not None, f"ERROR! Strategy {cls.__name__} does not specify the amount of space reduction needed to abort trying a specified list of initial guesses early!"
        assert 0 <= cls.reduction_needed_to_abort <= 1, f"ERROR! Strategy {cls.__name__} has a reduction_needed_to_bort value that is not between zero and 1!"
        return (len(possibilities) < ((1.0 - cls.reduction_needed_to_abort) * len(wu.known_five_letter_words)))


class ShadePointCurlyThenGetMaximumInfoHardModeAndBailEarly01(BailEarlyByPercentageReductionMixIn, ShadePointCurlyMixIn, GetMaximumInfoHardMode):
    is_abstract = False
    reduction_needed_to_abort = .01


class ShadePointCurlyThenGetMaximumInfoHardModeAndBailEarly02(BailEarlyByPercentageReductionMixIn, ShadePointCurlyMixIn, GetMaximumInfoHardMode):
    is_abstract = False
    reduction_needed_to_abort = .02


class ShadePointCurlyThenGetMaximumInfoHardModeAndBailEarly03(BailEarlyByPercentageReductionMixIn, ShadePointCurlyMixIn, GetMaximumInfoHardMode):
    is_abstract = False
    reduction_needed_to_abort = .03


class ShadePointCurlyThenGetMaximumInfoHardModeAndBailEarly04(BailEarlyByPercentageReductionMixIn, ShadePointCurlyMixIn, GetMaximumInfoHardMode):
    is_abstract = False
    reduction_needed_to_abort = .04


class ShadePointCurlyThenGetMaximumInfoHardModeAndBailEarly05(BailEarlyByPercentageReductionMixIn, ShadePointCurlyMixIn, GetMaximumInfoHardMode):
    is_abstract = False
    reduction_needed_to_abort = .05


class ShadePointCurlyThenGetMaximumInfoHardModeAndBailEarly06(BailEarlyByPercentageReductionMixIn, ShadePointCurlyMixIn, GetMaximumInfoHardMode):
    is_abstract = False
    reduction_needed_to_abort = .06


class ShadePointCurlyThenGetMaximumInfoHardModeAndBailEarly07(BailEarlyByPercentageReductionMixIn, ShadePointCurlyMixIn, GetMaximumInfoHardMode):
    is_abstract = False
    reduction_needed_to_abort = .07


class ShadePointCurlyThenGetMaximumInfoHardModeAndBailEarly08(BailEarlyByPercentageReductionMixIn, ShadePointCurlyMixIn, GetMaximumInfoHardMode):
    is_abstract = False
    reduction_needed_to_abort = .08


class ShadePointCurlyThenGetMaximumInfoHardModeAndBailEarly09(BailEarlyByPercentageReductionMixIn, ShadePointCurlyMixIn, GetMaximumInfoHardMode):
    is_abstract = False
    reduction_needed_to_abort = .09


class ShadePointCurlyThenGetMaximumInfoHardModeAndBailEarly10(BailEarlyByPercentageReductionMixIn, ShadePointCurlyMixIn, GetMaximumInfoHardMode):
    is_abstract = False
    reduction_needed_to_abort = .10


class ShadePointCurlyThenGetMaximumInfoHardModeAndBailEarly15(BailEarlyByPercentageReductionMixIn, ShadePointCurlyMixIn, GetMaximumInfoHardMode):
    is_abstract = False
    reduction_needed_to_abort = .15


class ShadePointCurlyThenGetMaximumInfoHardModeAndBailEarly20(BailEarlyByPercentageReductionMixIn, ShadePointCurlyMixIn, GetMaximumInfoHardMode):
    is_abstract = False
    reduction_needed_to_abort = .20


class ShadePointCurlyThenGetMaximumInfoHardModeAndBailEarly25(BailEarlyByPercentageReductionMixIn, ShadePointCurlyMixIn, GetMaximumInfoHardMode):
    is_abstract = False
    reduction_needed_to_abort = .25


class ShadePointCurlyThenGetMaximumInfoHardModeAndBailEarly30(BailEarlyByPercentageReductionMixIn, ShadePointCurlyMixIn, GetMaximumInfoHardMode):
    is_abstract = False
    reduction_needed_to_abort = .30


class ShadePointCurlyThenGetMaximumInfoHardModeAndBailEarly35(BailEarlyByPercentageReductionMixIn, ShadePointCurlyMixIn, GetMaximumInfoHardMode):
    is_abstract = False
    reduction_needed_to_abort = .35


class ShadePointCurlyThenGetMaximumInfoHardModeAndBailEarly40(BailEarlyByPercentageReductionMixIn, ShadePointCurlyMixIn, GetMaximumInfoHardMode):
    is_abstract = False
    reduction_needed_to_abort = .40


class ShadePointCurlyThenGetMaximumInfoHardModeAndBailEarly45(BailEarlyByPercentageReductionMixIn, ShadePointCurlyMixIn, GetMaximumInfoHardMode):
    is_abstract = False
    reduction_needed_to_abort = .45


class ShadePointCurlyThenGetMaximumInfoHardModeAndBailEarly50(BailEarlyByPercentageReductionMixIn, ShadePointCurlyMixIn, GetMaximumInfoHardMode):
    is_abstract = False
    reduction_needed_to_abort = .50


class ShadePointCurlyThenGetMaximumInfoHardModeAndBailEarly55(BailEarlyByPercentageReductionMixIn, ShadePointCurlyMixIn, GetMaximumInfoHardMode):
    is_abstract = False
    reduction_needed_to_abort = .55


class ShadePointCurlyThenGetMaximumInfoHardModeAndBailEarly60(BailEarlyByPercentageReductionMixIn, ShadePointCurlyMixIn, GetMaximumInfoHardMode):
    is_abstract = False
    reduction_needed_to_abort = .60


class ShadePointCurlyThenGetMaximumInfoHardModeAndBailEarly65(BailEarlyByPercentageReductionMixIn, ShadePointCurlyMixIn, GetMaximumInfoHardMode):
    is_abstract = False
    reduction_needed_to_abort = .65


class ShadePointCurlyThenGetMaximumInfoHardModeAndBailEarly70(BailEarlyByPercentageReductionMixIn, ShadePointCurlyMixIn, GetMaximumInfoHardMode):
    is_abstract = False
    reduction_needed_to_abort = .70


class ShadePointCurlyThenGetMaximumInfoHardModeAndBailEarly75(BailEarlyByPercentageReductionMixIn, ShadePointCurlyMixIn, GetMaximumInfoHardMode):
    is_abstract = False
    reduction_needed_to_abort = .75


class ShadePointCurlyThenGetMaximumInfoHardModeAndBailEarly80(BailEarlyByPercentageReductionMixIn, ShadePointCurlyMixIn, GetMaximumInfoHardMode):
    is_abstract = False
    reduction_needed_to_abort = .80


class ShadePointCurlyThenGetMaximumInfoHardModeAndBailEarly85(BailEarlyByPercentageReductionMixIn, ShadePointCurlyMixIn, GetMaximumInfoHardMode):
    is_abstract = False
    reduction_needed_to_abort = .85


class ShadePointCurlyThenGetMaximumInfoHardModeAndBailEarly90(BailEarlyByPercentageReductionMixIn, ShadePointCurlyMixIn, GetMaximumInfoHardMode):
    is_abstract = False
    reduction_needed_to_abort = .90


class ShadePointCurlyThenGetMaximumInfoHardModeAndBailEarly91(BailEarlyByPercentageReductionMixIn, ShadePointCurlyMixIn, GetMaximumInfoHardMode):
    is_abstract = False
    reduction_needed_to_abort = .91


class ShadePointCurlyThenGetMaximumInfoHardModeAndBailEarly92(BailEarlyByPercentageReductionMixIn, ShadePointCurlyMixIn, GetMaximumInfoHardMode):
    is_abstract = False
    reduction_needed_to_abort = .92


class ShadePointCurlyThenGetMaximumInfoHardModeAndBailEarly93(BailEarlyByPercentageReductionMixIn, ShadePointCurlyMixIn, GetMaximumInfoHardMode):
    is_abstract = False
    reduction_needed_to_abort = .93


class ShadePointCurlyThenGetMaximumInfoHardModeAndBailEarly94(BailEarlyByPercentageReductionMixIn, ShadePointCurlyMixIn, GetMaximumInfoHardMode):
    is_abstract = False
    reduction_needed_to_abort = .94


class ShadePointCurlyThenGetMaximumInfoHardModeAndBailEarly95(BailEarlyByPercentageReductionMixIn, ShadePointCurlyMixIn, GetMaximumInfoHardMode):
    is_abstract = False
    reduction_needed_to_abort = .95


class ShadePointCurlyThenGetMaximumInfoHardModeAndBailEarly96(BailEarlyByPercentageReductionMixIn, ShadePointCurlyMixIn, GetMaximumInfoHardMode):
    is_abstract = False
    reduction_needed_to_abort = .96


class ShadePointCurlyThenGetMaximumInfoHardModeAndBailEarly97(BailEarlyByPercentageReductionMixIn, ShadePointCurlyMixIn, GetMaximumInfoHardMode):
    is_abstract = False
    reduction_needed_to_abort = .97


class ShadePointCurlyThenGetMaximumInfoHardModeAndBailEarly98(BailEarlyByPercentageReductionMixIn, ShadePointCurlyMixIn, GetMaximumInfoHardMode):
    is_abstract = False
    reduction_needed_to_abort = .98


class ShadePointCurlyThenGetMaximumInfoHardModeAndBailEarly99(BailEarlyByPercentageReductionMixIn, ShadePointCurlyMixIn, GetMaximumInfoHardMode):
    is_abstract = False
    reduction_needed_to_abort = .99


class ShadePointCurlyThenGetMaximumInfoHardModeAndBailEarly991(BailEarlyByPercentageReductionMixIn, ShadePointCurlyMixIn, GetMaximumInfoHardMode):
    is_abstract = False
    reduction_needed_to_abort = .991


class ShadePointCurlyThenGetMaximumInfoHardModeAndBailEarly992(BailEarlyByPercentageReductionMixIn, ShadePointCurlyMixIn, GetMaximumInfoHardMode):
    is_abstract = False
    reduction_needed_to_abort = .992


class ShadePointCurlyThenGetMaximumInfoHardModeAndBailEarly993(BailEarlyByPercentageReductionMixIn, ShadePointCurlyMixIn, GetMaximumInfoHardMode):
    is_abstract = False
    reduction_needed_to_abort = .993


class ShadePointCurlyThenGetMaximumInfoHardModeAndBailEarly994(BailEarlyByPercentageReductionMixIn, ShadePointCurlyMixIn, GetMaximumInfoHardMode):
    is_abstract = False
    reduction_needed_to_abort = .994


class ShadePointCurlyThenGetMaximumInfoHardModeAndBailEarly995(BailEarlyByPercentageReductionMixIn, ShadePointCurlyMixIn, GetMaximumInfoHardMode):
    is_abstract = False
    reduction_needed_to_abort = .995


class ShadePointCurlyThenGetMaximumInfoHardModeAndBailEarly996(BailEarlyByPercentageReductionMixIn, ShadePointCurlyMixIn, GetMaximumInfoHardMode):
    is_abstract = False
    reduction_needed_to_abort = .996


class ShadePointCurlyThenGetMaximumInfoHardModeAndBailEarly997(BailEarlyByPercentageReductionMixIn, ShadePointCurlyMixIn, GetMaximumInfoHardMode):
    is_abstract = False
    reduction_needed_to_abort = .997


class ShadePointCurlyThenGetMaximumInfoHardModeAndBailEarly998(BailEarlyByPercentageReductionMixIn, ShadePointCurlyMixIn, GetMaximumInfoHardMode):
    is_abstract = False
    reduction_needed_to_abort = .998


class ShadePointCurlyThenGetMaximumInfoHardModeAndBailEarly999(BailEarlyByPercentageReductionMixIn, ShadePointCurlyMixIn, GetMaximumInfoHardMode):
    is_abstract = False
    reduction_needed_to_abort = .999
