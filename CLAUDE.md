# Repository Guidelines

## Git workflow

This is a solo hobby project. Pull requests are unnecessary: commit and push
changes directly to `main` unless the user explicitly requests a branch or pull
request.

## Deploy local app changes

Any workflow that commits and pushes local CatGuard changes is incomplete until
the updated app is also installed and running locally:

1. Build a fresh signed Release app, supplying the maintainer's Development Team
   only at build time. Never commit the Team ID.
2. Verify the built app's code signature.
3. Quit the currently running CatGuard before replacing it.
4. Replace `/Applications/CatGuard.app` with the newly built Release app.
5. Relaunch `/Applications/CatGuard.app` and verify that the installed build is
   running successfully.
