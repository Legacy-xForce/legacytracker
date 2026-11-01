# Formatting rules

The phone (`src/client/lib/src/core/formatters.dart`) and the web app
(`src/web/src/lib/format.ts`) format durations, distances and speeds with two
implementations of one spec. `docs/formatting-fixtures.json` is that spec as a
table of input → expected string; `src/client/test/formatters_fixtures_test.dart`
and `src/web/src/test/format-fixtures.test.ts` both assert against it, so the two
cannot drift apart silently. Change a rule by editing the fixture and both
implementations.

- Trip durations truncate to whole minutes and never read below `1m`.
- Metres per second convert to km/h with `msToKmh`; never open-code the factor.
