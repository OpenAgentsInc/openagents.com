# OpenAgents - The Agent Forge

OpenAgents is a source-code forge. We are building it to replace GitHub for our own projects, and then for customers. This repository is the public home of the project.

## What we are building

We are building the Agent Forge from scratch. This is a clean-room, independent implementation. It does not use code or design from any earlier internal or external forge.

The first public surface is an issue and project tracker. We will use the Agent Forge to build OpenAgents.com itself. Every change ships through the forge with live hot reload.

## Why start from scratch

Starting fresh lets us build a forge that is open, contributor-friendly, and defined by its own runtime behavior rather than by compatibility with an existing platform. The BEAM runtime, Phoenix LiveView, and hot reload are the implementation choices.

## What works now

- **Hot reload:** code changes reach the live cluster in seconds without a rolling restart.
- **Release upgrades (relups):** deploys use Erlang/OTP release upgrade patterns for zero-downtime updates.
- **Live surfaces:** pages update for every connected viewer at the same time through Phoenix PubSub.

## Tech stack

- **Elixir on the BEAM** — the runtime for hot reload, release upgrades, and live, concurrent page updates.
- **Phoenix and Phoenix LiveView** — web framework and live UI layer.
- **PostgreSQL** — primary database.
- **Google Cloud** — hosting and infrastructure.
- **Tailwind CSS** — styling.
- **DaisyUI** — UI component library.

## First deliverable: Issues and projects

The first public surface is an issue and project tracker. We will use it to run OpenAgents.com's own development. You can:

- Open issues.
- Create and manage projects.
- Watch updates appear live for everyone else on the page.
- See the deploy receipts for each change.

## For contributors

We want contributing to feel good. The first contributor features are:

- Log in with GitHub.
- See a leaderboard of contributions.
- Get credit for code that trains our agents, when we build that part.

## What's next

After issues and projects, we will make it easy to import repositories into OpenAgents.com. The goal is to let you bring an existing project onto the forge and get the same live, receipted, hot-reload experience.

## Roadmap

| Phase | Work | Outcome |
| --- | --- | --- |
| 1 | Issues and projects | Public tracker for OpenAgents.com |
| 2 | GitHub login and leaderboard | Contributor accounts and recognition |
| 3 | Repository import | Move projects onto the forge |
| 4 | Pull requests and reviews | Agent-native review flow |
| 5 | Transparency tiers | Paid and public access levels |

## Contributing

We are in the early phase. If you want to help, open an issue or watch for `good first issue` labels.

## License

This project is licensed under the GNU Affero General Public License v3.0. See `LICENSE`.
