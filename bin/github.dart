import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:crypto/crypto.dart';
import 'package:github/github.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:path/path.dart' as p;

void main(List<String> args) async {
  final github = GitHub(
    auth: Authentication.withToken(Platform.environment['GITHUB_TOKEN']!),
  );
  final model = GenerativeModel(
    model: 'gemini-embedding-001',
    apiKey: Platform.environment['GEMINI_API_KEY']!,
  );

  final runner = CommandRunner(
    'main.dart',
    'A tool for creating and querying embeddings',
  );
  runner
    ..addCommand(CreateEmbeddings(github, model))
    ..addCommand(QueryEmbeddings(model))
    ..addCommand(GroupEmbeddings());
  await runner.run(args);
}

class CreateEmbeddings extends Command {
  final GitHub github;
  final GenerativeModel model;

  CreateEmbeddings(this.github, this.model) {
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
        defaultsTo: TaskType.retrievalDocument.name,
        allowed: TaskType.values.map((e) => e.name).toList(),
      )
      ..addOption(
        'since',
        abbr: 's',
        help: 'Only issues with activity since this date are included',
        defaultsTo: DateTime.now()
            .subtract(const Duration(days: 365))
            .toString(),
      );
  }

  @override
  String get description => 'Generates embeddings for a repo';

  @override
  String get name => 'create';

  @override
  Future<void> run() async {
    var argResults = this.argResults!;
    final issuesService = IssuesService(github);
    final repoSlug = RepositorySlug.full(argResults.option('repo')!);
    final issues = issuesService.listByRepo(
      repoSlug,
      since: DateTime.parse(argResults.option('since')!),
    );
    final taskType = taskTypeFromArg(
      argResults.option('issue-embeddings-task-type')!,
    );
    final issuesToUpdate = <Issue>[];
    await for (final issue in issues) {
      final hashFile = File(issue.contentHashPath(taskType, repoSlug));
      final String lastHash;
      if (hashFile.existsSync()) {
        lastHash = hashFile.readAsStringSync();
      } else {
        lastHash = '';
        hashFile.createSync(recursive: true);
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
    if (await stdin.readLineSync() == 'y') {
      print('Creating embeddings');
    } else {
      print('Aborting');
      return;
    }
    // Batches are limited to 100
    for (var batch = 0; batch < (issuesToUpdate.length / 100).ceil(); batch++) {
      final offset = batch * 100;
      print('Creating batch ${batch + 1} of embeddings');
      final result = await model.batchEmbedContents([
        for (var i = offset; i < issuesToUpdate.length && i < offset + 100; i++)
          EmbedContentRequest(
            Content.text(issuesToUpdate[i].content),
            taskType: taskType,
          ),
      ]);
      print('Batch embed completed');

      print('Writing embeddings to disk');
      for (var i = 0; i < result.embeddings.length; i++) {
        final issue = issuesToUpdate[i + offset];
        final embeddingsFile = File(issue.embeddingsPath(taskType, repoSlug));
        final embeddingData = Float32List.fromList(result.embeddings[i].values);
        embeddingsFile.writeAsBytesSync(embeddingData.buffer.asUint8List());
        final hashFile = File(issue.contentHashPath(taskType, repoSlug));
        hashFile.writeAsStringSync(issue.contentHash());
        print('Processed issue ${issue.number}');
      }
    }
  }
}

class QueryEmbeddings extends Command {
  final GenerativeModel model;

  QueryEmbeddings(this.model) {
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
        defaultsTo: TaskType.retrievalDocument.name,
        allowed: TaskType.values.map((e) => e.name).toList(),
      )
      ..addOption(
        'query-embeddings-task-type',
        help: 'The query embedding task type',
        defaultsTo: TaskType.retrievalQuery.name,
        allowed: TaskType.values.map((e) => e.name).toList(),
      );
  }

  @override
  String get description => 'Runs a query against embeddings for a repo';

  @override
  String get name => 'query';

  @override
  Future<void> run() async {
    var argResults = this.argResults!;
    final query = argResults.rest.join(' ');
    final repoSlug = RepositorySlug.full(argResults.option('repo')!);
    final issueTaskType = taskTypeFromArg(
      argResults.option('issue-embeddings-task-type')!,
    );
    final queryTaskType = taskTypeFromArg(
      argResults.option('query-embeddings-task-type')!,
    );
    print('getting embedding for query: $query');
    final queryEmbedding = (await model.embedContent(
      Content.text(query),
      taskType: queryTaskType,
    )).embedding.values;
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
        p.join(dir.path, '${issueTaskType.name}.embedding'),
      );
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
        defaultsTo: TaskType.clustering.name,
        allowed: TaskType.values.map((e) => e.name).toList(),
      )
      ..addOption(
        'group-threshold',
        help:
            'A number between -1 and 1, controls whether issues are grouped. '
            'Numbers closer to 1 will be more closely related.',
        defaultsTo: '0.9',
      );
  }

  @override
  String get description => 'Runs a query against embeddings for a repo';

  @override
  String get name => 'group';

  @override
  Future<void> run() async {
    var argResults = this.argResults!;
    final repoSlug = RepositorySlug.full(argResults.option('repo')!);
    final issueTaskType = taskTypeFromArg(
      argResults.option('issue-embeddings-task-type')!,
    );
    final groupThreshold = double.parse(argResults.option('group-threshold')!);

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
        p.join(dir.path, '${issueTaskType.name}.embedding'),
      );
      final embeddingData = Float32List.view(
        embeddingFile.readAsBytesSync().buffer,
      );
      embeddings[issueNumber] = embeddingData;
      for (final MapEntry(:key, :value) in embeddings.entries) {
        if (key == issueNumber) continue;

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
      print("## New Group");
      for (final issue in group) {
        print('https://github.com/${repoSlug.fullName}/issues/$issue');
      }
    }
  }
}

TaskType taskTypeFromArg(String arg) {
  return TaskType.values.firstWhere((taskType) => taskType.name == arg);
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
      p.join(issueDir(slug), '${taskType.name}.contentHash');
  String embeddingsPath(TaskType taskType, RepositorySlug slug) =>
      p.join(issueDir(slug), '${taskType.name}.embedding');
  String get content =>
      '''
# $title

$body
''';

  String contentHash() => md5.convert(utf8.encode(content)).toString();
}
