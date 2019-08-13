import '../../context.dart';
import '../../parser.dart';
import '../core.dart';

class IncludeStatement extends Statement {
  static IncludeStatement parse(Parser parser) {
    final path = parser.parsePrimary();
    parser.scanner.expect(parser.blockEndReg);
    return IncludeStatement(path);
  }

  IncludeStatement(this.path);

  final Expression path;

  @override
  void accept(StringBuffer buffer, Context context) {
    final path = this.path.resolve(context);

    if (path is String) {
      final template = context.env.getTemplate(path);
      template.accept(buffer, context);
    } else {
      // Подробный текст проблемы: путь должен быть строкой
      throw Exception(path.runtimeType);
    }
  }

  @override
  String toDebugString([int level = 0]) =>
      ' ' * level + '# include: ${path.toDebugString()}';

  @override
  String toString() => 'Include($path})';
}