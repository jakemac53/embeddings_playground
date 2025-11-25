import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:dart_mcp/stdio.dart';
import 'package:dart_mcp/server.dart';

import 'github.dart';

void main() {
  GithubIssueEmbeddingsServer.fromStreamChannel(
    stdioChannel(input: stdin, output: stdout),
  );
}

final class GithubIssueEmbeddingsServer extends MCPServer with ToolsSupport {
  GithubIssueEmbeddingsServer.fromStreamChannel(super.channel)
    : super.fromStreamChannel(
        implementation: Implementation(
          name: 'GithubIssuesEmbeddings',
          version: '0.0.1',
        ),
      ) {
    final commandRunner = createCommandRunner();
    for (var command in commandRunner.commands.values) {
      registerTool(toolFromCommand(command), toolImplForCommand(command));
    }
  }
}

Tool toolFromCommand(Command command) {
  return Tool(
    name: command.name,
    description: command.description,
    inputSchema: ObjectSchema(
      properties: {
        for (final option in command.argParser.options.values)
          option.name: schemaForOption(option),
        if (command is QueryEmbeddings)
          'query': Schema.string(description: 'The search query'),
      },
      required: [
        for (final option in command.argParser.options.values)
          if (option.mandatory) option.name,
      ],
    ),
  );
}

Schema schemaForOption(Option option) {
  if (option.isFlag) {
    return Schema.bool(description: option.help);
  } else if (option.isSingle) {
    return Schema.string(enumValues: option.allowed, description: option.help);
  } else if (option.isMultiple) {
    return Schema.list(
      items: Schema.string(enumValues: option.allowed),
      description: option.help,
    );
  } else {
    throw StateError('Unsupported option $option');
  }
}

Future<CallToolResult> Function(CallToolRequest request) toolImplForCommand(
  Command command,
) {
  return (CallToolRequest request) async {
    final arguments = [
      command.name,
      for (final MapEntry(:key, :value) in request.arguments?.entries ?? [])
        if (key == 'query' && command is QueryEmbeddings)
          '"$value"'
        else if (value is bool)
          value == true ? '--$key' : '--no-$key'
        else if (value is List)
          for (var entry in value) '--$key=$entry'
        else
          '--$key=$value',
    ];
    final process = await Process.run('out/github.exe', arguments);
    return CallToolResult(
      content: [
        if (process.stdout.isNotEmpty) Content.text(text: process.stdout),
        if (process.stderr.isNotEmpty)
          Content.text(text: 'StdErr: ${process.stderr}'),
      ],
      isError: process.exitCode != 0,
    );
  };
}
