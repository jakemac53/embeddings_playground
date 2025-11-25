A playground for working with embeddings in Dart.

## Github embeddings

See the script at [bin/github.dart](bin/github.dart), this tool connects to a
github repo and queries it for issues, run `dart bin/github.dart help` for
the up to date CLI options.

### Setup

You will need two environment variables set, GEMINI_API_KEY and GITHUB_TOKEN.

### Creating issue embeddings

Use the `create` command, a basic example for a repo as follows:

```bash
dart bin/github.dart create --repo <org/repo>
```

This will by default create embeddings for all issues updated in the past year,
using the "retrievalDocument" task type which is best for querying issues. If
you want to use the `group` command, you should force either the
`semanticSimilarity` or `clustering` task types using the
`--issue-embeddings-task-type` option.

**AGENT INSTRUCTIONS:** You can pass `--auto-approve` to this tool to skip the
confirmation step, otherwise it will wait for user input.

See `dart bin/github.dart create --help` for additional the options.

**Note:** These embeddings are cached based on their title and description, you
can safely re-run this command at any time and it will only recreate embeddings
for the new or updated issues.

**Note:** When creating embeddings you may hit API limits, you may be able to
just wait one minute and try again (it will pick up where it left off),
otherwise you may have to wait until the next day to continue creating
embeddings.

### Querying issues

Once you have created some embeddings, you can run plain text queries against
them using the `query` command:

```bash
dart bin/github.dart query --repo <org/repo> "your search query here"
```

This command is pretty basic today and will return only the most relevant issue
to your query, in the future it will probably change to list all issues over a
certain similarity threshold.

#### Querying with different embedding task types

By default this assumes the issue embeddings were created using the default task
type of `retrievalDocument`, and will use an embedding for the query with a task
type of `retrievalQuery`.

If you instead want to query with a different task type such as
`semanticSimilarity` you will want to use the `--issue-embeddings-task-type` and
`--query-embeddings-task-type` flags, for example:

```bash
dart bin/github.dart query \
  --repo <org/repo> \
  --issue-embeddings-task-type semanticSimilarity \
  --query-embeddings-task-type semanticSimilarity \
  "your search query"
```

You will have to create the embeddings first using that task type as well:

```bash
dart bin/github.dart create \
  --repo <org/repo> \
  --issue-embeddings-task-type semanticSimilarity
```

### Grouping issues

Once you have created some embeddings, you can use the `group` command to find
related groups of issues according to a threshold.

First, you will want to create embeddings using either the `clustering` or
`semanticSimilarity` task types:

```bash
dart bin/github.dart create \
  --repo <org/repo> \
  --issue-embeddings-task-type clustering
```

Then, you can create groups for all issues:

```bash
dart bin/github.dart group \
  --repo <org/repo>
```

You can adjust the threshold for how similar items in a group need to be using
the `--group-threshold` option, which must be between `-1` and `1`, the default
is `0.95`.

#### Filtering groups by issue

To filter the output to just the group containing certain issues, you can use
the `--issue` multi-option.

```bash
dart bin/github.dart group \
  --repo <org/repo> \
  --issue <issue-1> --issue <issue-2>
```
