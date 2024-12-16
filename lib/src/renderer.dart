import 'dart:math' as math;

import 'package:jinja/src/environment.dart';
import 'package:jinja/src/exceptions.dart';
import 'package:jinja/src/nodes.dart';
import 'package:jinja/src/runtime.dart';
import 'package:jinja/src/tests.dart';
import 'package:jinja/src/utils.dart';
import 'package:jinja/src/visitor.dart';
import 'package:meta/dart2js.dart';

abstract base class RenderContext extends Context {
  RenderContext(
    super.environment, {
    super.template,
    super.blocks,
    super.parent,
    super.data,
  });

  void assignTargets(Object? target, Object? current) {
    if (target is String) {
      set(target, current);
    } else if (target is List<String>) {
      var values = list(current);

      if (values.length < target.length) {
        throw StateError('Not enough values to unpack.');
      }

      if (values.length > target.length) {
        throw StateError('Too many values to unpack.');
      }

      for (var i = 0; i < target.length; i++) {
        set(target[i], values[i]);
      }
    } else if (target is NamespaceValue) {
      var value = resolve(target.name);

      if (value is! Namespace) {
        throw TemplateRuntimeError('Non-namespace object.');
      }

      value[target.item] = current;
    } else {
      throw TypeError();
    }
  }

  @override
  RenderContext derived({String? template, Map<String, Object?>? data});

  Object? finalize(Object? object) {
    return environment.finalize(this, object);
  }
}

base class StringSinkRenderContext extends RenderContext {
  StringSinkRenderContext(
    super.environment,
    this.sink, {
    super.template,
    super.blocks,
    super.parent,
    super.data,
  });

  final StringSink sink;

  @override
  StringSinkRenderContext derived({
    StringSink? sink,
    String? template,
    Map<String, Object?>? data,
    bool withContext = true,
  }) {
    Map<String, Object?> parent;

    if (withContext) {
      parent = <String, Object?>{...this.parent, ...context};
    } else {
      parent = this.parent;
    }

    return StringSinkRenderContext(
      environment,
      sink ?? this.sink,
      template: template ?? this.template,
      blocks: blocks,
      parent: parent,
      data: data,
    );
  }

  @noInline
  void write(Object? value) {
    sink.write(value);
  }
}

base class StringSinkRenderer
    extends Visitor<StringSinkRenderContext, Object?> {
  const StringSinkRenderer();

  Map<String, Object?> getDataForTargets(Object? targets, Object? current) {
    if (targets is String) {
      return <String, Object?>{targets: current};
    }

    if (targets is List<Object?>) {
      var names = targets.cast<String>();
      var values = list(current);

      if (values.length < names.length) {
        throw StateError(
            'Not enough values to unpack (expected ${names.length}, '
            'got ${values.length}).');
      }

      if (values.length > names.length) {
        throw StateError(
            'Too many values to unpack (expected ${names.length}).');
      }

      return <String, Object?>{
        for (var i = 0; i < names.length; i++) names[i]: values[i]
      };
    }

    // TODO(renderer): add error message
    throw ArgumentError.value(targets, 'targets');
  }

  MacroFunction getMacroFunction(
    MacroCall node,
    StringSinkRenderContext context,
  ) {
    String macro(List<Object?> positional, Map<Object?, Object?> named) {
      var buffer = StringBuffer();
      var derived = context.derived(sink: buffer);

      var index = 0;
      var length = node.positional.length;

      for (; index < length; index += 1) {
        var key = node.positional[index].accept(this, context) as String;
        derived.set(key, positional[index]);
      }

      if (node.varargs) {
        derived.set('varargs', positional.sublist(index));
      } else if (index < positional.length) {
        throw TypeError();
      }

      var remaining = named.keys.toSet();

      for (var (argument, defaultValue) in node.named) {
        var key = argument.accept(this, context) as String;

        if (remaining.remove(key)) {
          derived.set(key, named[key]);
        } else {
          if (defaultValue is Name) {
            derived.set(key, named[defaultValue.name]);
          } else {
            derived.set(key, defaultValue.accept(this, context));
          }
        }
      }

      if (node.kwargs) {
        derived.set('kwargs', <Object?, Object?>{
          for (var key in remaining) key: named[key],
        });
      } else if (remaining.isNotEmpty) {
        throw TypeError();
      }

      node.body.accept(this, derived);
      return buffer.toString();
    }

    return macro;
  }

  // Expressions

  @override
  List<Object?> visitArray(Array node, StringSinkRenderContext context) {
    return <Object?>[
      for (var value in node.values) value.accept(this, context)
    ];
  }

  @override
  Object? visitAttribute(Attribute node, StringSinkRenderContext context) {
    var value = node.value.accept(this, context);
    return context.attribute(node.attribute, value);
  }

  @override
  Object? visitCall(Call node, StringSinkRenderContext context) {
    var function = node.value.accept(this, context);
    var (positional, named) = node.calling.accept(this, context) as Parameters;
    return context.call(function, positional, named);
  }

  @override
  Parameters visitCalling(Calling node, StringSinkRenderContext context) {
    var positional = <Object?>[
      for (var argument in node.arguments) argument.accept(this, context)
    ];

    var named = <Symbol, Object?>{
      for (var (:key, :value) in node.keywords)
        Symbol(key): value.accept(this, context)
    };

    return (positional, named);
  }

  @override
  bool visitCompare(Compare node, StringSinkRenderContext context) {
    var left = node.value.accept(this, context);

    for (var (operator, value) in node.operands) {
      var right = value.accept(this, context);

      var result = switch (operator) {
        CompareOperator.equal => isEqual(left, right),
        CompareOperator.notEqual => isNotEqual(left, right),
        CompareOperator.lessThan => isLessThan(left, right),
        CompareOperator.lessThanOrEqual => isLessThanOrEqual(left, right),
        CompareOperator.greaterThan => isGreaterThan(left, right),
        CompareOperator.greaterThanOrEqual => isGreaterThanOrEqual(left, right),
        CompareOperator.contains => isIn(left, right),
        CompareOperator.notContains => !isIn(left, right),
      };

      if (!result) {
        return false;
      }

      left = right;
    }

    return true;
  }

  @override
  Object? visitConcat(Concat node, StringSinkRenderContext context) {
    var buffer = StringBuffer();

    for (var value in node.values) {
      buffer.write(value.accept(this, context));
    }

    return buffer.toString();
  }

  @override
  Object? visitCondition(Condition node, StringSinkRenderContext context) {
    if (boolean(node.test.accept(this, context))) {
      return node.trueValue.accept(this, context);
    }

    return node.falseValue?.accept(this, context);
  }

  @override
  Object? visitConstant(Constant node, StringSinkRenderContext context) {
    return node.value;
  }

  @override
  Map<Object?, Object?> visitDict(Dict node, StringSinkRenderContext context) {
    return <Object?, Object?>{
      for (var (:key, :value) in node.pairs)
        key.accept(this, context): value.accept(this, context)
    };
  }

  @override
  Object? visitFilter(Filter node, StringSinkRenderContext context) {
    var (positional, named) = node.calling.accept(this, context) as Parameters;
    return context.filter(node.name, positional, named);
  }

  @override
  Object? visitItem(Item node, StringSinkRenderContext context) {
    var key = node.key.accept(this, context);
    var value = node.value.accept(this, context);
    return context.item(key, value);
  }

  @override
  Object? visitLogical(Logical node, StringSinkRenderContext context) {
    var left = node.left.accept(this, context);

    return switch (node.operator) {
      LogicalOperator.and =>
        boolean(left) ? node.right.accept(this, context) : left,
      LogicalOperator.or =>
        boolean(left) ? left : node.right.accept(this, context),
    };
  }

  @override
  Object? visitName(Name node, StringSinkRenderContext context) {
    return switch (node.context) {
      AssignContext.load => context.resolve(node.name),
      _ => node.name,
    };
  }

  @override
  NamespaceValue visitNamespaceRef(
    NamespaceRef node,
    StringSinkRenderContext context,
  ) {
    return NamespaceValue(node.name, node.attribute);
  }

  @override
  Object? visitScalar(Scalar node, StringSinkRenderContext context) {
    var left = node.left.accept(this, context);
    var right = node.right.accept(this, context);

    return switch (node.operator) {
      ScalarOperator.power => math.pow(left as num, right as num),
      // ignore: avoid_dynamic_calls
      ScalarOperator.module => (left as dynamic) % right,
      // ignore: avoid_dynamic_calls
      ScalarOperator.floorDivision => (left as dynamic) ~/ right,
      // ignore: avoid_dynamic_calls
      ScalarOperator.division => (left as dynamic) / right,
      // ignore: avoid_dynamic_calls
      ScalarOperator.multiple => (left as dynamic) * right,
      // ignore: avoid_dynamic_calls
      ScalarOperator.minus => (left as dynamic) - right,
      // ignore: avoid_dynamic_calls
      ScalarOperator.plus => (left as dynamic) + right,
    };
  }

  @override
  Object? visitTest(Test node, StringSinkRenderContext context) {
    var (positional, named) = node.calling.accept(this, context) as Parameters;
    return context.test(node.name, positional, named);
  }

  @override
  List<Object?> visitTuple(Tuple node, StringSinkRenderContext context) {
    return <Object?>[
      for (var value in node.values) value.accept(this, context)
    ];
  }

  @override
  Object? visitUnary(Unary node, StringSinkRenderContext context) {
    var value = node.value.accept(this, context);

    return switch (node.operator) {
      UnaryOperator.plus => value,
      // ignore: avoid_dynamic_calls
      UnaryOperator.minus => -(value as dynamic),
      UnaryOperator.not => !boolean(value),
    };
  }

  // Statements

  @override
  void visitAssign(Assign node, StringSinkRenderContext context) {
    var target = node.target.accept(this, context);
    var values = node.value.accept(this, context);
    context.assignTargets(target, values);
  }

  @override
  void visitAssignBlock(AssignBlock node, StringSinkRenderContext context) {
    var target = node.target.accept(this, context);
    var buffer = StringBuffer();
    var derived = context.derived(sink: buffer);
    node.body.accept(this, derived);

    Object? value = buffer.toString();

    var filters = node.filters;

    if (filters.isEmpty) {
      context.assignTargets(target, value);
    } else {
      // TODO(renderer): replace with Filter { BlockExpression ( AssignBlock ) }
      for (var Filter(name: name, calling: calling) in filters) {
        var (positional, named) = calling.accept(this, context) as Parameters;
        positional = [value, ...positional];
        value = context.filter(name, positional, named);
      }

      context.assignTargets(target, value);
    }
  }

  @override
  void visitBlock(Block node, StringSinkRenderContext context) {
    context.blocks[node.name]![0](context);
  }

  @override
  void visitCallBlock(CallBlock node, StringSinkRenderContext context) {
    var function = node.call.value.accept(this, context) as MacroFunction;
    var (arguments, _) = node.call.calling.accept(this, context) as Parameters;
    var [positional as List, named as Map] = arguments;
    named['caller'] = getMacroFunction(node, context);
    context.write(context.call(function, <Object?>[positional, named]));
  }

  @override
  void visitData(Data node, StringSinkRenderContext context) {
    context.write(node.data);
  }

  @override
  void visitDo(Do node, StringSinkRenderContext context) {
    node.value.accept(this, context);
  }

  @override
  void visitExtends(Extends node, StringSinkRenderContext context) {
    var templateOrParth = node.template.accept(this, context);

    var template = switch (templateOrParth) {
      String path => context.environment.getTemplate(path),
      Template template => template,
      Object? value => throw ArgumentError.value(value, 'template'),
    };

    template.body.accept(this, context);
  }

  @override
  void visitFilterBlock(FilterBlock node, StringSinkRenderContext context) {
    var buffer = StringBuffer();
    var derived = context.derived(sink: buffer);
    node.body.accept(this, derived);

    Object? value = buffer.toString();

    for (var Filter(name: name, calling: calling) in node.filters) {
      var (positional, named) = calling.accept(this, context) as Parameters;
      positional = <Object?>[value, ...positional];
      value = context.filter(name, positional, named);
    }

    context.write(value);
  }

  @override
  void visitFor(For node, StringSinkRenderContext context) {
    var targets = node.target.accept(this, context);
    var iterable = node.iterable.accept(this, context);

    if (iterable == null) {
      throw ArgumentError.notNull('iterable');
    }

    String render(Object? iterable, [int depth = 0]) {
      List<Object?> values;

      if (iterable is Map) {
        values = List<Object?>.of(iterable.entries);
      } else {
        values = list(iterable);
      }

      if (values.isEmpty) {
        if (node.orElse case var orElse?) {
          orElse.accept(this, context);
        }

        // Empty string prevents calling `finalize` on `null`.
        return '';
      }

      if (node.test != null) {
        var test = node.test!;
        var filtered = <Object?>[];

        for (var value in values) {
          var data = getDataForTargets(targets, value);
          var newContext = context.derived(data: data);

          if (boolean(test.accept(this, newContext))) {
            filtered.add(value);
          }
        }

        values = filtered;
      }

      var loop = LoopContext(values, depth, render);

      for (var value in loop) {
        var data = getDataForTargets(targets, value);
        var forContext = context.derived(data: data);
        forContext.set('loop', loop);
        node.body.accept(this, forContext);
      }

      // Empty string prevents calling `finalize` on `null`.
      return '';
    }

    render(iterable);
  }

  @override
  void visitFromImport(FromImport node, StringSinkRenderContext context) {
    var templateOrParth = node.template.accept(this, context);

    var template = switch (templateOrParth) {
      String path => context.environment.getTemplate(path),
      Template template => template,
      // TODO(renderer): add error message
      Object? value => throw ArgumentError.value(value, 'template'),
    };

    for (var (name, alias) in node.names) {
      String macro(List<Object?> positional, Map<Object?, Object?> named) {
        Macro? targetMacro;

        for (var macro in template.body.macros) {
          if (macro.name == name) {
            targetMacro = macro;
            break;
          }
        }

        if (targetMacro == null) {
          throw TemplateRuntimeError(
              "The '${template.path}' does not export the requested name.");
        }

        MacroFunction function;

        if (node.withContext) {
          function = getMacroFunction(targetMacro, context);
        } else {
          var newContext = context.derived(withContext: false);
          function = getMacroFunction(targetMacro, newContext);
        }

        return function(positional, named.cast<Symbol, Object?>());
      }

      context.set(alias ?? name, macro);
    }
  }

  @override
  void visitIf(If node, StringSinkRenderContext context) {
    if (boolean(node.test.accept(this, context))) {
      node.body.accept(this, context);
    } else if (node.orElse case var orElse?) {
      orElse.accept(this, context);
    }
  }

  @override
  void visitImport(Import node, StringSinkRenderContext context) {
    var templateOrParth = node.template.accept(this, context);

    var template = switch (templateOrParth) {
      String path => context.environment.getTemplate(path),
      Template template => template,
      Object? value => throw ArgumentError.value(value, 'template'),
    };

    var namespace = Namespace();

    for (var macro in template.body.macros) {
      if (node.withContext) {
        namespace[macro.name] = getMacroFunction(macro, context);
      } else {
        var newContext = context.derived(withContext: false);
        namespace[macro.name] = getMacroFunction(macro, newContext);
      }
    }

    context.set(node.target, namespace);
  }

  @override
  void visitInclude(Include node, StringSinkRenderContext context) {
    var templateOrParth = node.template.accept(this, context);

    Template? template;

    try {
      template = switch (templateOrParth) {
        String path => context.environment.getTemplate(path),
        Template template => template,
        List<Object?> paths => context.environment.selectTemplate(paths),
        // TODO(renderer): add error message
        Object? value => throw ArgumentError.value(value, 'template'),
      };
    } on TemplateNotFound {
      if (!node.ignoreMissing) {
        rethrow;
      }
    }

    if (template != null) {
      if (!node.withContext) {
        context = context.derived(withContext: false);
      }

      template.body.accept(this, context);
    }
  }

  @override
  void visitInterpolation(Interpolation node, StringSinkRenderContext context) {
    var value = node.value.accept(this, context);
    var finalized = context.finalize(value);
    context.write(finalized);
  }

  @override
  void visitMacro(Macro node, StringSinkRenderContext context) {
    var function = getMacroFunction(node, context);
    context.set(node.name, function);
  }

  @override
  void visitOutput(Output node, StringSinkRenderContext context) {
    for (var node in node.nodes) {
      node.accept(this, context);
    }
  }

  @override
  void visitTemplateNode(TemplateNode node, StringSinkRenderContext context) {
    // TODO(renderer): add `TemplateReference`
    var self = Namespace();

    for (var block in node.blocks) {
      var blockName = block.name;

      // TODO(compiler): switch to `ContextCallback`
      String render() {
        var blocks = context.blocks[blockName];

        if (blocks == null) {
          throw UndefinedError("Block '$blockName' is not defined.");
        }

        // TODO(renderer): check if empty
        blocks[0](context);
        return '';
      }

      self[blockName] = render;

      var blocks = context.blocks[blockName] ??= <ContextCallback>[];

      if (block.required) {
        Never callback(Context context) {
          throw TemplateRuntimeError(
              "Required block '${block.name}' not found.");
        }

        blocks.add(callback);
      } else {
        var parentIndex = blocks.length + 1;

        void callback(Context context) {
          var current = context.get('super');

          // TODO(renderer): add `BlockReference`
          String parent() {
            var blocks = context.blocks[blockName]!;

            if (parentIndex >= blocks.length) {
              throw TemplateRuntimeError("Super block '$blockName' not found.");
            }

            blocks[parentIndex](context);
            return '';
          }

          context.set('super', parent);
          block.body.accept(this, context);
          context.set('super', current);
        }

        blocks.add(callback);
      }
    }

    context.set('self', self);
    node.body.accept(this, context);
  }

  @override
  void visitWith(With node, StringSinkRenderContext context) {
    var data = <String, Object?>{};

    for (var i = 0; i < node.targets.length; i += 1) {
      var target = node.targets[i].accept(this, context) as String;
      var value = node.values[i].accept(this, context);
      data[target] = value;
    }

    var newContext = context.derived(data: data);
    node.body.accept(this, newContext);
  }
}
