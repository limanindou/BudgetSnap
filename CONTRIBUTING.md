# Contributing

Thanks for contributing to BudgetSnap.

## Before You Change Anything

- keep changes focused and easy to review
- avoid committing credentials, account ids, or private deployment URLs
- preserve the public, reusable nature of this repository

## Development Guidelines

- keep the frontend dependency-light unless a new dependency has a clear payoff
- prefer configuration over hardcoded AWS resource names
- keep Lambda handlers small and explicit
- keep request and response payloads backward-compatible when possible

## Pull Requests

Please include:

- a short summary of the change
- any AWS resources or permissions affected
- local or deployment validation steps
- screenshots only when the UI changed materially

## Security

If you find a security issue, do not open a public issue with secrets or exploit details. Share a minimal reproduction without credentials and rotate any exposed values immediately.