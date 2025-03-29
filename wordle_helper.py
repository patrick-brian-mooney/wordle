#!/home/patrick/Documents/programming/python_projects/wordle/bin/python
# -*- coding: utf-8 -*-
"""A helper for guessing Wordle entries based on already known information. It
prompts the user for already-known information and then prints a list of known
English words that match the specified info. It also requires a list of known
English words; I use one that I extracted directly from the Wordle JavaScript
code; previously I tested the script with a fuller list I got at
https://github.com/dwyl/english-words.

At the end of the run, it prints out a list of known English five-letter words,
based on the word list, that are not excluded by the information already known.
These words are ranked according to an algorithm that prioritizes:

  * words with more, rather than fewer, unique untried letters;
  * words containing letters that occur more frequently in the list of known
    five-letter words.

The overall strategy is not to try to guess right on the next guess, but to
use the next guess to elicit as much new information as possible while also
acting in a way that maximizes the likelihood of being right on the next guess,
to the extent that that doesn't conflict with getting as much new info as
possible.

Wordle is at https://www.powerlanguage.co.uk/wordle/.

This program comes with ABSOLUTELY NO WARRANTY. Use at your own risk. It is
copyright 2022 by Patrick Mooney. It is free software, and you are welcome to
redistribute it under certain conditions, according to the GNU general public
license, either version 3 or (at your own option) any later version. See the
file LICENSE.md for details.
"""


import argparse
import collections
import typing
import string
import sys

try:
    import pyximport; pyximport.install()       # http://cython.org
except (ImportError,):                          # Allow running from setups that don't have Cython installed ...
    pass                                        # ... by renaming *.pyx files to *.py

import wordle_utils as wu


print('\n\n\nStarting up ...')
print(f"    (running under Python {sys.version}")


def prompt_and_solve() -> typing.Tuple[str, str, collections.Counter, typing.Set[str]]:
    print(f"{len(wu.known_five_letter_words)} five-letter words known!\n\n")

    if input("Have you entirely eliminated any letters? ").strip().lower()[0] == 'y':
        elim = ''.join(set(wu.normalize_char_string(input("Enter all eliminated letters: "))))
    else:
        elim = ''

    if input("Do you have any letters yet without knowing their position? ").strip().lower()[0] == 'y':
        correct = wu.normalize_char_string(input("Enter all known letters: "))
    else:
        correct = ''

    if input("Have you finalized the position of any letters? ").strip().lower()[0] == 'y':
        possible = {}
        for i in range(1, 6):
            if input(f"Do you know the letter in position {i}? ").strip().lower()[0] == 'y':
                char = input(f"What is the letter in position {i}? ").strip().lower()
                assert len(char) == 1, "ERROR! You can only input one letter there!"
                possible[i] = char
            else:
                possible[i] = ''.join([c for c in string.ascii_lowercase if (c not in elim)])
    else:
        possible = {key: ''.join([c for c in string.ascii_lowercase if (c not in elim)]) for key in range(1, 6)}

    for c in correct:
        for i in range(1, 6):
            if len(possible[i]) == 1:  # Have we already determined for sure what letter is in a position?
                continue  # No need to ask if we've eliminated other characters, then.
            if input(f"Can you eliminate character {c} from position {i}? ").lower().strip() == "y":
                possible[i] = ''.join([char for char in possible[i] if char != c])

    known_letters = ''.join([s[0] for s in possible.values() if (len(s) == 1)])
    untried_letters = ''.join([c for c in string.ascii_lowercase if ((c not in elim) and (c not in known_letters))])

    letter_frequencies, possible_answers = wu.enumerate_solutions(possible, correct)
    return known_letters, untried_letters, letter_frequencies, possible_answers


if __name__ == "__main__":
    print('\n\nWordle Helper Utils, by Patrick Mooney. Use -h or --help for help.\n')
    parser = argparse.ArgumentParser(prog='Wordle Helper',
        description="A set of utilities for use with Parick Mooney's Wordle Helper script",
        epilog='Released under the GNU GPL, either version 3 or (at your option) any later version. See the file '
               'LICENSE.md for details.')
    parser.add_argument('--eliminate-word', '--elim', '-e', action='append',
                        help="A word to eliminate from the list of potential words to consider.")
    parser.add_argument('--confirm-word', '--confirm', '--conf', '-c', action='append',
                        help="A word to be marked in output as having been confirmed to exist as a potential answer.")
    parser.add_argument('--add-word', '--add', '-a', action='append',
                        help="A word to add to the list of potential words to consider.")
    args = vars(parser.parse_args())

    changes = False     # set to True if we make any changes to word lists.

    if ('eliminate_word' in args) and (args['eliminate_word']):
        num_removed = 0
        start_len = len(wu.non_words)
        for word in sorted([w.strip().casefold() for w in args['eliminate_word']]):
            if len(word) == 5:
                wu.non_words.append(word)
                print(f"Added {word.upper()} to list of non-words!")
                num_removed += 1

                try:
                    wu.addl_words.remove(word)
                except ValueError:
                    pass

                try:
                    wu.conf_words.remove(word)
                except ValueError:
                    pass

        if num_removed:
            changes = True
            wu.non_words = sorted(set(wu.non_words))
            wu.non_words_file.write_text('\n'.join(wu.non_words), encoding='utf-8')
            print('    ... updated list of non-words on disk!')
            print(f"    ... list of non-words now has {len(wu.non_words)} entries!")

    if ('add_word' in args) and (args['add_word']):
        num_added = 0
        start_len = len(wu.addl_words)
        for word in sorted([w.strip().casefold() for w in args['add_word']]):
            if len(word) == 5:
                wu.addl_words.append(word)
                print(f"Added {word.upper()} to list of additional words!")
                num_added += 1

                try:
                    wu.non_words.remove(word)
                except ValueError:
                    pass

        if num_added:
            changes = True
            wu.addl_words = sorted(set(wu.addl_words))
            wu.addl_words_file.write_text('\n'.join(wu.addl_words), encoding='utf-8')
            print('    ... updated list of additional words on disk!')
            (print(f"    ... list of additional words now has {len(wu.addl_words)} entries!"))

    if ('confirm_word' in args) and (args['confirm_word']):
        num_confirmed = 0
        start_len = len(wu.conf_words)
        for word in sorted([w.strip().casefold() for w in args['confirm_word']]):
            if len(word) == 5:
                wu.conf_words.append(word)
                print(f"Added {word.upper()} to list of confirmed words!")
                num_confirmed += 1

                try:
                    wu.non_words.remove(word)
                except ValueError:
                    pass

        if num_confirmed:
            changes = True
            wu.conf_words = sorted(set(wu.conf_words))
            wu.conf_words_file.write_text('\n'.join(wu.conf_words), encoding='utf-8')
            print('    ... updated list of confirmed words on disk!')
            print(f"    ... list of confirmed words now has {len(wu.conf_words)} entries!")

    # If we tried to perform one or more maintenance tasks, quit without running the main script
    if (('add_word' in args) and (args['add_word'])) or \
        (('eliminate_word' in args) and (args['eliminate_word'])) or \
        (('confirm_word' in args) and (args['confirm_word'])):
        print("\n  ... all requested actions performed! Quitting ...")
        sys.exit(0)

    known_letters, untried_letters, letter_frequencies, possible_answers = prompt_and_solve()
    print("Possible answers:")

    if possible_answers:
        for w in wu.ranked_answers(possible_answers, letter_frequencies, untried_letters):
            if w.strip().casefold() in wu.conf_words:
                print(w.upper())
            else:
                print(w)

        print(f"\n{len(possible_answers)} possibilities ({len(possible_answers) - len({w for w in wu.conf_words if w in possible_answers})} unconfirmed)!\n")

    else:
        print("No possibilities found!")
