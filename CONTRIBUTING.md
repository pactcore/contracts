# Contributing

Thanks for contributing to PACT Contracts.

## Development Setup

```bash
forge soldeer install
forge fmt
forge build
forge test -vvv
```

## Pull Request Expectations

- keep changes focused and reviewable
- add or update tests for behavior changes
- run formatting and tests before opening or updating a PR
- prefer descriptive commit messages that explain the change
- avoid machine-specific paths or local environment details in commits, PR bodies, and comments

## Contract Changes

For Solidity changes, include:
- the motivation and expected behavior
- any state transition or permissioning changes
- test coverage for success and failure paths

## Documentation

If a change affects the protocol surface, update `README.md` and any relevant inline documentation.
