# Signing in

Identity comes from GitHub. There is no separate OpenAgents password.

## How it works

Choose **Sign in with GitHub** and approve the authorization. You return to the
application signed in.

Your account is keyed to your numeric GitHub id, not your login name. Renaming
yourself on GitHub therefore keeps your account, your history, and your
attribution intact — a login name is a label, not an identity.

## What is stored

A scoped GitHub access token is retained so the application can read
repositories on your behalf. It is encrypted at rest and never sent to the
browser.

## Signing out

**Log out** from the account menu ends the session. It does not revoke the
GitHub authorization; do that from GitHub's application settings if you want
the grant removed entirely.
