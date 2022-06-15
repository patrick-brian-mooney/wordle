Wordle Utility Scripts
=================================

A series of scripts for exploring possibilities in the [Wordle](https://www.nytimes.com/games/wordle/index.html) online game. 

Code in this project depends on both [NumPy](https://numpy.org/) and [Pandas](https://pandas.pydata.org/) for its record-keeping and statistical processing. By default, it also uses [Cython](http://cython.org) for speedups, but this is easy enough to work around if installing Cython and getting it running is onerous on your system.

The Wordle utilities were developed under CPython 3.6 and 3.8, but should work just fine on any recent version of Python.

`wordle_explorer.py`
--------------------
Works through all of the strategies coded in `strategies.pyx`, trying each Strategy for each possible answer from each possible starting word, assessing the Strategy's overall performance, and keeping a list of best (and worst) starting words. Writes summary statistics to the `solutions/` directory.

`wordle_helper.py`
-----------------
Prompts the user to evaluate and input the data already returned by guesses on the current Wordle board, then returns a list of words that have not yet been eliminated, decreasingly ranked according to the same ranking system used in the `GetMaximumInfoHardMode` Strategy.

`strategies.pyx`
----------------
Actual code implementing the various strategies tried by `wordle_explorer.py` as classes that bundle the functions necessary for the strategies to operate.

This file is designed to be compiled with [Cython](http://cython.org), but you can avoid installing Cython by changing the extension from `.pyx` to `.py`. `wordle_explorer.py` will then run 100% to 200% slower.

`wordle_utils.pyx`
-----------------
Utility code used by both `wordle_explorer.py` and `wordle_helper.py`.

This file is designed to be compiled with [Cython](http://cython.org), but you can avoid installing Cython by changing the extension from `.pyx` to `.py`. `wordle_explorer.py` will then run 100% to 200% slower.




These scripts are copyright © 2022 by Patrick Mooney. They are licensed under the GPL v3 or, at your option, any
later version. See the file LICENSE.md for a copy of this licence. No warranty or guarantee of functionality is
represented here, though I'm glad if these scripts are helpful to you and would love to hear if you have thoughts or
feedback.
