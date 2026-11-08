# GitHub Pull Requests

GitHub Review Requests (`prr`) and My Pull Requests (`prs`): `once` lists from the GitHub search API, with open, copy-link and inline detail actions per pull request.
Needs the `GITHUB_TOKEN` secret (a token that can read your repositories): `wicket secret set github-prs GITHUB_TOKEN`. A rejected token, the rate limit and network failures each get their own error message.
With `GITHUB_PRS_FIXTURE_DIR=fixture` the canned answers in `fixture/` stand in for the API, so `GITHUB_PRS_FIXTURE_DIR=fixture wicket run . my-prs` works offline.
