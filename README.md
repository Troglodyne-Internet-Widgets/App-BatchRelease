# NAME

App::BatchRelease - Release, in one run, every Dist::Zilla distribution of a set of checkouts whose work is not all on CPAN

# VERSION

version 0.001

# SYNOPSIS

```perl
use 5.040;
use App::BatchRelease;

exit App::BatchRelease->new->run( '--dry-run', '/bogus/Foo-Bar', '/bogus/Foo-Baz' );
```

# DESCRIPTION

This is the program `batch-release`.  Its POD says how a person uses it.
This page says what each part does, for a caller and for a test.

A run has four steps:

- 1. ["plan"](#plan)

    Looks at each checkout, without changing any, and sorts them into the ones
    to release, in order, and the ones to skip, each with its reason.

- 2. ["listing"](#listing)

    Prints both lists.  A dry run stops here.

- 3. ["confirm"](#confirm), then the credentials

    Asks the person to confirm the list, then asks for the PAUSE username and
    password, once, through [App::BatchRelease::Credentials](https://metacpan.org/pod/App%3A%3ABatchRelease%3A%3ACredentials).  Both happen
    before the first build.

- 4. ["release\_all"](#release_all)

    Releases each distribution of the list, in order, through
    [App::BatchRelease::Release](https://metacpan.org/pod/App%3A%3ABatchRelease%3A%3ARelease), skips each one that requires a distribution
    whose release failed, and prints the summary.

# ATTRIBUTES

## cpan

The client of MetaCPAN.  Default an [App::BatchRelease::MetaCPAN](https://metacpan.org/pod/App%3A%3ABatchRelease%3A%3AMetaCPAN).

## credentials

The [App::BatchRelease::Credentials](https://metacpan.org/pod/App%3A%3ABatchRelease%3A%3ACredentials).

## dry\_run

True to stop after the list.  Then nothing reads standard input, and nothing
asks for credentials.

## conformant\_only

True to skip each distribution that is not in full conformance, as
["conformance\_problem"](#conformance_problem) says.

## yes

True to release without asking for confirmation.

## check\_login

True, the default, to check the credentials with PAUSE before the first
build.  See ["check\_with\_pause" in App::BatchRelease::Credentials](https://metacpan.org/pod/App%3A%3ABatchRelease%3A%3ACredentials#check_with_pause).

# METHODS

## run

`(@arguments)`.  Runs the program with the arguments of the command line,
and returns its exit status: 0 when nothing failed, 1 when a release failed,
and 2 for a mistake in the arguments or a run that stopped before the first
release, such as an unanswered question or credentials that PAUSE refused.

## plan

`(@paths)`.  Looks at each path through ["inspect"](#inspect), and orders the
distributions to release through ["order" in App::BatchRelease::Prereqs](https://metacpan.org/pod/App%3A%3ABatchRelease%3A%3APrereqs#order).
Returns a hash reference of `release`, the entries to release, in order,
and `skipped`, the entries to skip, in the order of the paths.  An entry is
what ["inspect"](#inspect) returns, and an entry to release has `needs` too, the
names of the distributions of the batch that it requires.  A distribution
that the batch cannot order, because its requirements in the batch form a
cycle, is skipped.  So is one whose requirements cannot be read, and a
second checkout of a distribution that an earlier path already gave.

## inspect

`($path)`.  An entry for one path: a hash reference of `path`, and, when
it got that far, `name`, `version` and the rest of what
["release\_state" in App::BatchRelease::State](https://metacpan.org/pod/App%3A%3ABatchRelease%3A%3AState#release_state) returns.  An entry to skip has
`skip`, the reason.  The path is skipped when:

- it is not a directory, has no `dist.ini`, or is not the top of a git
checkout, so it is not clearly a Dist::Zilla distribution;
- its `dist.ini` is not committed on the default branch, or the check of its
state fails;
- its state says that CPAN has its work, or that nothing can tell, or that
its version must be raised first: see ["due"](#due);
- it is due, but the checkout is not on its default branch, or has changes
that are not committed, because `dzil release` releases the work tree;
- it is due, ["conformant\_only"](#conformant_only) is set, and ["conformance\_problem"](#conformance_problem) finds a
problem.

It changes nothing in the checkout.

## confirm

`($plan)`.  Asks whether to release the distributions of the plan, and
returns true for `y` or `yes`, in any case.  It asks at `/dev/tty` when
the credentials came on standard input.  It dies when nobody can answer, and
says to pass `--yes`.

## release\_all

`($plan)`.  Releases each distribution of the plan, in order, through
["release" in App::BatchRelease::Release](https://metacpan.org/pod/App%3A%3ABatchRelease%3A%3ARelease#release).  A distribution that requires one of
the batch that was not released, because its release failed or because it
was skipped for that reason, is skipped.  Returns a hash reference of
`released`, `skipped` and `failed`, each a list of entries.  The skipped
ones are those of the plan and then those that this skipped, each with
`skip`, and a failed one has `error`.

The tests of a release run against the modules that are installed, and a
distribution of the batch that was released a moment ago is not installed,
nor yet indexed by CPAN.  So each release gets, through the option `lib` of
["release" in App::BatchRelease::Release](https://metacpan.org/pod/App%3A%3ABatchRelease%3A%3ARelease#release), the `lib/` of the build of each
distribution of the batch that it requires, directly or not.  The build is
what went to CPAN, with the versions that `[PkgVersion]` wrote.

When the credentials came on standard input, each release reads its own
questions from ["answers\_from" in App::BatchRelease::Prompt](https://metacpan.org/pod/App%3A%3ABatchRelease%3A%3APrompt#answers_from), the terminal or,
without one, `/dev/null`.

# FUNCTIONS

## due

`($state)`, what ["release\_state" in App::BatchRelease::State](https://metacpan.org/pod/App%3A%3ABatchRelease%3A%3AState#release_state) returns.  Undef
when the distribution is due for a release that `dzil release` can make,
else the reason that it is not:

- `never_released` and `not_uploaded` are due.
- `unreleased_commits` is due when the version comes from the tags, as with
`[Git::NextVersion]`, which gives the next release a new version.  With a
`version` in `dist.ini`, that version is on CPAN already, PAUSE refuses it
a second time, and `[Git::Tag]` refuses to write its tag again, so it is not
due until somebody raises the version.
- `released`, `no_tag` and `no_version` are not due.

## conformance\_problem

`($root)`.  Undef when the checkout `$root` is in full conformance, as
[Dist::Conformance](https://metacpan.org/pod/Dist%3A%3AConformance) defines it: ["check" in Dist::Conformance](https://metacpan.org/pod/Dist%3A%3AConformance#check) reports no check
as `fail`, which is when `conformance check` exits 0.  Else the reason,
which names each check that failed, or says why the check could not run, for
example when the checkout has no `.conformance.yml`.  It reads the
checkout, and changes nothing in it.  It fetches the standards of a git
source into the cache of [Dist::Conformance::Source::Git](https://metacpan.org/pod/Dist%3A%3AConformance%3A%3ASource%3A%3AGit).

## first\_line

`($message)`.  The first line of `$message`, without its newline.

## describe

`($entry)`.  The state of an entry to release, in words.

## version\_of

`($entry)`.  The version that the release of an entry will have, as far as
this program can tell: the version of `dist.ini`, or the next after the
version of the last tag when the tags give it.

## listing

`($plan, $verb)`, what ["plan"](#plan) returns and the words that start the list.
The text of the plan: the distributions to release, in order, each with its
version, its state, the distributions of the batch that it requires and its
path, then the ones to skip, each with its reason.

## label

`($entry)`.  The name of the distribution of an entry and its path, or only
the path when it has no name.

## summary

`($outcome)`, what ["release\_all"](#release_all) returns.  The text of the summary: the
distributions that were released, skipped, each with the reason, and
failed, each with the error.

# AUTHORS

Current Maintainers:

- George S. Baugh <george@troglodyne.net>

# CONTRIBUTOR

troglodyne-robot <trogbot@troglodyne.net>

# COPYRIGHT AND LICENSE

Copyright (c) 2026 Troglodyne LLC

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:
The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.
THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
