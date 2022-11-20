import 'package:jinja/src/context.dart';
import 'package:jinja/src/environment.dart';
import 'package:jinja/src/exceptions.dart';
import 'package:jinja/src/loop.dart';
import 'package:jinja/src/markup.dart';
import 'package:jinja/src/namespace.dart';
import 'package:jinja/src/nodes.dart';
import 'package:jinja/src/utils.dart';
import 'package:jinja/src/visitor.dart';

class RenderContext extends Context {
  RenderContext(
    super.environment, {
    Map<String, List<Block>>? blocks,
    super.parent,
    super.data,
  }) : blocks = blocks ?? <String, List<Block>>{};

  final Map<String, List<Block>> blocks;

  @override
  RenderContext derived({
    Map<String, List<Block>>? blocks,
    Map<String, Object?>? data,
  }) {
    return RenderContext(
      environment,
      blocks: blocks ?? this.blocks,
      parent: context,
      data: data,
    );
  }

  Map<String, Object?> save(Map<String, Object?> map) {
    var save = <String, Object?>{};

    for (var key in map.keys) {
      save[key] = context[key];
      context[key] = map[key];
    }

    return save;
  }

  void restore(Map<String, Object?> map) {
    context.addAll(map);
  }

  void set(String key, Object? value) {
    context[key] = value;
  }

  bool remove(String name) {
    if (context.containsKey(name)) {
      context.remove(name);
      return true;
    }

    return false;
  }

  Object finalize(Object? object) {
    return environment.finalize(this, object);
  }

  void assignTargets(Object? target, Object? current) {
    if (target is String) {
      set(target, current);
      return;
    }

    if (target is List<String>) {
      var values = list(current);

      if (values.length < target.length) {
        throw StateError('not enough values to unpack.');
      }

      if (values.length > target.length) {
        throw StateError('too many values to unpack.');
      }

      for (var i = 0; i < target.length; i++) {
        set(target[i], values[i]);
      }

      return;
    }

    if (target is NamespaceValue) {
      var namespace = resolve(target.name);

      if (namespace is Namespace) {
        namespace[target.item] = current;
        return;
      }

      throw TemplateRuntimeError('non-namespace object.');
    }

    throw TypeError();
  }
}

class StringSinkRenderContext extends RenderContext {
  StringSinkRenderContext(
    super.environment,
    this.sink, {
    super.blocks,
    super.parent,
    super.data,
  });

  final StringSink sink;

  @override
  StringSinkRenderContext derived({
    StringSink? sink,
    Map<String, List<Block>>? blocks,
    Map<String, Object?>? data,
  }) {
    return StringSinkRenderContext(
      environment,
      sink ?? this.sink,
      blocks: blocks ?? this.blocks,
      parent: context,
      data: data,
    );
  }

  void write(Object? object) {
    sink.write(object);
  }
}

class StringSinkRenderer extends Visitor<StringSinkRenderContext, void> {
  const StringSinkRenderer();

  @override
  void visitAll(List<Node> nodes, StringSinkRenderContext context) {
    for (var node in nodes) {
      node.accept(this, context);
    }
  }

  @override
  void visitAssign(Assign node, StringSinkRenderContext context) {
    var target = node.target.resolve(context);
    var values = node.value.resolve(context);
    context.assignTargets(target, values);
  }

  @override
  void visitAssignBlock(AssignBlock node, StringSinkRenderContext context) {
    var target = node.target.resolve(context);
    var buffer = StringBuffer();
    var derived = context.derived(sink: buffer);
    node.body.accept(this, derived);

    Object? value = buffer.toString();
    var filters = node.filters;

    if (filters == null || filters.isEmpty) {
      if (context.autoEscape) {
        value = Markup.escaped(value);
      }

      context.assignTargets(target, value);
      return;
    }

    // TODO: replace with Filter { BlockExpression ( AssignBlock ) }
    for (var filter in filters) {
      Object? callback(List<Object?> positional, Map<Symbol, Object?> named) {
        positional = <Object?>[value, ...positional];
        return context.filter(filter.name, positional, named);
      }

      value = filter.apply(context, callback);
    }

    if (context.autoEscape) {
      value = Markup.escaped(value);
    }

    context.assignTargets(target, value);
  }

  @override
  void visitAutoEscape(AutoEscape node, StringSinkRenderContext context) {
    var current = context.autoEscape;
    context.autoEscape = boolean(node.value.resolve(context));
    node.body.accept(this, context);
    context.autoEscape = current;
  }

  @override
  void visitBlock(Block node, StringSinkRenderContext context) {
    var blocks = context.blocks[node.name];

    if (blocks == null || blocks.isEmpty) {
      node.body.accept(this, context);
    } else {
      if (node.required) {
        if (blocks.length == 1) {
          throw TemplateRuntimeError("required block '${node.name}' not found");
        }
      }

      var first = blocks[0];
      var index = 0;

      if (first.hasSuper) {
        String parent() {
          if (index < blocks.length - 1) {
            var parentBlock = blocks[index += 1];
            parentBlock.body.accept(this, context);
            return '';
          }

          // TODO: add error message
          throw TemplateRuntimeError();
        }

        context.set('super', parent);
        first.body.accept(this, context);
        context.remove('super');
      } else {
        first.body.accept(this, context);
      }
    }
  }

  @override
  void visitData(Data node, StringSinkRenderContext context) {
    context.write(node.data);
  }

  @override
  void visitDo(Do node, StringSinkRenderContext context) {
    node.expression.resolve(context);
  }

  @override
  void visitExpression(Expression node, StringSinkRenderContext context) {
    var resolved = node.resolve(context);
    var finalized = context.finalize(resolved);
    var escaped = context.escape(finalized);
    context.write(escaped);
  }

  @override
  void visitExtends(Extends node, StringSinkRenderContext context) {
    var template = context.environment.getTemplate(node.path);
    template.body.accept(this, context);
  }

  @override
  void visitFilterBlock(FilterBlock node, StringSinkRenderContext context) {
    var buffer = StringBuffer();
    node.body.accept(this, context.derived(sink: buffer));

    Object? value = buffer.toString();

    for (var filter in node.filters) {
      Object? callback(List<Object?> positional, Map<Symbol, Object?> named) {
        positional = <Object?>[value, ...positional];
        return context.filter(filter.name, positional, named);
      }

      value = filter.apply(context, callback);
    }

    context.write(value);
  }

  @override
  void visitFor(For node, StringSinkRenderContext context) {
    var targets = node.target.resolve(context);
    var iterable = node.iterable.resolve(context);
    var orElse = node.orElse;

    if (iterable == null) {
      throw ArgumentError.notNull('${node.iterable}');
    }

    String render(Object? iterable, [int depth = 0]) {
      var values = list(iterable);

      if (values.isEmpty) {
        if (orElse != null) {
          orElse.accept(this, context);
        }

        return '';
      }

      if (node.test != null) {
        var test = node.test!;
        var filtered = <Object?>[];

        for (var value in values) {
          var data = getDataForTargets(targets, value);
          data = context.save(data);

          if (boolean(test.resolve(context))) {
            filtered.add(value);
          }

          context.restore(data);
        }

        values = filtered;
      }

      var loop = LoopContext(values, depth, render);
      var parent = context.get('loop');
      context.set('loop', loop);

      for (var value in loop) {
        var data = getDataForTargets(targets, value);
        var forContext = context.derived(data: data);
        node.body.accept(this, forContext);
      }

      context.set('loop', parent);
      return '';
    }

    render(iterable);
  }

  @override
  void visitIf(If node, StringSinkRenderContext context) {
    if (boolean(node.test.resolve(context))) {
      node.body.accept(this, context);
      return;
    }

    var orElse = node.orElse;

    if (orElse != null) {
      orElse.accept(this, context);
    }
  }

  @override
  void visitInclude(Include node, StringSinkRenderContext context) {
    var template = context.environment.getTemplate(node.template);

    if (node.withContext) {
      template.body.accept(this, context);
    } else {
      context = StringSinkRenderContext(context.environment, context.sink);
      template.body.accept(this, context);
    }
  }

  @override
  void visitOutput(Output node, StringSinkRenderContext context) {
    visitAll(node.nodes, context);
  }

  @override
  void visitTemplate(Template node, StringSinkRenderContext context) {
    var self = Namespace();

    for (var block in node.blocks) {
      var blocks = context.blocks[block.name] ??= <Block>[];
      blocks.add(block);

      String render() {
        block.accept(this, context);
        return '';
      }

      self[block.name] = render;
    }

    context.set('self', self);
    node.body.accept(this, context);
  }

  @override
  void visitWith(With node, StringSinkRenderContext context) {
    Object? target(int index) {
      return node.targets[index].resolve(context);
    }

    Object? value(int index) {
      return node.values[index].resolve(context);
    }

    var targets = generate(node.targets, target);
    var values = generate(node.values, value);
    var data = context.save(getDataForTargets(targets, values));
    node.body.accept(this, context);
    context.restore(data);
  }
}

Map<String, Object?> getDataForTargets(Object? targets, Object? current) {
  if (targets is String) {
    return <String, Object?>{targets: current};
  }

  if (targets is List) {
    var names = targets.cast<String>();
    var values = list(current);

    if (values.length < names.length) {
      throw StateError('not enough values to unpack (expected ${names.length},'
          ' got ${values.length}).');
    }

    if (values.length > names.length) {
      throw StateError('too many values to unpack (expected ${names.length}).');
    }

    return <String, Object?>{
      for (var i = 0; i < names.length; i++) names[i]: values[i]
    };
  }

  throw ArgumentError.value(
    targets,
    'targets',
    'must be String or List<String>',
  );
}
