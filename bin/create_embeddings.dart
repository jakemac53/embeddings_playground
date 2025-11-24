import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:github/github.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:path/path.dart' as p;

void main() async {
  final github = GitHub(
    auth: Authentication.withToken(Platform.environment['GITHUB_TOKEN']!),
  );
  final model = GenerativeModel(
    model: 'gemini-embedding-001',
    apiKey: Platform.environment['GEMINI_API_KEY']!,
  );

  final issuesService = IssuesService(github);
  final issues = issuesService.listByRepo(
    RepositorySlug('dart-lang', 'test'),
    since: DateTime(2025, 6, 1),
  );
  await for (final issue in issues) {
    final issuePath = p.join('embeddings', 'issues', issue.number.toString());
    final hashFile = File(p.join(issuePath, 'content.hash'));
    final String lastHash;
    if (hashFile.existsSync()) {
      lastHash = hashFile.readAsStringSync();
    } else {
      lastHash = '';
      hashFile.createSync(recursive: true);
    }
    final content =
        '''
# ${issue.title}
${issue.body}
''';
    final hash = md5.convert(utf8.encode(content)).toString();
    if (lastHash == hash) {
      print('skipping issue ${issue.number}, content hash hasn\'t changed');
      continue;
    }

    try {
      final embeddingsFile = File(p.join(issuePath, 'primary.embedding'));
      embeddingsFile.createSync(recursive: true);
      final issueEmbedding = await model.embedContent(
        Content.text(issue.body),
        taskType: TaskType.retrievalDocument,
        title: issue.title,
      );
      final embeddingData = Float32List.fromList(
        issueEmbedding.embedding.values,
      );
      embeddingsFile.writeAsBytesSync(embeddingData.buffer.asUint8List());
      hashFile.writeAsStringSync(hash);
      print('Processed issue ${issue.number}');
    } catch (e) {
      print('Failed to process issue ${issue.number}: $e');
    }
  }
}
