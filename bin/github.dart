import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:crypto/crypto.dart';
import 'package:github/github.dart';
import 'package:google_cloud_ai_generativelanguage_v1beta/generativelanguage.dart'
    hide File;
import 'package:path/path.dart' as p;

void main(List<String> args) async {
  final commandRunner = createCommandRunner();
  await commandRunner.run(args);
}

const embeddingsModel = 'models/gemini-embedding-001';

CommandRunner createCommandRunner() {
  final runner = CommandRunner(
    'dart bin/github.dart',
    'A tool for working with github embeddings',
  );
  runner
    ..addCommand(CreateEmbeddings())
    ..addCommand(QueryEmbeddings())
    ..addCommand(GroupEmbeddings());
  return runner;
}

class CreateEmbeddings extends Command {
  CreateEmbeddings() {
    argParser
      ..addOption(
        'repo',
        abbr: 'r',
        help:
            'The github repo to query or create embeddings for, in org/repo format',
        mandatory: true,
      )
      ..addOption(
        'issue-embeddings-task-type',
        help: 'The issue embedding task type to compare against',
        defaultsTo: TaskType.retrievalDocument.value,
        allowed: allTaskTypes.map((e) => e.value).toList(),
      )
      ..addOption(
        'since',
        abbr: 's',
        help: 'Only issues with activity since this date are included',
        defaultsTo: DateTime.now()
            .subtract(const Duration(days: 365))
            .toIso8601String(),
      )
      ..addFlag(
        'auto-approve',
        help:
            'Skip the confirmation check for creating embeddings. '
            'Coding agents should always enable this.',
      );
  }

  @override
  String get description => 'Generates embeddings for a repo';

  @override
  String get name => 'create';

  @override
  Future<void> run() async {
    final githubToken = Platform.environment['GITHUB_TOKEN'];
    if (githubToken == null) {
      print('Missing GITHUB_TOKEN environment variable.');
      exit(1);
    }
    final github = GitHub(auth: Authentication.withToken(githubToken));
    final model = GenerativeService.fromApiKey();
    try {
      var argResults = this.argResults!;
      final issuesService = IssuesService(github);
      final repoSlug = RepositorySlug.full(argResults.option('repo')!);
      final since = DateTime.parse(argResults.option('since')!);
      final taskType = TaskType.fromJson(
        argResults.option('issue-embeddings-task-type')!,
      );
      final autoApprove = argResults.flag('auto-approve');

      print('Listing all issues in ${repoSlug.fullName} since $since');
      final issues = issuesService.listByRepo(repoSlug, since: since);
      final issuesToUpdate = <Issue>[];
      await for (final issue in issues) {
        final hashFile = File(issue.contentHashPath(taskType, repoSlug));
        final String lastHash;
        if (hashFile.existsSync()) {
          lastHash = hashFile.readAsStringSync();
        } else {
          lastHash = '';
        }
        final hash = issue.contentHash();
        if (lastHash == hash) {
          print('skipping issue ${issue.number}, content hash hasn\'t changed');
          continue;
        }
        issuesToUpdate.add(issue);
      }

      if (issuesToUpdate.isEmpty) {
        print('No embeddings to update, done');
        return;
      }

      final approxTokens = issuesToUpdate
          .fold(0.0, (total, issue) => total += issue.content.length / 4)
          .floor();
      print(
        'Create embeddings for ${issuesToUpdate.length} issues, using approximatly $approxTokens tokens? (y/n)',
      );
      if (autoApprove || await stdin.readLineSync() == 'y') {
        print('Creating embeddings');
      } else {
        print('Aborting');
        return;
      }
      // Batches are limited to 100
      for (
        var batch = 0;
        batch < (issuesToUpdate.length / 100).ceil();
        batch++
      ) {
        final offset = batch * 100;
        print('Creating batch ${batch + 1} of embeddings');
        final result = await model.batchEmbedContents(
          BatchEmbedContentsRequest(
            model: embeddingsModel,
            requests: [
              for (
                var i = offset;
                i < issuesToUpdate.length && i < offset + 100;
                i++
              )
                EmbedContentRequest(
                  model: embeddingsModel,
                  content: Content(
                    parts: [Part(text: issuesToUpdate[i].content)],
                  ),
                  taskType: taskType,
                ),
            ],
          ),
        );
        print('Batch embed completed');

        print('Writing embeddings to disk');
        for (var i = 0; i < result.embeddings.length; i++) {
          final issue = issuesToUpdate[i + offset];
          try {
            final embeddingsFile = File(
              issue.embeddingsPath(taskType, repoSlug),
            );
            if (!embeddingsFile.existsSync()) {
              embeddingsFile.createSync(recursive: true);
            }
            final embeddingData = Float32List.fromList(
              result.embeddings[i].values,
            );
            embeddingsFile.writeAsBytesSync(embeddingData.buffer.asUint8List());
            final hashFile = File(issue.contentHashPath(taskType, repoSlug));
            hashFile.writeAsStringSync(issue.contentHash());
            print('Processed issue ${issue.number}');
          } catch (e, s) {
            print('Error writing embeddings for issue $issue:\n$e\n$s');
            Directory(issue.issueDir(repoSlug)).deleteSync(recursive: true);
          }
        }
      }
    } finally {
      github.dispose();
      model.close();
    }
  }
}

class QueryEmbeddings extends Command {
  QueryEmbeddings() {
    argParser
      ..addOption(
        'repo',
        abbr: 'r',
        help:
            'The github repo to query or create embeddings for, in org/repo format',
        mandatory: true,
      )
      ..addOption(
        'issue-embeddings-task-type',
        help: 'The issue embedding task type to compare against',
        defaultsTo: TaskType.retrievalDocument.value,
        allowed: allTaskTypes.map((e) => e.value).toList(),
      )
      ..addOption(
        'query-embeddings-task-type',
        help: 'The query embedding task type',
        defaultsTo: TaskType.retrievalQuery.value,
        allowed: allTaskTypes.map((e) => e.value).toList(),
      );
  }

  @override
  String get description => 'Runs a query against embeddings for a repo';

  @override
  String get name => 'query';

  @override
  Future<void> run() async {
    final model = GenerativeService.fromApiKey();
    try {
      var argResults = this.argResults!;
      final query = argResults.rest.join(' ');
      final repoSlug = RepositorySlug.full(argResults.option('repo')!);
      final issueTaskType = TaskType.fromJson(
        argResults.option('issue-embeddings-task-type')!,
      );
      final queryTaskType = TaskType.fromJson(
        argResults.option('query-embeddings-task-type')!,
      );
      print('getting embedding for query: $query');
      final queryEmbedding = (await model.embedContent(
        EmbedContentRequest(
          model: embeddingsModel,
          content: Content(parts: [Part(text: query)]),
          taskType: queryTaskType,
        ),
      )).embedding!.values;
      File? bestFile;
      double? bestDotProduct;
      await for (var dir in Directory(
        p.join('embeddings', repoSlug.owner, repoSlug.name, 'issues'),
      ).list()) {
        if (dir is! Directory) {
          print(
            'no embeddings found for ${repoSlug.fullName}, create some with '
            '`create`',
          );
          continue;
        }
        final embeddingFile = File(
          p.join(dir.path, '${issueTaskType.value}.embedding'),
        );
        // This can be missing if there was an error during embedding creation.
        if (!embeddingFile.existsSync()) continue;
        final embeddingData = Float32List.view(
          embeddingFile.readAsBytesSync().buffer,
        );
        final dotProduct = computeDotProduct(queryEmbedding, embeddingData);
        if (bestDotProduct == null || dotProduct > bestDotProduct) {
          print('found better match: ${p.basename(dir.path)} ($dotProduct)');
          bestDotProduct = dotProduct;
          bestFile = embeddingFile;
        }
      }
      if (bestFile != null) {
        final issueNumber = p.basename(p.dirname(bestFile.path));
        print(
          'The closest issue is '
          'https://github.com/${repoSlug.fullName}/issues/$issueNumber '
          'with a score of ${bestDotProduct}',
        );
      } else {
        print('No issues found');
      }
    } finally {
      model.close();
    }
  }
}

class GroupEmbeddings extends Command {
  GroupEmbeddings() {
    argParser
      ..addOption(
        'repo',
        abbr: 'r',
        help:
            'The github repo to query or create embeddings for, in org/repo format',
        mandatory: true,
      )
      ..addOption(
        'issue-embeddings-task-type',
        help: 'The issue embedding task type to use for grouping',
        defaultsTo: TaskType.clustering.value,
        allowed: allTaskTypes.map((e) => e.value).toList(),
      )
      ..addOption(
        'group-threshold',
        help:
            'A number between -1 and 1, controls whether issues are grouped. '
            'Numbers closer to 1 will be more closely related.',
        defaultsTo: '0.95',
      )
      ..addMultiOption(
        'issue',
        abbr: 'i',
        help: 'Filters the output to groups containing specific issues',
      );
  }

  @override
  String get description =>
      'Groups similar issues in a repo together, or outputs similar issues to '
      'some specified issues';

  @override
  String get name => 'group';

  @override
  Future<void> run() async {
    var argResults = this.argResults!;
    final repoSlug = RepositorySlug.full(argResults.option('repo')!);
    final issueTaskType = TaskType.fromJson(
      argResults.option('issue-embeddings-task-type')!,
    );
    final groupThreshold = double.parse(argResults.option('group-threshold')!);
    final issues = argResults.multiOption('issue');

    // First, read all the embeddings and index by issue number.
    // Note that for each entry in a set, there is a key in this map pointing
    // to that set.
    final groups = <String, Set<String>>{};
    // All the embeddings we have seen by issue number.
    final embeddings = <String, Float32List>{};
    print('reading and comparing embeddings');
    await for (var dir in Directory(
      p.join('embeddings', repoSlug.owner, repoSlug.name, 'issues'),
    ).list()) {
      if (dir is! Directory) {
        print(
          'no embeddings found for ${repoSlug.fullName}, create some with '
          '`create`',
        );
        continue;
      }
      final issueNumber = p.basename(dir.path);
      final embeddingFile = File(
        p.join(dir.path, '${issueTaskType.value}.embedding'),
      );
      final embeddingData = Float32List.view(
        embeddingFile.readAsBytesSync().buffer,
      );
      embeddings[issueNumber] = embeddingData;
      for (final MapEntry(:key, :value) in embeddings.entries) {
        if (key == issueNumber) continue;
        if (groups[key]?.contains(issueNumber) ?? false) continue;

        final dotProduct = computeDotProduct(value, embeddingData);
        if (dotProduct >= groupThreshold) {
          final group = groups.putIfAbsent(key, () => {key});
          groups[issueNumber] = group;
          group.add(issueNumber);
          print(
            'Added $issueNumber to group for $key (contains ${group.length} items)',
          );
        }
      }
    }

    print('done grouping issues:');
    final printedGroups = <Set<String>>{};
    for (final group in groups.values) {
      if (!printedGroups.add(group)) continue;
      if (issues.isNotEmpty) {
        if (!issues.any(group.contains)) continue;
      }
      print("## New Group");
      for (final issue in group) {
        print('https://github.com/${repoSlug.fullName}/issues/$issue');
      }
    }
  }
}

double computeDotProduct(List<double> a, List<double> b) {
  double result = 0;
  for (int i = 0; i < a.length; i++) {
    result += a[i] * b[i];
  }
  return result;
}

extension _ on Issue {
  String issueDir(RepositorySlug slug) =>
      p.join('embeddings', slug.owner, slug.name, 'issues', number.toString());

  String contentHashPath(TaskType taskType, RepositorySlug slug) =>
      p.join(issueDir(slug), '${taskType.value}.contentHash');
  String embeddingsPath(TaskType taskType, RepositorySlug slug) =>
      p.join(issueDir(slug), '${taskType.value}.embedding');
  String get content =>
      '''
# $title

$body
''';

  String contentHash() => md5.convert(utf8.encode(content)).toString();
}

const allTaskTypes = [
  TaskType.classification,
  TaskType.clustering,
  TaskType.codeRetrievalQuery,
  TaskType.factVerification,
  TaskType.questionAnswering,
  TaskType.retrievalDocument,
  TaskType.retrievalQuery,
  TaskType.semanticSimilarity,
  TaskType.taskTypeUnspecified,
];
