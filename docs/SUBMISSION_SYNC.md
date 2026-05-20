# Submission repository sync

## Recommended shape

Use a fork of the target repository as the submission repository whenever
possible. GitHub pull requests work most reliably when the source branch lives in a fork of the target repository.

```text
this repo -> your fork/submission branch -> target repo pull request
```

Avoid manually copying files. Push a branch from this repository into the
submission remote and keep that branch updated with Git.

## One-time setup

From this repository, add the submission repository as an extra remote:

```bash
git remote add submission git@github.com:<your-user>/<submission-repo>.git
```

Check the remotes:

```bash
git remote -v
```

## Initial sync

Push the current local `main` branch into a branch in the submission repository:

```bash
git push submission main:submission/fraud-detector
```

Open the pull request from:

```text
<your-user>/<submission-repo>:submission/fraud-detector
```

into the target repository branch requested by the assignment, usually:

```text
<target-org>/<target-repo>:main
```

## Keep the pull request updated

After making changes in this repository, push the same branch again:

```bash
git push submission main:submission/fraud-detector
```

If the submission branch is only a mirror of this repository and nobody edits it directly on GitHub, update it with:

```bash
git push submission main:submission/fraud-detector --force-with-lease
```

Use `--force-with-lease` instead of `--force`; it refuses to overwrite remote changes that were added after the last fetch.

## If the target repo has unrelated history

If GitHub says the branches cannot be compared, the target repository already has history that is unrelated to this repository. In that case, create a branch from the target repository's base branch and overlay this repository's files onto it.

One practical local setup:

```bash
git clone git@github.com:<your-user>/<submission-repo>.git ../fraud-detector-submission
cd ../fraud-detector-submission
git checkout -b submission/fraud-detector origin/main
```

Then sync files from this repository into that checkout, excluding Git metadata and local Terraform artifacts:

```bash
rsync -a --delete \
  --exclude .git \
  --exclude .terraform \
  --exclude '*.tfstate' \
  --exclude '*.tfstate.backup' \
  --exclude app/results_writer/build \
  --exclude layers/psycopg2/psycopg2-layer.zip \
  ../fraud-detector-terraform/ ./
```

Commit and push the overlay branch:

```bash
git add -A
git commit -m "Add fraud detector Terraform lab"
git push -u origin submission/fraud-detector
```

To update the pull request later, rerun the same `rsync`, commit the resulting diff, and push.

## Workflow behavior on the pull request

The `Validate` workflow runs automatically on pull requests and pushes. It only builds local artifacts, runs `terraform fmt -check -recursive`, initializes Terraform without a backend, and runs `terraform validate`.

The operational workflows are manual:

- `Plan`
- `Deploy`
- `Destroy`
- `Send test transactions`

Run `Plan` manually after validation when the branch is ready for infrastructure review. Run `Deploy` only from the branch that should actually update AWS, normally after the pull request has been merged.
