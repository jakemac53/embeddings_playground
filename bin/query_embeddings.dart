import 'dart:io';

import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:path/path.dart' as p;
import 'package:vector_math/vector_math.dart';

void main(List<String> args) async {
  final model = GenerativeModel(
    model: 'gemini-embedding-001',
    apiKey: Platform.environment['GEMINI_API_KEY']!,
  );
  final query = args.join(' ');
  print('getting embedding for query: $query');
  final queryEmbedding = await model.embedContent(
    Content.text(query),
    taskType: TaskType.retrievalQuery,
  );
  final queryVector = Vector2.array(queryEmbedding.embedding.values);
  File? bestFile;
  double? bestDotProduct;
  await for (var dir in Directory(p.join('embeddings', 'issues')).list()) {
    if (dir is! Directory) continue;
    final embeddingFile = File(p.join(dir.path, 'primary.embedding'));
    final embeddingData = embeddingFile.readAsBytesSync();
    final embeddingVector = Vector2.fromBuffer(embeddingData.buffer, 0);
    final dotProduct = queryVector.dot(embeddingVector);
    if (bestDotProduct == null || dotProduct > bestDotProduct) {
      print('found better match: ${p.basename(dir.path)} ($dotProduct)');
      bestDotProduct = dotProduct;
      bestFile = embeddingFile;
    }
  }
  if (bestFile != null) {
    final issueNumber = p.basename(p.dirname(bestFile.path));
    print('The closest issue is $issueNumber');
  } else {
    print('No issues found');
  }
}
